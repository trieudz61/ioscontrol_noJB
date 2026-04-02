// IOSControlDaemon.m — Standalone daemon process
// Spawned by the IOSControlApp, survives app kills
// Architecture: exactly like XXTouch's ReportCrash daemon

#import "ICHTTPServer.h"
#import "ICLuaEngine.h"
#import "ICScreenCapture.h"
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach/mach_time.h>
#import <math.h>
#import <objc/runtime.h>
#import <signal.h>
#import <sys/resource.h> // setpriority
#import <unistd.h>

// XNU memorystatus API to prevent Jetsam kills
extern int memorystatus_control(uint32_t command, int32_t pid, uint32_t flags,
                                void *buffer, size_t buffersize);

// ═══════════════════════════════════════════
// IOHIDEvent type declarations (same as Tweak.xm)
// ═══════════════════════════════════════════

typedef void *IOHIDEventRef;
typedef void *IOHIDEventSystemClientRef;
typedef void *IOHIDServiceRef;
typedef uint32_t IOHIDEventType;

static const IOHIDEventType kIOHIDEventTypeDigitizer = 11;

enum {
  kIOHIDDigitizerEventRange = 0x00000001,
  kIOHIDDigitizerEventTouch = 0x00000002,
  kIOHIDDigitizerEventPosition = 0x00000004,
};

enum {
  TOUCH_DOWN = 1,
  TOUCH_MOVE = 2,
  TOUCH_UP = 3,
};

enum {
  kIOHIDEventFieldDigitizerX = 0x000B0001,
  kIOHIDEventFieldDigitizerY = 0x000B0002,
  kIOHIDEventFieldDigitizerMask = 0x000B000D,
  kIOHIDEventFieldDigitizerRange = 0x000B0007,
  kIOHIDEventFieldDigitizerTouch = 0x000B0008,
  kIOHIDEventFieldDigitizerEventMask = 0x000B000C,
  kIOHIDEventFieldDigitizerDisplayIntegrated = 0x000B0019,
  kIOHIDEventFieldBuiltIn = 0x00000004,
};

#define kIOHIDDigitizerEventIdentity 32

// ═══════════════════════════════════════════
// IOHIDEvent function pointers
// ═══════════════════════════════════════════

static IOHIDEventSystemClientRef (*_SystemClientCreate)(CFAllocatorRef);
static void (*_SystemClientDispatchEvent)(IOHIDEventSystemClientRef,
                                          IOHIDEventRef);
static void (*_SystemClientScheduleWithRunLoop)(IOHIDEventSystemClientRef,
                                                CFRunLoopRef, CFRunLoopMode);
static void (*_SystemClientRegisterEventCallback)(IOHIDEventSystemClientRef,
                                                  void *, void *, void *);

static IOHIDEventRef (*_CreateDigitizerEvent)(CFAllocatorRef, uint64_t,
                                              uint32_t, uint32_t, uint32_t,
                                              uint32_t, uint32_t, double,
                                              double, double, double, double,
                                              Boolean, Boolean, uint32_t);
static IOHIDEventRef (*_CreateFingerEvent)(CFAllocatorRef, uint64_t, uint32_t,
                                           uint32_t, uint32_t, double, double,
                                           double, double, double, Boolean,
                                           Boolean, uint32_t);
static void (*_AppendEvent)(IOHIDEventRef, IOHIDEventRef, uint32_t);
static void (*_SetSenderID)(IOHIDEventRef, uint64_t);
static uint64_t (*_GetSenderID)(IOHIDEventRef);
static IOHIDEventType (*_GetType)(IOHIDEventRef);
static int64_t (*_GetIntegerValue)(IOHIDEventRef, uint32_t);
static void (*_SetIntegerValue)(IOHIDEventRef, uint32_t, int64_t);
static void (*_SetFloatValue)(IOHIDEventRef, uint32_t, double);
static double (*_GetFloatValue)(IOHIDEventRef, uint32_t);
static void (*_SetIntegerValueWithOptions)(IOHIDEventRef, uint32_t, int64_t,
                                           int32_t);

// ═══════════════════════════════════════════
// Global state
// ═══════════════════════════════════════════

double gScreenW = 393.0; // Default iPhone 15 Pro
double gScreenH = 852.0;
uint64_t gSenderID = 0;
IOHIDEventSystemClientRef gDispatchClient = NULL; // used by ICKeyInput.m
static IOHIDEventSystemClientRef gCaptureClient = NULL;
static IOHIDEventSystemClientRef gKeyboardClient = NULL;
// Dedicated keyboard/button dispatch client (type=Admin) for Home/Volume events
IOHIDEventSystemClientRef gKeyboardDispatchClient =
    NULL; // used by ICKeyInput.m
