// IOSControl Tweak.xm — Phase 1: HID Touch Injection
// Injects into SpringBoard, provides system-level touch simulation
// Based on SimulateTouch/Veency IOHIDEvent approach

#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <AudioToolbox/AudioToolbox.h>
#import <spawn.h>
#import <math.h>
#import "src/IOSControl.h"

// ═══════════════════════════════════════════
// IOHIDEvent type declarations
// ═══════════════════════════════════════════

typedef void *IOHIDEventRef;
typedef void *IOHIDEventSystemClientRef;
typedef void *IOHIDServiceRef;
typedef uint32_t IOHIDEventType;

static const IOHIDEventType kIOHIDEventTypeDigitizer = 11;

// Digitizer event masks
enum {
    kIOHIDDigitizerEventRange    = 0x00000001,
    kIOHIDDigitizerEventTouch    = 0x00000002,
    kIOHIDDigitizerEventPosition = 0x00000004,
};

// Touch types
enum {
    TOUCH_DOWN = 1,
    TOUCH_MOVE = 2,
    TOUCH_UP   = 3,
};

// Digitizer event field IDs
enum {
    kIOHIDEventFieldDigitizerX                   = 0x000B0001,
    kIOHIDEventFieldDigitizerY                   = 0x000B0002,
    kIOHIDEventFieldDigitizerMask                = 0x000B000D,
    kIOHIDEventFieldDigitizerRange               = 0x000B0007,
    kIOHIDEventFieldDigitizerTouch               = 0x000B0008,
    kIOHIDEventFieldDigitizerEventMask           = 0x000B000C,
    kIOHIDEventFieldDigitizerDisplayIntegrated   = 0x000B0019,
    kIOHIDEventFieldBuiltIn                      = 0x00000004,
};

#define kIOHIDDigitizerEventIdentity 32  // 0x20

// ═══════════════════════════════════════════
// IOHIDEvent function pointers (loaded at runtime via dlsym)
// ═══════════════════════════════════════════

// NOTE: IOHIDFloat = double on arm64 (LP64). Using float here causes
// ARM64 calling convention mismatch (s-regs vs d-regs) → garbled coordinates!

static IOHIDEventSystemClientRef (*_SystemClientCreate)(CFAllocatorRef);
static void (*_SystemClientDispatchEvent)(IOHIDEventSystemClientRef, IOHIDEventRef);
static void (*_SystemClientScheduleWithRunLoop)(IOHIDEventSystemClientRef, CFRunLoopRef, CFRunLoopMode);
static void (*_SystemClientRegisterEventCallback)(IOHIDEventSystemClientRef, void*, void*, void*);

static IOHIDEventRef (*_CreateDigitizerEvent)(CFAllocatorRef, uint64_t, uint32_t, uint32_t,
    uint32_t, uint32_t, uint32_t, double, double, double, double, double,
    Boolean, Boolean, uint32_t);
static IOHIDEventRef (*_CreateFingerEvent)(CFAllocatorRef, uint64_t, uint32_t, uint32_t,
    uint32_t, double, double, double, double, double, Boolean, Boolean, uint32_t);
static void (*_AppendEvent)(IOHIDEventRef, IOHIDEventRef, uint32_t);
static void (*_SetSenderID)(IOHIDEventRef, uint64_t);
static uint64_t (*_GetSenderID)(IOHIDEventRef);
static IOHIDEventType (*_GetType)(IOHIDEventRef);
static int64_t (*_GetIntegerValue)(IOHIDEventRef, uint32_t);
static void (*_SetIntegerValue)(IOHIDEventRef, uint32_t, int64_t);
static void (*_SetFloatValue)(IOHIDEventRef, uint32_t, double);
static double (*_GetFloatValue)(IOHIDEventRef, uint32_t);
static void (*_SetIntegerValueWithOptions)(IOHIDEventRef, uint32_t, int64_t, int32_t);

// ═══════════════════════════════════════════
// Global state
// ═══════════════════════════════════════════

