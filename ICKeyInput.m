// ICKeyInput.m — HID Keyboard input dispatch for IOSControl daemon
// Reuses same HID dispatch infrastructure as touch events
// kIOHIDEventTypeKeyboard = 3 (confirmed from XXTouch source)

#import "ICKeyInput.h"
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <objc/message.h>

extern void logMsg(const char *fmt, ...);
extern uint64_t gSenderID;
extern uint64_t gHWSenderID;
// gKeyboardDispatchClient (Admin type=2) and gDispatchClient are created and
// scheduled on the main run loop by IOSControlDaemon.m — reuse them here.
extern void *gKeyboardDispatchClient;
extern void *gDispatchClient;

// ═══════════════════════════════════════════
// IOHIDEvent type + field constants
// (confirmed from XXTouch Lua source & lessons.md)
// ═══════════════════════════════════════════

typedef void *IOHIDEventRef;
typedef void *IOHIDEventSystemClientRef;

// kIOHIDEventTypeKeyboard = 3
static const uint32_t kIOHIDEventTypeKeyboard = 3;

// Field constants (from XXTouch: 196608 = 0x30000, 196609 = 0x30001, 196610 =
// 0x30002)
static const uint32_t kFieldKeyboardUsagePage = 0x00030000;
static const uint32_t kFieldKeyboardUsage = 0x00030001;
static const uint32_t kFieldKeyboardDown = 0x00030002;

// ═══════════════════════════════════════════
// Dynamic symbol pointers (loaded once)
// ═══════════════════════════════════════════

static IOHIDEventRef (*_IOHIDEventCreateKeyboardEvent)(CFAllocatorRef, uint64_t,
                                                       uint32_t, uint32_t,
                                                       Boolean,
                                                       uint32_t) = NULL;

static void (*_IOHIDEventSystemClientDispatchEvent)(IOHIDEventSystemClientRef,
                                                    IOHIDEventRef) = NULL;

static IOHIDEventSystemClientRef (*_IOHIDEventSystemClientCreate)(
    CFAllocatorRef) = NULL;

static void (*_IOHIDEventSetSenderID)(IOHIDEventRef, uint64_t) = NULL;

// No local client needed — use global clients from IOSControlDaemon.m

static void loadKeySymbols(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    void *hnd = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit",
                       RTLD_NOW | RTLD_NOLOAD);
    if (!hnd)
      hnd =
          dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!hnd) {
      logMsg("❌ [KeyInput] Cannot load IOKit");
      return;
    }
    _IOHIDEventCreateKeyboardEvent =
        dlsym(hnd, "IOHIDEventCreateKeyboardEvent");
    _IOHIDEventSystemClientDispatchEvent =
        dlsym(hnd, "IOHIDEventSystemClientDispatchEvent");
    _IOHIDEventSystemClientCreate = dlsym(hnd, "IOHIDEventSystemClientCreate");
    _IOHIDEventSetSenderID = dlsym(hnd, "IOHIDEventSetSenderID");

    logMsg("⌨️ [KeyInput] Symbols: createKbd=%d dispatch=%d create=%d",
           !!_IOHIDEventCreateKeyboardEvent,
           !!_IOHIDEventSystemClientDispatchEvent,
           !!_IOHIDEventSystemClientCreate);
  });
}

// ═══════════════════════════════════════════
// Internal: dispatch a single key event (down or up)
// ═══════════════════════════════════════════

static BOOL dispatchKeyEvent(uint32_t usagePage, uint32_t usage, BOOL down) {
  loadKeySymbols();

  if (!_IOHIDEventCreateKeyboardEvent ||
      !_IOHIDEventSystemClientDispatchEvent) {
    logMsg("❌ [KeyInput] Required symbols not loaded");
    return NO;
  }

  uint64_t ts = mach_absolute_time();
  IOHIDEventRef evt = _IOHIDEventCreateKeyboardEvent(
      kCFAllocatorDefault, ts, usagePage, usage, down ? 1 : 0, 0);
  if (!evt) {
    logMsg("❌ [KeyInput] IOHIDEventCreateKeyboardEvent returned nil");
    return NO;
  }

  // Use real HW senderID (priority: keyboard HW → touch HW → fallback)
  if (_IOHIDEventSetSenderID) {
    uint64_t sid = gHWSenderID
                       ? gHWSenderID
                       : (gSenderID ? gSenderID : 0x000000010000027FULL);
    _IOHIDEventSetSenderID(evt, sid);
  }

  // Use global clients scheduled on main run loop (from IOSControlDaemon.m)
  // gKeyboardDispatchClient = Admin type, gDispatchClient = fallback
  void *client =
      gKeyboardDispatchClient ? gKeyboardDispatchClient : gDispatchClient;
  if (client) {
    _IOHIDEventSystemClientDispatchEvent(client, evt);
  } else {
    logMsg("❌ [KeyInput] No dispatch client available");
    CFRelease(evt);
    return NO;
  }

  CFRelease(evt);
  return YES;
}

// ═══════════════════════════════════════════
// Public API
// ═══════════════════════════════════════════

BOOL ic_keyPress(uint32_t usagePage, uint32_t usage) {
  BOOL down = dispatchKeyEvent(usagePage, usage, YES);
  usleep(50000); // 50ms hold
  BOOL up = dispatchKeyEvent(usagePage, usage, NO);
  logMsg("⌨️ [KeyInput] key page=0x%X usage=0x%X down=%d up=%d", usagePage,
         usage, down, up);
  return down && up;
}