static FILE *gLogFile = NULL;
// Real hardware senderID from keyboard button service (captured from Volume
// press) This is needed for SpringBoard to accept injected button events
uint64_t gHWSenderID = 0; // used by ICKeyInput.m

// kIOHIDEventSystemClientTypeAdmin = 2 (required for dispatching keyboard
// events to SpringBoard)
#define kIOHIDEventSystemClientTypeAdmin 2

// Serial queue for ALL HID event dispatch — IOHIDEvent APIs are NOT thread-safe
// Using concurrent queue caused gDispatchClient race condition → daemon crash
static dispatch_queue_t gHIDQueue = NULL;

// Serial queue for ALL screen capture — UIKit/CoreGraphics are NOT thread-safe
// Must never run concurrently with other CoreGraphics operations
dispatch_queue_t gScreenQueue = NULL;

// ═══════════════════════════════════════════
// Logging
// ═══════════════════════════════════════════

void logMsg(const char *fmt, ...) {
  if (!gLogFile)
    gLogFile = fopen("/var/tmp/ioscontrol-daemon.log", "a");
  if (!gLogFile)
    return;

  // Timestamp
  time_t now = time(NULL);
  struct tm *t = localtime(&now);
  fprintf(gLogFile, "[%02d:%02d:%02d] ", t->tm_hour, t->tm_min, t->tm_sec);

  va_list args;
  va_start(args, fmt);
  vfprintf(gLogFile, fmt, args);
  va_end(args);
  fprintf(gLogFile, "\n");
  fflush(gLogFile);
}

// ═══════════════════════════════════════════
// Load HID symbols
// ═══════════════════════════════════════════

static void loadHIDSymbols(void) {
  void *handle =
      dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
  if (!handle) {
    logMsg("❌ Cannot load IOKit");
    return;
  }

  _SystemClientCreate = (typeof(_SystemClientCreate))dlsym(
      handle, "IOHIDEventSystemClientCreate");
  _SystemClientDispatchEvent = (typeof(_SystemClientDispatchEvent))dlsym(
      handle, "IOHIDEventSystemClientDispatchEvent");
  _SystemClientScheduleWithRunLoop =
      (typeof(_SystemClientScheduleWithRunLoop))dlsym(
          handle, "IOHIDEventSystemClientScheduleWithRunLoop");
  _SystemClientRegisterEventCallback =
      (typeof(_SystemClientRegisterEventCallback))dlsym(
          handle, "IOHIDEventSystemClientRegisterEventCallback");
  _CreateDigitizerEvent = (typeof(_CreateDigitizerEvent))dlsym(
      handle, "IOHIDEventCreateDigitizerEvent");
  _CreateFingerEvent = (typeof(_CreateFingerEvent))dlsym(
      handle, "IOHIDEventCreateDigitizerFingerEvent");
  _AppendEvent = (typeof(_AppendEvent))dlsym(handle, "IOHIDEventAppendEvent");
  _SetSenderID = (typeof(_SetSenderID))dlsym(handle, "IOHIDEventSetSenderID");
  _GetSenderID = (typeof(_GetSenderID))dlsym(handle, "IOHIDEventGetSenderID");
  _GetType = (typeof(_GetType))dlsym(handle, "IOHIDEventGetType");
  _GetIntegerValue =
      (typeof(_GetIntegerValue))dlsym(handle, "IOHIDEventGetIntegerValue");
  _SetIntegerValue =
      (typeof(_SetIntegerValue))dlsym(handle, "IOHIDEventSetIntegerValue");
  _SetFloatValue =
      (typeof(_SetFloatValue))dlsym(handle, "IOHIDEventSetFloatValue");
  _GetFloatValue =
      (typeof(_GetFloatValue))dlsym(handle, "IOHIDEventGetFloatValue");
  _SetIntegerValueWithOptions = (typeof(_SetIntegerValueWithOptions))dlsym(
      handle, "IOHIDEventSetIntegerValueWithOptions");

  logMsg("✅ HID symbols loaded (%d available)",
         !!_SystemClientCreate + !!_SystemClientDispatchEvent +
             !!_CreateDigitizerEvent + !!_CreateFingerEvent + !!_AppendEvent +
             !!_SetSenderID);
}

// ═══════════════════════════════════════════
// SenderID auto-capture
// ═══════════════════════════════════════════

static void senderIDCallback(void *target, void *refcon,
                             IOHIDServiceRef service, IOHIDEventRef event) {
  if (!_GetType)
    return;
  if (_GetType(event) == kIOHIDEventTypeDigitizer && gSenderID == 0 &&
      _GetSenderID) {
    gSenderID = _GetSenderID(event);
    logMsg("✅ Input source captured: 0x%llX", gSenderID);
  }
}