static double gScreenW = 0;
static double gScreenH = 0;
static uint64_t gSenderID = 0;
static IOHIDEventSystemClientRef gDispatchClient = NULL;
static IOHIDEventSystemClientRef gCaptureClient = NULL;
static FILE *gLogFile = NULL;

// ═══════════════════════════════════════════
// Logging
// ═══════════════════════════════════════════

void logMsg(const char *fmt, ...) {
    if (!gLogFile) gLogFile = fopen("/var/tmp/ioscontrol.log", "a");
    if (!gLogFile) return;
    va_list args;
    va_start(args, fmt);
    vfprintf(gLogFile, fmt, args);
    va_end(args);
    fprintf(gLogFile, "\n");
    fflush(gLogFile);
}

// ═══════════════════════════════════════════
// Screen size detection
// ═══════════════════════════════════════════

static void ensureScreenSize(void) {
    if (gScreenW > 0 && gScreenH > 0) return;
    CGSize sz = [UIScreen mainScreen].bounds.size;
    if (sz.width > 0 && sz.height > 0) {
        gScreenW = sz.width;
        gScreenH = sz.height;
        logMsg("📱 Screen: %.0f × %.0f", gScreenW, gScreenH);
    } else {
        gScreenW = 393.0;  // iPhone 15 Pro
        gScreenH = 852.0;
        logMsg("⚠️ Screen fallback: 393 × 852");
    }
}

// ═══════════════════════════════════════════
// SenderID auto-capture from real touch events
// ═══════════════════════════════════════════

static void senderIDCallback(void *target, void *refcon, IOHIDServiceRef service, IOHIDEventRef event) {
    if (!_GetType) return;
    IOHIDEventType type = _GetType(event);

    if (type == kIOHIDEventTypeDigitizer && gSenderID == 0 && _GetSenderID) {
        gSenderID = _GetSenderID(event);
        logMsg("✅ Input source captured: 0x%llX", gSenderID);
    }
}