// Basic ASCII → HID keyboard mapping (HID usage page 0x07)
static uint32_t asciiToHIDUsage(char c, BOOL *needsShift) {
  *needsShift = NO;
  // A-Z → 0x04–0x1D
  if (c >= 'a' && c <= 'z')
    return 0x04 + (c - 'a');
  if (c >= 'A' && c <= 'Z') {
    *needsShift = YES;
    return 0x04 + (c - 'A');
  }
  // 1–9 → 0x1E–0x26, 0 → 0x27
  if (c >= '1' && c <= '9')
    return 0x1E + (c - '1');
  if (c == '0')
    return 0x27;
  // Space
  if (c == ' ')
    return 0x2C;
  if (c == '\n' || c == '\r')
    return 0x28; // Return
  if (c == '\t')
    return 0x2B; // Tab
  if (c == '.')
    return 0x37;
  if (c == ',')
    return 0x36;
  if (c == '!') {
    *needsShift = YES;
    return 0x1E;
  }
  if (c == '@') {
    *needsShift = YES;
    return 0x1F;
  }
  if (c == '#') {
    *needsShift = YES;
    return 0x20;
  }
  if (c == '$') {
    *needsShift = YES;
    return 0x21;
  }
  if (c == '%') {
    *needsShift = YES;
    return 0x22;
  }
  if (c == '^') {
    *needsShift = YES;
    return 0x23;
  }
  if (c == '&') {
    *needsShift = YES;
    return 0x24;
  }
  if (c == '*') {
    *needsShift = YES;
    return 0x25;
  }
  if (c == '(') {
    *needsShift = YES;
    return 0x26;
  }
  if (c == ')') {
    *needsShift = YES;
    return 0x27;
  }
  if (c == '-')
    return 0x2D;
  if (c == '_') {
    *needsShift = YES;
    return 0x2D;
  }
  if (c == '=')
    return 0x2E;
  if (c == '+') {
    *needsShift = YES;
    return 0x2E;
  }
  if (c == '[')
    return 0x2F;
  if (c == ']')
    return 0x30;
  if (c == '\\')
    return 0x31;
  if (c == ';')
    return 0x33;
  if (c == '\'')
    return 0x34;
  if (c == '`')
    return 0x35;
  if (c == '/')
    return 0x38;
  if (c == '?') {
    *needsShift = YES;
    return 0x38;
  }
  return 0; // Unsupported
}

// Check if string has non-ASCII chars (Vietnamese, emoji, Chinese, etc.)
static BOOL hasNonASCII(NSString *s) {
  for (NSUInteger i = 0; i < s.length; i++) {
    if ([s characterAtIndex:i] > 127)
      return YES;
  }
  return NO;
}

// ─────────────────────────────────────────────────────────────────────
// ic_inputUnicodeText — paste arbitrary Unicode text via clipboard
// Works for Vietnamese, Chinese, emoji, etc.
// Steps:
//   1. Save current clipboard content
//   2. Set clipboard = text
//   3. Inject Cmd+V (Command+V) via HID
//   4. Wait a moment, then restore clipboard
// ─────────────────────────────────────────────────────────────────────
BOOL ic_inputUnicodeText(NSString *text) {
  if (!text.length)
    return NO;

  // Daemon cannot write to UIPasteboard (no UIApplication context).
  // Use IPC: write text to temp file → post Darwin notification →
  // main UIKit app reads file and sets system clipboard.
  NSString *path = @"/tmp/ioscontrol_paste_text.txt";
  NSError *err;
  BOOL ok = [text writeToFile:path
                   atomically:YES
                     encoding:NSUTF8StringEncoding
                        error:&err];
  if (!ok) {
    logMsg("❌ [KeyInput] IPC write failed: %s",
           err.localizedDescription.UTF8String ?: "?");
    return NO;
  }
  logMsg("📋 [KeyInput] IPC: wrote '%s' → notify main app", text.UTF8String);

  // Post Darwin notification → AppDelegate.m reads file and sets UIPasteboard
  CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(),
      CFSTR("com.ioscontrol.setPasteboard"), NULL, NULL, YES);

  // Wait for main app to process and iOS XPC to propagate clipboard (~300ms
  // total)
  usleep(400000); // 400ms

  // Inject Cmd+V on MAIN queue (HID client run loop thread)
  void (^cmdV)(void) = ^{
    dispatchKeyEvent(0x07, 0xE3, YES); // Command down
    usleep(50000);
    dispatchKeyEvent(0x07, 0x19, YES); // V down
    usleep(80000);
    dispatchKeyEvent(0x07, 0x19, NO); // V up
    usleep(50000);
    dispatchKeyEvent(0x07, 0xE3, NO); // Command up
    logMsg("⌨️ [KeyInput] Cmd+V sent for: %s", text.UTF8String);
  };

  if ([NSThread isMainThread]) {
    cmdV();
  } else {
    dispatch_sync(dispatch_get_main_queue(), cmdV);
  }

  return YES;
}

BOOL ic_keyInputText(NSString *text) {
  if (!text.length)
    return NO;

  // Unicode text (Vietnamese, emoji, etc.) → clipboard + paste
  if (hasNonASCII(text)) {
    return ic_inputUnicodeText(text);
  }

  // Pure ASCII → HID key-by-key (faster, no clipboard side-effects)
  const char *str = text.UTF8String;
  int count = 0;
  for (int i = 0; str[i]; i++) {
    BOOL shift = NO;
    uint32_t usage = asciiToHIDUsage(str[i], &shift);
    if (usage == 0)
      continue;

    if (shift)
      dispatchKeyEvent(0x07, 0xE1, YES);
    ic_keyPress(0x07, usage);
    if (shift)
      dispatchKeyEvent(0x07, 0xE1, NO);

    usleep(30000); // 30ms between chars
    count++;
  }
  logMsg("⌨️ [KeyInput] inputText ASCII: %d chars", count);
  return count > 0;
}