static void startSenderIDCapture(void) {
  if (!_SystemClientCreate || !_SystemClientScheduleWithRunLoop ||
      !_SystemClientRegisterEventCallback)
    return;

  // Capture client: listens for real touches to learn senderID
  gCaptureClient = _SystemClientCreate(kCFAllocatorDefault);
  if (gCaptureClient) {
    _SystemClientScheduleWithRunLoop(gCaptureClient, CFRunLoopGetMain(),
                                     kCFRunLoopDefaultMode);
    _SystemClientRegisterEventCallback(gCaptureClient, (void *)senderIDCallback,
                                       NULL, NULL);
    logMsg("🎧 Input capture active — waiting for first touch");
  }

  // Dispatch client: used to INJECT synthetic touch events
  // Created here (in main() context) and scheduled on main run loop
  // so iOS properly routes our injected events through the HID system
  gDispatchClient = _SystemClientCreate(kCFAllocatorDefault);
  if (gDispatchClient) {
    _SystemClientScheduleWithRunLoop(gDispatchClient, CFRunLoopGetMain(),
                                     kCFRunLoopDefaultMode);
    logMsg("✅ HID dispatch client ready (run loop scheduled)");
  } else {
    logMsg("❌ Failed to create HID dispatch client");
  }

  // ── Keyboard/button dispatch client (type=Admin) ──
  // IOHIDEventSystemClientCreate(type=0) CANNOT dispatch keyboard/button events
  // to SpringBoard. Must use IOHIDEventSystemClientCreateWithType(type=2)
  // This is what XXTouch uses internally for Home/Volume/Lock button dispatch.
  IOHIDEventSystemClientRef (*_CreateWithType)(CFAllocatorRef, uint32_t,
                                               CFDictionaryRef) =
      dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreateWithType");
  if (_CreateWithType) {
    gKeyboardDispatchClient = _CreateWithType(
        kCFAllocatorDefault, kIOHIDEventSystemClientTypeAdmin, NULL);
    if (gKeyboardDispatchClient) {
      _SystemClientScheduleWithRunLoop(
          gKeyboardDispatchClient, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
      logMsg("✅ Keyboard dispatch client (Admin type) ready");
    } else {
      logMsg("⚠️ IOHIDEventSystemClientCreateWithType returned NULL — fallback "
             "to gDispatchClient");
    }
  } else {
    logMsg("⚠️ IOHIDEventSystemClientCreateWithType not found — fallback to "
           "gDispatchClient");
  }
}

// ═══════════════════════════════════════════
// Core Touch Dispatch
// ═══════════════════════════════════════════

// All IOHIDEvent dispatch MUST run on gHIDQueue (serial) — not thread-safe
static void dispatchTouch(double x, double y, int finger, int touchType) {
  double normX = x / gScreenW;
  double normY = y / gScreenH;
  if (normX < 0)
    normX = 0;
  if (normX > 1)
    normX = 1;
  if (normY < 0)
    normY = 0;
  if (normY > 1)
    normY = 1;

  Boolean isTouching = (touchType != TOUCH_UP);
  int touch = isTouching ? 1 : 0;

  int fingerMask = (touchType == TOUCH_MOVE) ? kIOHIDDigitizerEventPosition
                                             : (kIOHIDDigitizerEventRange |
                                                kIOHIDDigitizerEventTouch |
                                                kIOHIDDigitizerEventIdentity);

  uint64_t timestamp = mach_absolute_time();

  IOHIDEventRef handEvent = _CreateDigitizerEvent(
      kCFAllocatorDefault, timestamp, 3, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

  if (_SetIntegerValueWithOptions) {
    _SetIntegerValueWithOptions(
        handEvent, kIOHIDEventFieldDigitizerDisplayIntegrated, 1, -268435456);
    _SetIntegerValueWithOptions(handEvent, kIOHIDEventFieldBuiltIn, 1,
                                -268435456);
  }

  uint64_t sid = gSenderID ? gSenderID : 0x000000010000027FULL;
  _SetSenderID(handEvent, sid);

  IOHIDEventRef fingerEvent = _CreateFingerEvent(
      kCFAllocatorDefault, timestamp, finger, finger + 2, fingerMask, normX,
      normY, 0.0, isTouching ? 1.0 : 0.0, 0.0, isTouching, isTouching, 0);

  _AppendEvent(handEvent, fingerEvent, 0);

  int handMask = fingerMask;
  if (touchType == TOUCH_UP)
    handMask |= kIOHIDDigitizerEventPosition;

  if (_SetIntegerValueWithOptions) {
    _SetIntegerValueWithOptions(handEvent, kIOHIDEventFieldDigitizerEventMask,
                                handMask, -268435456);
    _SetIntegerValueWithOptions(handEvent, kIOHIDEventFieldDigitizerRange,
                                touch, -268435456);
    _SetIntegerValueWithOptions(handEvent, kIOHIDEventFieldDigitizerTouch,
                                touch, -268435456);
  }

  // Use pre-created dispatch client (init'd in startSenderIDCapture() on main
  // run loop)
  _SystemClientDispatchEvent(gDispatchClient, handEvent);

  // Log every DOWN/UP with senderID + client validity
  if (touchType != TOUCH_MOVE) {
    logMsg("🎯 touch pt=(%.0f,%.0f) type=%d senderID=0x%llX client=%s", x, y,
           touchType, sid, gDispatchClient ? "OK" : "NULL");
  }

  CFRelease(fingerEvent);
  CFRelease(handEvent);
}

// ── Public Touch API ──
// ALL calls routed through gHIDQueue (serial) — IOHIDEvent APIs are NOT
// thread-safe. Concurrent access to gDispatchClient causes daemon crash.

void ic_touchDown(double x, double y, int finger) {
  dispatch_async(dispatch_get_main_queue(), ^{
    dispatchTouch(x, y, finger, TOUCH_DOWN);
  });
}
void ic_touchMove(double x, double y, int finger) {
  dispatch_async(dispatch_get_main_queue(), ^{
    dispatchTouch(x, y, finger, TOUCH_MOVE);
  });
}
void ic_touchUp(double x, double y, int finger) {
  dispatch_async(dispatch_get_main_queue(), ^{
    dispatchTouch(x, y, finger, TOUCH_UP);
  });
}

void ic_tap(double x, double y) {
  dispatch_sync(dispatch_get_main_queue(), ^{
    dispatchTouch(x, y, 0, TOUCH_DOWN);
    usleep(80000);
    dispatchTouch(x, y, 0, TOUCH_UP);
  });
}

void ic_swipe(double x1, double y1, double x2, double y2, double duration) {
  dispatch_async(gHIDQueue, ^{
    const int kMaxStepsPerSec = 30;
    const useconds_t kMinStepUs = 33000; // 33ms = 30fps

    int steps = (int)(duration * kMaxStepsPerSec);
    if (steps < 5)
      steps = 5;
    if (steps > 60)
      steps = 60;

    double dx = (x2 - x1) / steps;
    double dy = (y2 - y1) / steps;
    useconds_t delay = (useconds_t)((duration / steps) * 1000000);
    if (delay < kMinStepUs)
      delay = kMinStepUs;

    dispatchTouch(x1, y1, 0, TOUCH_DOWN);
    usleep(30000);
    for (int i = 1; i <= steps; i++) {
      usleep(delay);
      dispatchTouch(x1 + dx * i, y1 + dy * i, 0, TOUCH_MOVE);
    }
    usleep(16000);
    dispatchTouch(x2, y2, 0, TOUCH_UP);
  });
}

void ic_longPress(double x, double y, double duration) {
  dispatch_async(gHIDQueue, ^{
    dispatchTouch(x, y, 0, TOUCH_DOWN);
    usleep((useconds_t)(duration * 1000000));
    dispatchTouch(x, y, 0, TOUCH_UP);
  });
}

// ═══════════════════════════════════════════
// Key Press (Home, Lock, Volume, etc.)
// ═══════════════════════════════════════════

// IOHIDEvent keyboard field constants (from IOHIDEventTypes.h)
#define kIOHIDKeyboardUsagePage 0x00030000
#define kIOHIDKeyboardUsage 0x00030001
#define kIOHIDKeyboardDown 0x00030002

// HID Usage pages
#define kHIDPage_Consumer 0x000C
#define kHIDPage_KeyboardOrKeypad 0x0007
#define kHIDPage_AppleVendor 0xFF01

typedef struct {
  uint32_t page;
  uint32_t usage;
} ICKeyDef;

static ICKeyDef ic_keyDefForName(const char *name) {
  // ── System / Hardware buttons ──────────────────────────────────────────
  if (!strcmp(name, "HOMEBUTTON") || !strcmp(name, "HOME"))
    return (ICKeyDef){0x000C, 0x0040}; // Consumer Menu (iPhone 8 home button)
  if (!strcmp(name, "LOCK") || !strcmp(name, "SLEEP") || !strcmp(name, "POWER"))
    return (ICKeyDef){0x000C, 0x0030}; // Consumer Power
  if (!strcmp(name, "SCREENSAVE"))
    return (ICKeyDef){0xFF01, 0x000B}; // AppleVendor Screensave
  if (!strcmp(name, "SPOTLIGHT") || !strcmp(name, "SEARCH"))
    return (ICKeyDef){0xFF01, 0x0009}; // AppleVendor Spotlight

  // ── Volume / Media ─────────────────────────────────────────────────────
  if (!strcmp(name, "VOLUMEUP"))
    return (ICKeyDef){0x000C, 0x00E9};
  if (!strcmp(name, "VOLUMEDOWN"))
    return (ICKeyDef){0x000C, 0x00EA};
  if (!strcmp(name, "MUTE"))
    return (ICKeyDef){0x000C, 0x00E2};
  if (!strcmp(name, "PLAYPAUSE"))
    return (ICKeyDef){0x000C, 0x00CD};
  if (!strcmp(name, "NEXTTRACK"))
    return (ICKeyDef){0x000C, 0x00B5};
  if (!strcmp(name, "PREVTRACK"))
    return (ICKeyDef){0x000C, 0x00B6};
  if (!strcmp(name, "FASTFORWARD"))
    return (ICKeyDef){0x000C, 0x00B3};
  if (!strcmp(name, "REWIND"))
    return (ICKeyDef){0x000C, 0x00B4};

  // ── Special HID keyboard keys ──────────────────────────────────────────
  if (!strcmp(name, "RETURN") || !strcmp(name, "ENTER"))
    return (ICKeyDef){0x0007, 0x0028};
  if (!strcmp(name, "ESCAPE") || !strcmp(name, "ESC"))
    return (ICKeyDef){0x0007, 0x0029};
  if (!strcmp(name, "BACKSPACE") || !strcmp(name, "DELETE"))
    return (ICKeyDef){0x0007, 0x002A};
  if (!strcmp(name, "TAB"))
    return (ICKeyDef){0x0007, 0x002B};
  if (!strcmp(name, "SPACE"))
    return (ICKeyDef){0x0007, 0x002C};
  if (!strcmp(name, "CAPSLOCK"))
    return (ICKeyDef){0x0007, 0x0039};
  if (!strcmp(name, "DEL") || !strcmp(name, "FORWARDDELETE"))
    return (ICKeyDef){0x0007, 0x004C};

  // ── Arrow keys ─────────────────────────────────────────────────────────
  if (!strcmp(name, "RIGHT") || !strcmp(name, "RIGHTARROW"))
    return (ICKeyDef){0x0007, 0x004F};
  if (!strcmp(name, "LEFT") || !strcmp(name, "LEFTARROW"))
    return (ICKeyDef){0x0007, 0x0050};
  if (!strcmp(name, "DOWN") || !strcmp(name, "DOWNARROW"))
    return (ICKeyDef){0x0007, 0x0051};
  if (!strcmp(name, "UP") || !strcmp(name, "UPARROW"))
    return (ICKeyDef){0x0007, 0x0052};

  // ── Navigation ────────────────────────────────────────────────────────
  if (!strcmp(name, "PAGEUP"))
    return (ICKeyDef){0x0007, 0x004B};
  if (!strcmp(name, "PAGEDOWN"))
    return (ICKeyDef){0x0007, 0x004E};
  if (!strcmp(name, "HOMEKEY"))
    return (ICKeyDef){0x0007, 0x004A};
  if (!strcmp(name, "ENDKEY"))
    return (ICKeyDef){0x0007, 0x004D};

  // ── Function keys F1-F12 ───────────────────────────────────────────────
  if (!strcmp(name, "F1"))
    return (ICKeyDef){0x0007, 0x003A};
  if (!strcmp(name, "F2"))
    return (ICKeyDef){0x0007, 0x003B};
  if (!strcmp(name, "F3"))
    return (ICKeyDef){0x0007, 0x003C};
  if (!strcmp(name, "F4"))
    return (ICKeyDef){0x0007, 0x003D};
  if (!strcmp(name, "F5"))
    return (ICKeyDef){0x0007, 0x003E};
  if (!strcmp(name, "F6"))
    return (ICKeyDef){0x0007, 0x003F};
  if (!strcmp(name, "F7"))
    return (ICKeyDef){0x0007, 0x0040};
  if (!strcmp(name, "F8"))
    return (ICKeyDef){0x0007, 0x0041};
  if (!strcmp(name, "F9"))
    return (ICKeyDef){0x0007, 0x0042};
  if (!strcmp(name, "F10"))
    return (ICKeyDef){0x0007, 0x0043};
  if (!strcmp(name, "F11"))
    return (ICKeyDef){0x0007, 0x0044};
  if (!strcmp(name, "F12"))
    return (ICKeyDef){0x0007, 0x0045};

  // ── Modifier keys ─────────────────────────────────────────────────────
  if (!strcmp(name, "LSHIFT"))
    return (ICKeyDef){0x0007, 0x00E1};
  if (!strcmp(name, "RSHIFT"))
    return (ICKeyDef){0x0007, 0x00E5};
  if (!strcmp(name, "LCTRL"))
    return (ICKeyDef){0x0007, 0x00E0};
  if (!strcmp(name, "RCTRL"))
    return (ICKeyDef){0x0007, 0x00E4};
  if (!strcmp(name, "LALT"))
    return (ICKeyDef){0x0007, 0x00E2};
  if (!strcmp(name, "RALT"))
    return (ICKeyDef){0x0007, 0x00E6};
  if (!strcmp(name, "LGUI") || !strcmp(name, "CMD"))
    return (ICKeyDef){0x0007, 0x00E3};
  if (!strcmp(name, "RGUI"))
    return (ICKeyDef){0x0007, 0x00E7};

  // ── Letters A-Z (HID: 0x04=a … 0x1D=z) ───────────────────────────────
  if (strlen(name) == 1) {
    char c = name[0];
    if (c >= 'a' && c <= 'z')
      return (ICKeyDef){0x0007, (uint32_t)(0x04 + c - 'a')};
    if (c >= 'A' && c <= 'Z')
      return (ICKeyDef){0x0007, (uint32_t)(0x04 + c - 'A')};
    // Digits 1-9=0x1E-0x26, 0=0x27
    if (c >= '1' && c <= '9')
      return (ICKeyDef){0x0007, (uint32_t)(0x1E + c - '1')};
    if (c == '0')
      return (ICKeyDef){0x0007, 0x0027};
    // Common punctuation
    if (c == '-')
      return (ICKeyDef){0x0007, 0x002D};
    if (c == '=')
      return (ICKeyDef){0x0007, 0x002E};
    if (c == '[')
      return (ICKeyDef){0x0007, 0x002F};
    if (c == ']')
      return (ICKeyDef){0x0007, 0x0030};
    if (c == '\\')
      return (ICKeyDef){0x0007, 0x0031};
    if (c == ';')
      return (ICKeyDef){0x0007, 0x0033};
    if (c == '\'')
      return (ICKeyDef){0x0007, 0x0034};
    if (c == '`')
      return (ICKeyDef){0x0007, 0x0035};
    if (c == ',')
      return (ICKeyDef){0x0007, 0x0036};
    if (c == '.')
      return (ICKeyDef){0x0007, 0x0037};
    if (c == '/')
      return (ICKeyDef){0x0007, 0x0038};
  }

  // ── Named keys for letters (alternative uppercase form) ───────────────
  if (strlen(name) == 2) {
    // e.g., "KEY_A" shorthand or fallback
  }

  return (ICKeyDef){0, 0};
}

static void dispatchKeyEvent(uint32_t page, uint32_t usage, BOOL down) {
  if (!_SystemClientDispatchEvent || !_SetSenderID)
    return;

  // Use IOHIDEventCreateKeyboardEvent (Apple private, available on iOS)
  void *(*_CreateKeyboard)(CFAllocatorRef, uint64_t, uint32_t, uint32_t,
                           Boolean, uint32_t) =
      dlsym(RTLD_DEFAULT, "IOHIDEventCreateKeyboardEvent");
  if (!_CreateKeyboard) {
    logMsg("⚠️ IOHIDEventCreateKeyboardEvent not found");
    return;
  }

  uint64_t ts = mach_absolute_time();
  IOHIDEventRef ev =
      _CreateKeyboard(kCFAllocatorDefault, ts, page, usage, down, 0);
  if (!ev)
    return;

  // Priority: real HW senderID (captured from real button press) → touch
  // senderID → fallback SpringBoard ONLY accepts button events with the
  // hardware button service's senderID
  uint64_t sid = gHWSenderID ? gHWSenderID
                             : (gSenderID ? gSenderID : 0x000000010000027FULL);
  _SetSenderID(ev, sid);
  logMsg("🔑 Dispatching key page=0x%04X usage=0x%04X down=%d senderID=0x%llX "
         "(hw=%s)",
         page, usage, (int)down, sid, gHWSenderID ? "yes" : "no");
  IOHIDEventSystemClientRef client =
      gKeyboardDispatchClient ? gKeyboardDispatchClient : gDispatchClient;
  if (client)
    _SystemClientDispatchEvent(client, ev);
  CFRelease(ev);
}

void ic_pressKey(const char *name) {
  ICKeyDef def = ic_keyDefForName(name);
  if (def.page == 0) {
    logMsg("⚠️ Unknown key: %s", name);
    return;
  }

  // ── HOMEBUTTON: multi-approach for non-jailbreak ──
  // Approach 1: IOHIDEvent with real HW senderID (works if Volume was pressed
  // first) Approach 2: SBSLaunchApplicationWithIdentifier(SpringBoard) → goes
  // to home screen
  if (strcmp(name, "HOMEBUTTON") == 0) {
    // ✅ CONFIRMED: iPhone 8 home button = Consumer Menu {0x0C, 0x40}
    // GSSendSystemEvent/SBS approaches removed — crash or fail from external
    // daemon
    dispatch_async(dispatch_get_main_queue(), ^{
      dispatchKeyEvent(0x0C, 0x0040, YES);
      usleep(100000);
      dispatchKeyEvent(0x0C, 0x0040, NO);
      logMsg("🏠 HOMEBUTTON: {0x0C,0x40} dispatched");
    });
    return;
  }

  // Other keys: IOHIDEvent dispatch on main queue
  dispatch_async(dispatch_get_main_queue(), ^{
    dispatchKeyEvent(def.page, def.usage, YES);
    usleep(80000);
    dispatchKeyEvent(def.page, def.usage, NO);
    logMsg("🔑 Key press: %s (page=0x%04X usage=0x%04X)", name, def.page,
           def.usage);
  });
}

void ic_holdKey(const char *name) {
  ICKeyDef def = ic_keyDefForName(name);
  if (def.page == 0)
    return;
  dispatch_async(gHIDQueue, ^{
    dispatchKeyEvent(def.page, def.usage, YES);
  });
}

void ic_releaseKey(const char *name) {
  ICKeyDef def = ic_keyDefForName(name);
  if (def.page == 0)
    return;
  dispatch_async(gHIDQueue, ^{
    dispatchKeyEvent(def.page, def.usage, NO);
  });
}

// ═══════════════════════════════════════════
// Volume Button Test Trigger
// ═══════════════════════════════════════════

static void keyboardEventCallback(void *target, void *refcon,
                                  IOHIDServiceRef service,
                                  IOHIDEventRef event) {
  if (!_GetType || !_GetIntegerValue)
    return;

  IOHIDEventType type = _GetType(event);
  if (type != 3) // kIOHIDEventTypeKeyboard = 3
    return;

  int64_t usagePage = _GetIntegerValue(event, 0x00030000);
  int64_t usage = _GetIntegerValue(event, 0x00030001);
  int64_t down = _GetIntegerValue(event, 0x00030002);

  // Capture the real hardware senderID from any physical button press
  // (Volume Up/Down, Lock). This senderID is what SpringBoard trusts.
  if (gHWSenderID == 0 && _GetSenderID) {
    uint64_t sid = _GetSenderID(event);
    // Filter out our own injected events (they use gSenderID or fallback)
    if (sid != gSenderID && sid != 0x000000010000027FULL && sid != 0) {
      gHWSenderID = sid;
      logMsg("✅ HW keyboard senderID captured: 0x%llX", gHWSenderID);
    }
  }

  logMsg("🎹 Key event: page=0x%llX usage=0x%llX down=%lld senderID=0x%llX",
         usagePage, usage, down, _GetSenderID ? _GetSenderID(event) : 0);
}

static void startKeyboardCapture(void) {
  if (!_SystemClientCreate || !_SystemClientScheduleWithRunLoop ||
      !_SystemClientRegisterEventCallback)
    return;
  gKeyboardClient = _SystemClientCreate(kCFAllocatorDefault);
  if (gKeyboardClient) {
    _SystemClientScheduleWithRunLoop(gKeyboardClient, CFRunLoopGetMain(),
                                     kCFRunLoopDefaultMode);
    _SystemClientRegisterEventCallback(
        gKeyboardClient, (void *)keyboardEventCallback, NULL, NULL);
    logMsg("🎧 Keyboard capture active for testing (Vol-)");
  }
}

// ═══════════════════════════════════════════
// Signal handlers
// ═══════════════════════════════════════════

static void handleSignal(int sig) {
  logMsg("⚠️ Received signal %d, ignoring (daemon stays alive)", sig);
}

// ═══════════════════════════════════════════
// App install check (LSApplicationWorkspace)
// ═══════════════════════════════════════════

static BOOL isAppStillInstalled(void) {
  Class LSAppWorkspace = objc_getClass("LSApplicationWorkspace");
  if (!LSAppWorkspace)
    return YES; // Can't check, assume installed
  id workspace = [LSAppWorkspace performSelector:@selector(defaultWorkspace)];
  if (!workspace)
    return YES;
  id proxy =
      [workspace performSelector:@selector(applicationProxyForIdentifier:)
                      withObject:@"com.trieu.ioscontrolapp"];
  return (proxy != nil);
}

static void appUninstalledNotification(CFNotificationCenterRef center,
                                       void *observer, CFNotificationName name,
                                       const void *object,
                                       CFDictionaryRef userInfo) {
  logMsg("📢 Received notification: %s",
         CFStringGetCStringPtr(name, kCFStringEncodingUTF8) ?: "unknown");
  // Small delay to let the system finish unregistering
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        if (!isAppStillInstalled()) {
          logMsg("🛑 App uninstalled — daemon exiting.");
          exit(0);
        }
      });
}