static void startSenderIDCapture(void) {
    if (!_SystemClientCreate || !_SystemClientScheduleWithRunLoop || !_SystemClientRegisterEventCallback) {
        logMsg("❌ Cannot init input capture — missing symbols");
        return;
    }
    gCaptureClient = _SystemClientCreate(kCFAllocatorDefault);
    if (gCaptureClient) {
        _SystemClientScheduleWithRunLoop(gCaptureClient, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
        _SystemClientRegisterEventCallback(gCaptureClient, (void*)senderIDCallback, NULL, NULL);
        logMsg("🎧 Input capture active — waiting for first touch");
    }
}

// ═══════════════════════════════════════════
// Keyboard / Volume Button Testing
// ═══════════════════════════════════════════

static IOHIDEventSystemClientRef gKeyboardClient = NULL;

static void keyboardEventCallback(void *target, void *refcon, IOHIDServiceRef service, IOHIDEventRef event) {
    if (!_GetType || !_GetIntegerValue) return;
    IOHIDEventType type = _GetType(event);
    
    if (type != 7) return; // kIOHIDEventTypeKeyboard
    
    int64_t usagePage = _GetIntegerValue(event, 0x00070004); // UsagePage
    int64_t usage = _GetIntegerValue(event, 0x00070005);     // Usage
    int64_t down = _GetIntegerValue(event, 0x00070006);      // Down
    
    // Volume Down (Page: 0x0C, Usage: 0xEA)
    if (usagePage == 0x0C && usage == 0xEA && down == 1) {
        dispatch_async(dispatch_get_main_queue(), ^{
            logMsg("⚡ TEST TRIGGER: Volume Down pressed. Tapping center screen...");
            ic_showToast(@"Test: Tapping center...");
            ic_tap(gScreenW / 2, gScreenH / 2);
        });
    }
}

static void startKeyboardCapture(void) {
    if (!_SystemClientCreate || !_SystemClientScheduleWithRunLoop || !_SystemClientRegisterEventCallback) return;
    gKeyboardClient = _SystemClientCreate(kCFAllocatorDefault);
    if (gKeyboardClient) {
        _SystemClientScheduleWithRunLoop(gKeyboardClient, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
        _SystemClientRegisterEventCallback(gKeyboardClient, (void *)keyboardEventCallback, NULL, NULL);
        logMsg("🎧 Keyboard capture active for testing (Vol-)");
    }
}

// ═══════════════════════════════════════════
// Touch Visual Indicator
// ═══════════════════════════════════════════

static UIWindow *gTouchWindow = nil;
static NSMutableDictionary *gTouchDots = nil;
static BOOL gShowTouchIndicator = YES;

static void cleanupDot(NSNumber *key) {
    UIView *dot = gTouchDots[key];
    if (dot) {
        [UIView animateWithDuration:0.2 animations:^{
            dot.alpha = 0;
            dot.transform = CGAffineTransformMakeScale(1.5, 1.5);
        } completion:^(BOOL finished) {
            [dot removeFromSuperview];
            [gTouchDots removeObjectForKey:key];
        }];
    }
}

static void showTouchIndicator(double ptX, double ptY, int finger, int touchType) {
    if (!gShowTouchIndicator) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        // Create overlay window if needed
        if (!gTouchWindow) {
            UIWindowScene *windowScene = nil;
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]]) {
                    windowScene = (UIWindowScene *)scene;
                    break;
                }
            }
            if (windowScene) {
                gTouchWindow = [[UIWindow alloc] initWithWindowScene:windowScene];
            } else {
                gTouchWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
            }
            gTouchWindow.windowLevel = UIWindowLevelStatusBar + 200;
            gTouchWindow.backgroundColor = [UIColor clearColor];
            gTouchWindow.userInteractionEnabled = NO;
            gTouchWindow.hidden = NO;
            gTouchDots = [NSMutableDictionary new];
        }

        NSNumber *key = @(finger);
        CGFloat dotSize = 28.0;

        if (touchType == TOUCH_DOWN) {
            UIView *oldDot = gTouchDots[key];
            if (oldDot) { [oldDot removeFromSuperview]; [gTouchDots removeObjectForKey:key]; }

            UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, dotSize, dotSize)];
            dot.backgroundColor = [UIColor clearColor];
            dot.layer.cornerRadius = dotSize / 2;
            dot.layer.borderWidth = 2.5;
            dot.layer.borderColor = [UIColor colorWithRed:0.35 green:0.78 blue:1.0 alpha:0.9].CGColor;
            dot.layer.shadowColor = [UIColor colorWithRed:0.35 green:0.78 blue:1.0 alpha:1.0].CGColor;
            dot.layer.shadowRadius = 6;
            dot.layer.shadowOpacity = 0.6;
            dot.layer.shadowOffset = CGSizeZero;
            dot.center = CGPointMake(ptX, ptY);
            dot.transform = CGAffineTransformMakeScale(0.1, 0.1);
            dot.alpha = 0;
            [gTouchWindow addSubview:dot];
            gTouchDots[key] = dot;

            [UIView animateWithDuration:0.12 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
                dot.transform = CGAffineTransformIdentity;
                dot.alpha = 1;
            } completion:nil];

            // Auto-cleanup after 2s (safety net)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (gTouchDots[key] == dot) { cleanupDot(key); }
            });
        }
        else if (touchType == TOUCH_MOVE) {
            UIView *dot = gTouchDots[key];
            if (dot) { dot.center = CGPointMake(ptX, ptY); }
        }
        else if (touchType == TOUCH_UP) {
            cleanupDot(key);
        }
    });
}

// ═══════════════════════════════════════════
// Core Touch Dispatch (SimulateTouch approach)
// ═══════════════════════════════════════════

static void dispatchTouch(double x, double y, int finger, int touchType) {
    ensureScreenSize();
    showTouchIndicator(x, y, finger, touchType);

    // Normalize coordinates (0.0-1.0)
    double normX = x / gScreenW;
    double normY = y / gScreenH;
    if (normX < 0) normX = 0; if (normX > 1) normX = 1;
    if (normY < 0) normY = 0; if (normY > 1) normY = 1;

    Boolean isTouching = (touchType != TOUCH_UP);
    int touch = isTouching ? 1 : 0;

    // Event masks: DOWN/UP = range|touch|identity(35), MOVE = position(4)
    int fingerMask;
    if (touchType == TOUCH_MOVE) {
        fingerMask = kIOHIDDigitizerEventPosition;
    } else {
        fingerMask = kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventIdentity;
    }

    uint64_t timestamp = mach_absolute_time();

    // Parent hand event (coordinates at 0,0 — finger child has real coords)
    IOHIDEventRef handEvent = _CreateDigitizerEvent(
        kCFAllocatorDefault, timestamp,
        3,    // kIOHIDTransducerTypeHand
        0, 1, // index=0, identity=1
        0, 0, // eventMask=0, buttonMask=0
        0, 0, 0,    // x=0, y=0, z=0
        0, 0,       // pressure=0, barrel=0
        0, 0, 0     // range=0, touch=0, options=0
    );

    // Set display-integrated flags (required for BackBoard routing)
    if (_SetIntegerValueWithOptions) {
        _SetIntegerValueWithOptions(handEvent, kIOHIDEventFieldDigitizerDisplayIntegrated, 1, -268435456);
        _SetIntegerValueWithOptions(handEvent, kIOHIDEventFieldBuiltIn, 1, -268435456);
    } else if (_SetIntegerValue) {
        _SetIntegerValue(handEvent, kIOHIDEventFieldDigitizerDisplayIntegrated, 1);
        _SetIntegerValue(handEvent, kIOHIDEventFieldBuiltIn, 1);
    }

    // Use captured SenderID or fallback
    uint64_t sid = gSenderID ? gSenderID : 0x000000010000027FULL;
    _SetSenderID(handEvent, sid);

    // Child finger event with normalized coordinates
    IOHIDEventRef fingerEvent = _CreateFingerEvent(
        kCFAllocatorDefault, timestamp,
        finger,         // index
        finger + 2,     // identity (SimulateTouch convention: i+2)
        fingerMask,
        normX, normY, 0.0,           // x, y, z
        isTouching ? 1.0 : 0.0,     // pressure
        0.0,                          // twist
        isTouching, isTouching, 0    // range, touch, options
    );

    _AppendEvent(handEvent, fingerEvent, 0);

    // Set parent event mask after appending child
    int handMask = fingerMask;
    if (touchType == TOUCH_UP) {
        handMask |= kIOHIDDigitizerEventPosition;
    }

    if (_SetIntegerValueWithOptions) {
        _SetIntegerValueWithOptions(handEvent, kIOHIDEventFieldDigitizerEventMask, handMask, -268435456);
        _SetIntegerValueWithOptions(handEvent, kIOHIDEventFieldDigitizerRange, touch, -268435456);
        _SetIntegerValueWithOptions(handEvent, kIOHIDEventFieldDigitizerTouch, touch, -268435456);
    } else if (_SetIntegerValue) {
        _SetIntegerValue(handEvent, kIOHIDEventFieldDigitizerEventMask, handMask);
        _SetIntegerValue(handEvent, kIOHIDEventFieldDigitizerRange, touch);
        _SetIntegerValue(handEvent, kIOHIDEventFieldDigitizerTouch, touch);
    }

    // Wake the event system (BackBoard)
    Class timerClass = NSClassFromString(@"BKUserEventTimer");
    if (timerClass) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id timer = [timerClass performSelector:NSSelectorFromString(@"sharedInstance")];
        SEL displaySel = NSSelectorFromString(@"userEventOccurredOnDisplay:");
        SEL simpleSel = NSSelectorFromString(@"userEventOccurred");
        if ([timer respondsToSelector:displaySel]) {
            [timer performSelector:displaySel withObject:nil];
        } else if ([timer respondsToSelector:simpleSel]) {
            [timer performSelector:simpleSel];
        }
        #pragma clang diagnostic pop
    }

    logMsg("🎯 touch pt=(%.0f,%.0f) norm=(%.3f,%.3f) type=%d finger=%d sid=0x%llX",
           x, y, normX, normY, touchType, finger, sid);

    // Dispatch via dedicated HID client
    if (!gDispatchClient) {
        gDispatchClient = _SystemClientCreate(kCFAllocatorDefault);
    }
    _SystemClientDispatchEvent(gDispatchClient, handEvent);

    CFRelease(fingerEvent);
    CFRelease(handEvent);
}