// ═══════════════════════════════════════════
// Main — Daemon Entry Point
// ═══════════════════════════════════════════

int main(int argc, char *argv[]) {
  @autoreleasepool {
    // ── Init serial HID dispatch queue FIRST (before any touch API) ──
    gHIDQueue =
        dispatch_queue_create("com.ioscontrol.hid", DISPATCH_QUEUE_SERIAL);
    gScreenQueue =
        dispatch_queue_create("com.ioscontrol.screen", DISPATCH_QUEUE_SERIAL);

    // ── Daemonize completely ──
    // setsid(): create new session, detach from parent process group
    // This prevents iOS from killing us when the parent app is suspended
    setsid();

    // Ignore all common kill signals — daemon should only die via exit()
    signal(SIGTERM, handleSignal); // graceful shutdown
    signal(SIGHUP, SIG_IGN);       // hangup from terminal
    signal(SIGPIPE, SIG_IGN);      // broken pipe (socket died)
    signal(SIGINT, SIG_IGN);       // Ctrl-C
    signal(SIGQUIT, SIG_IGN);      // quit signal

    // ── Anti-Jetsam: full suite of memorystatus tricks ──
    // cmd 16 = MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT (disable memory limit)
    int r1 = memorystatus_control(16, getpid(), 0, NULL, 0);
    // cmd 5  = MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES — set to foreground
    // priority priority 10 = JETSAM_PRIORITY_FOREGROUND (same as foreground
    // apps)
    struct {
      int32_t priority;
      uint32_t user_data;
    } props = {10, 0};
    int r2 = memorystatus_control(5, getpid(), 0, &props, sizeof(props));
    // cmd 4  = MEMORYSTATUS_CMD_SET_DIRTY_PROCESS_STATE — mark as "dirty" (not
    // killable by idle)
    int r3 = memorystatus_control(4, getpid(), 1, NULL, 0);
    logMsg("🛡️ Jetsam: limit=%d priority=%d dirty=%d", r1, r2, r3);

    // ── Process priority boost ──
    // setpriority PRIO_PROCESS -5 → higher scheduling priority (daemon-like)
    setpriority(PRIO_PROCESS, 0, -5);

    logMsg("═══════════════════════════════════════");
    logMsg("🚀 IOSControl Daemon started (PID: %d, SID: %d)", getpid(),
           (int)getsid(0));
    logMsg("═══════════════════════════════════════");

    // ── Parse screen size from args (passed by app) ──
    if (argc >= 3) {
      gScreenW = atof(argv[1]);
      gScreenH = atof(argv[2]);
    }
    logMsg("📱 Screen: %.0f × %.0f", gScreenW, gScreenH);

    // ── Load HID symbols ──
    loadHIDSymbols();

    // ── Start capturing real touch SenderID ──
    startSenderIDCapture();

    // ── Start keyboard capture (Volume Down → tap) ──
    startKeyboardCapture();

    // ── Watchdog: auto-exit when app is uninstalled ──
    {
      // Get our own executable path
      static char execPath[1024];
      uint32_t pathSize = sizeof(execPath);
      if (_NSGetExecutablePath(execPath, &pathSize) == 0) {
        logMsg("👁️ Watchdog: monitoring %s", execPath);

        // Timer fires every 5 seconds
        CFRunLoopTimerRef timer = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + 5.0, // first fire
            5.0,                              // interval
            0, 0, ^(CFRunLoopTimerRef t) {
              if (access(execPath, F_OK) != 0) {
                logMsg("💀 Watchdog: app uninstalled, daemon exiting");
                exit(0);
              }
            });
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, kCFRunLoopDefaultMode);
        CFRelease(timer);
      } else {
        logMsg("⚠️ Watchdog: failed to get executable path");
      }
    }

    // ── Start HTTP Server (Phase 2) ──
    ic_startHTTPServer(46952);

    // ── Init Screen Capture (Phase 3) ──
    ic_initScreenCapture();

    // ── Init Lua Scripting Engine (Phase 5) ──
    ic_luaInit();

    logMsg("═══════════════════════════════════════");
    logMsg(
        "🎮 Daemon ready! HTTP on :46952, Screen Capture active, Lua ready.");
    logMsg("═══════════════════════════════════════");

    // ── Run forever ──
    CFRunLoopRun();
  }
  return 0;
}