// Multi-touch: two fingers in one hand event (for pinch/rotate)
static void dispatchMultiTouch(double x1, double y1, int f1,
                                double x2, double y2, int f2,
                                int touchType) {
    ensureScreenSize();
    showTouchIndicator(x1, y1, f1, touchType);
    showTouchIndicator(x2, y2, f2, touchType);

    double nx1 = fmin(fmax(x1 / gScreenW, 0), 1);
    double ny1 = fmin(fmax(y1 / gScreenH, 0), 1);
    double nx2 = fmin(fmax(x2 / gScreenW, 0), 1);
    double ny2 = fmin(fmax(y2 / gScreenH, 0), 1);

    Boolean isTouching = (touchType != TOUCH_UP);
    int touch = isTouching ? 1 : 0;
    int fingerMask = (touchType == TOUCH_MOVE)
        ? kIOHIDDigitizerEventPosition
        : (kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventIdentity);

    uint64_t timestamp = mach_absolute_time();

    IOHIDEventRef handEvent = _CreateDigitizerEvent(
        kCFAllocatorDefault, timestamp, 3, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    if (_SetIntegerValueWithOptions) {
        _SetIntegerValueWithOptions(handEvent, kIOHIDEventFieldDigitizerDisplayIntegrated, 1, -268435456);
        _SetIntegerValueWithOptions(handEvent, kIOHIDEventFieldBuiltIn, 1, -268435456);
    }

    uint64_t sid = gSenderID ? gSenderID : 0x000000010000027FULL;
    _SetSenderID(handEvent, sid);

    // Finger 1
    IOHIDEventRef fe1 = _CreateFingerEvent(
        kCFAllocatorDefault, timestamp, f1, f1 + 2, fingerMask,
        nx1, ny1, 0.0, isTouching ? 1.0 : 0.0, 0.0, isTouching, isTouching, 0);
    _AppendEvent(handEvent, fe1, 0);

    // Finger 2
    IOHIDEventRef fe2 = _CreateFingerEvent(
        kCFAllocatorDefault, timestamp, f2, f2 + 2, fingerMask,
        nx2, ny2, 0.0, isTouching ? 1.0 : 0.0, 0.0, isTouching, isTouching, 0);
    _AppendEvent(handEvent, fe2, 0);

    int handMask = fingerMask;
    if (touchType == TOUCH_UP) handMask |= kIOHIDDigitizerEventPosition;

    if (_SetIntegerValueWithOptions) {
        _SetIntegerValueWithOptions(handEvent, kIOHIDEventFieldDigitizerEventMask, handMask, -268435456);
        _SetIntegerValueWithOptions(handEvent, kIOHIDEventFieldDigitizerRange, touch, -268435456);
        _SetIntegerValueWithOptions(handEvent, kIOHIDEventFieldDigitizerTouch, touch, -268435456);
    }

    // Wake
    Class timerClass = NSClassFromString(@"BKUserEventTimer");
    if (timerClass) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id timer = [timerClass performSelector:NSSelectorFromString(@"sharedInstance")];
        SEL sel = NSSelectorFromString(@"userEventOccurredOnDisplay:");
        if ([timer respondsToSelector:sel]) [timer performSelector:sel withObject:nil];
        #pragma clang diagnostic pop
    }

    if (!gDispatchClient) gDispatchClient = _SystemClientCreate(kCFAllocatorDefault);
    _SystemClientDispatchEvent(gDispatchClient, handEvent);

    CFRelease(fe1);
    CFRelease(fe2);
    CFRelease(handEvent);
}

// ═══════════════════════════════════════════
// Public Touch API
// ═══════════════════════════════════════════

void ic_touchDown(double x, double y, int finger) { dispatchTouch(x, y, finger, TOUCH_DOWN); }
void ic_touchMove(double x, double y, int finger) { dispatchTouch(x, y, finger, TOUCH_MOVE); }
void ic_touchUp(double x, double y, int finger)   { dispatchTouch(x, y, finger, TOUCH_UP); }

void ic_tap(double x, double y) {
    dispatchTouch(x, y, 0, TOUCH_DOWN);
    usleep(80000);  // 80ms hold
    dispatchTouch(x, y, 0, TOUCH_UP);
}

void ic_swipe(double x1, double y1, double x2, double y2, double duration) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        int steps = MAX(10, (int)(duration * 60));  // ~60fps
        double dx = (x2 - x1) / steps;
        double dy = (y2 - y1) / steps;
        useconds_t delay = (useconds_t)((duration / steps) * 1000000);

        dispatchTouch(x1, y1, 0, TOUCH_DOWN);
        usleep(30000);  // 30ms hold before move

        for (int i = 1; i <= steps; i++) {
            usleep(delay);
            dispatchTouch(x1 + dx*i, y1 + dy*i, 0, TOUCH_MOVE);
        }
        usleep(16000);
        dispatchTouch(x2, y2, 0, TOUCH_UP);
    });
}

void ic_longPress(double x, double y, double duration) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        dispatchTouch(x, y, 0, TOUCH_DOWN);
        usleep((useconds_t)(duration * 1000000));
        dispatchTouch(x, y, 0, TOUCH_UP);
    });
}

void ic_pinch(double cx, double cy, double scale, double duration) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        double startDist = 40.0;
        double endDist = startDist * scale;
        int steps = MAX(20, (int)(duration * 60));
        useconds_t delay = (useconds_t)((duration / steps) * 1000000);

        dispatchMultiTouch(cx - startDist, cy, 0, cx + startDist, cy, 1, TOUCH_DOWN);
        usleep(30000);

        for (int i = 1; i <= steps; i++) {
            double t = (double)i / steps;
            double d = startDist + (endDist - startDist) * t;
            usleep(delay);
            dispatchMultiTouch(cx - d, cy, 0, cx + d, cy, 1, TOUCH_MOVE);
        }
        usleep(16000);
        dispatchMultiTouch(cx - endDist, cy, 0, cx + endDist, cy, 1, TOUCH_UP);
    });
}

// ═══════════════════════════════════════════
// System Commands
// ═══════════════════════════════════════════

void ic_pressHome(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        Class uiCtrl = NSClassFromString(@"SBUIController");
        if (uiCtrl) {
            id ctrl = [uiCtrl performSelector:NSSelectorFromString(@"sharedInstance")];
            if (ctrl) {
                SEL homeSel = NSSelectorFromString(@"handleHomeButtonSinglePressUp");
                if ([ctrl respondsToSelector:homeSel]) {
                    [ctrl performSelector:homeSel];
                } else {
                    SEL menuSel = NSSelectorFromString(@"clickedMenuButton");
                    if ([ctrl respondsToSelector:menuSel]) [ctrl performSelector:menuSel];
                }
            }
        }
        #pragma clang diagnostic pop
    });
}

void ic_vibrate(void) {
    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
}

void ic_showToast(NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindowScene *windowScene = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                windowScene = (UIWindowScene *)scene;
                break;
            }
        }

        UIWindow *toastWindow;
        if (windowScene) {
            toastWindow = [[UIWindow alloc] initWithWindowScene:windowScene];
        } else {
            toastWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        }
        toastWindow.windowLevel = UIWindowLevelStatusBar + 100;
        toastWindow.backgroundColor = [UIColor clearColor];
        toastWindow.userInteractionEnabled = NO;
        toastWindow.hidden = NO;

        // Container with blur background
        UIView *container = [[UIView alloc] init];
        container.backgroundColor = [UIColor colorWithRed:0.08 green:0.08 blue:0.15 alpha:0.85];
        container.layer.cornerRadius = 14;
        container.layer.borderWidth = 0.5;
        container.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.12].CGColor;
        container.clipsToBounds = YES;

        UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
        UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
        blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [container addSubview:blurView];

        UILabel *label = [[UILabel alloc] init];
        label.text = message;
        label.textColor = [UIColor colorWithWhite:1.0 alpha:0.92];
        label.textAlignment = NSTextAlignmentCenter;
        label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        label.numberOfLines = 0;

        CGFloat maxW = MIN(300, toastWindow.bounds.size.width - 60);
        CGSize size = [label sizeThatFits:CGSizeMake(maxW, CGFLOAT_MAX)];
        CGFloat w = size.width + 36;
        CGFloat h = size.height + 20;
        CGFloat x = (toastWindow.bounds.size.width - w) / 2;
        CGFloat y = toastWindow.bounds.size.height - 130;

        container.frame = CGRectMake(x, y + 20, w, h);
        label.frame = CGRectMake(18, 10, size.width, size.height);
        blurView.frame = container.bounds;
        [container addSubview:label];
        container.alpha = 0;
        [toastWindow addSubview:container];

        [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0.5 options:0 animations:^{
            container.alpha = 1;
            container.frame = CGRectMake(x, y, w, h);
        } completion:nil];

        [UIView animateWithDuration:0.3 delay:2.0 options:0 animations:^{
            container.alpha = 0;
            container.frame = CGRectMake(x, y - 10, w, h);
        } completion:^(BOOL finished) {
            toastWindow.hidden = YES;
        }];
    });
}

void ic_launchApp(NSString *bundleId) {
    dispatch_async(dispatch_get_main_queue(), ^{
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        Class workspace = NSClassFromString(@"LSApplicationWorkspace");
        if (workspace) {
            id ws = [workspace performSelector:NSSelectorFromString(@"defaultWorkspace")];
            if (ws) {
                SEL openSel = NSSelectorFromString(@"openApplicationWithBundleID:");
                if ([ws respondsToSelector:openSel]) [ws performSelector:openSel withObject:bundleId];
            }
        }
        #pragma clang diagnostic pop
    });
}

void ic_killApp(NSString *bundleId) {
    NSString *procName = [bundleId componentsSeparatedByString:@"."].lastObject;
    pid_t spawnPid;
    const char *argv[] = { "/var/jb/usr/bin/killall", "-9", [procName UTF8String], NULL };
    extern char **environ;
    posix_spawn(&spawnPid, "/var/jb/usr/bin/killall", NULL, NULL, (char **)argv, environ);
}

// ═══════════════════════════════════════════
// Device Info
// ═══════════════════════════════════════════

NSDictionary* ic_deviceInfo(void) {
    ensureScreenSize();
    UIDevice *dev = [UIDevice currentDevice];
    return @{
        @"name": dev.name ?: @"",
        @"model": dev.model ?: @"",
        @"systemName": dev.systemName ?: @"",
        @"systemVersion": dev.systemVersion ?: @"",
        @"screenWidth": @(gScreenW),
        @"screenHeight": @(gScreenH),
        @"batteryLevel": @(dev.batteryLevel),
        @"version": @"0.1.0",
    };
}

void ic_getScreenSize(double *outW, double *outH) {
    ensureScreenSize();
    *outW = gScreenW;
    *outH = gScreenH;
}

int ic_getOrientation(void) {
    __block int orient = 0;
    if ([NSThread isMainThread]) {
        orient = (int)[[UIApplication sharedApplication] statusBarOrientation];
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            orient = (int)[[UIApplication sharedApplication] statusBarOrientation];
        });
    }
    switch (orient) {
        case UIInterfaceOrientationPortrait: return 0;
        case UIInterfaceOrientationPortraitUpsideDown: return 1;
        case UIInterfaceOrientationLandscapeLeft: return 2;
        case UIInterfaceOrientationLandscapeRight: return 3;
        default: return 0;
    }
}

NSString* ic_frontMostAppId(void) {
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    Class uiCtrl = NSClassFromString(@"SBUIController");
    if (uiCtrl) {
        id ctrl = [uiCtrl performSelector:NSSelectorFromString(@"sharedInstance")];
        if (ctrl) {
            SEL fgSel = NSSelectorFromString(@"foregroundApplicationBundleID");
            if ([ctrl respondsToSelector:fgSel]) {
                NSString *bundleId = [ctrl performSelector:fgSel];
                if (bundleId) return bundleId;
            }
        }
    }
    #pragma clang diagnostic pop
    return @"com.apple.springboard";
}

// ═══════════════════════════════════════════
// Load HID symbols at runtime
// ═══════════════════════════════════════════

static void loadHIDSymbols(void) {
    void *handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!handle) {
        logMsg("❌ Cannot load IOKit");
        return;
    }

    _SystemClientCreate = (typeof(_SystemClientCreate))dlsym(handle, "IOHIDEventSystemClientCreate");
    _SystemClientDispatchEvent = (typeof(_SystemClientDispatchEvent))dlsym(handle, "IOHIDEventSystemClientDispatchEvent");
    _SystemClientScheduleWithRunLoop = (typeof(_SystemClientScheduleWithRunLoop))dlsym(handle, "IOHIDEventSystemClientScheduleWithRunLoop");
    _SystemClientRegisterEventCallback = (typeof(_SystemClientRegisterEventCallback))dlsym(handle, "IOHIDEventSystemClientRegisterEventCallback");
    _CreateDigitizerEvent = (typeof(_CreateDigitizerEvent))dlsym(handle, "IOHIDEventCreateDigitizerEvent");
    _CreateFingerEvent = (typeof(_CreateFingerEvent))dlsym(handle, "IOHIDEventCreateDigitizerFingerEvent");
    _AppendEvent = (typeof(_AppendEvent))dlsym(handle, "IOHIDEventAppendEvent");
    _SetSenderID = (typeof(_SetSenderID))dlsym(handle, "IOHIDEventSetSenderID");
    _GetSenderID = (typeof(_GetSenderID))dlsym(handle, "IOHIDEventGetSenderID");
    _GetType = (typeof(_GetType))dlsym(handle, "IOHIDEventGetType");
    _GetIntegerValue = (typeof(_GetIntegerValue))dlsym(handle, "IOHIDEventGetIntegerValue");
    _SetIntegerValue = (typeof(_SetIntegerValue))dlsym(handle, "IOHIDEventSetIntegerValue");
    _SetFloatValue = (typeof(_SetFloatValue))dlsym(handle, "IOHIDEventSetFloatValue");
    _GetFloatValue = (typeof(_GetFloatValue))dlsym(handle, "IOHIDEventGetFloatValue");
    _SetIntegerValueWithOptions = (typeof(_SetIntegerValueWithOptions))dlsym(handle, "IOHIDEventSetIntegerValueWithOptions");

    logMsg("✅ HID symbols loaded (%d available)",
        !!_SystemClientCreate + !!_SystemClientDispatchEvent + !!_CreateDigitizerEvent +
        !!_CreateFingerEvent + !!_AppendEvent + !!_SetSenderID);
}

// ═══════════════════════════════════════════
// Tweak Constructor — all initialization here
// ═══════════════════════════════════════════

%ctor {
    @autoreleasepool {
        logMsg("═══════════════════════════════════════");
        logMsg("🚀 IOSControl v0.1.0 loading in SpringBoard");
        logMsg("═══════════════════════════════════════");

        // Load IOHIDEvent symbols
        loadHIDSymbols();

        // Start SenderID capture
        startSenderIDCapture();
        
        // Start keyboard capture for manual testing
        startKeyboardCapture();

        // Detect screen size (delayed — UIScreen not ready during %ctor)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ensureScreenSize();

            // Show boot toast
            ic_showToast(@"IOSControl v0.1.0 loaded ✅");

            logMsg("═══════════════════════════════════════");
            logMsg("🎮 IOSControl Phase 1 ready!");
            logMsg("═══════════════════════════════════════");
        });
    }
}
