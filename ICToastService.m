// ICToastService.m — Global toast overlay service (v5)
// IPC: file write + Darwin notification (reliable, no socket needed)
// Watchdog: daemon monitors /tmp/ictoast.pid and respawns if dead
//
// Flow:
// - Daemon spawns ICToastService
// - ICToastService writes PID to /tmp/ictoast.pid
// - Daemon watchdog checks every 3s: kill(pid,0) → respawn if dead
// - sys.toast() → write /tmp/ictoast_payload.json → Darwin notify
// - ICToastService receives notify → reads file → shows toast

#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <unistd.h>
#import <signal.h>

// ─── Constants ─────────────────────────────────────────────────────────────
static NSString *const kToastPayloadFile = @"/tmp/ictoast_payload.json";
static NSString *const kToastPIDFile     = @"/tmp/ictoast.pid";
static CFStringRef  kToastNotifyName    = CFSTR("com.ioscontrol.toast.show");

// ─── Logging ───────────────────────────────────────────────────────────────
static void ictlog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void ictlog(NSString *fmt, ...) {
  va_list args;
  va_start(args, fmt);
  NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
  va_end(args);
  NSLog(@"🍞 ICToastService: %@", msg);

  NSString *log = [NSString stringWithFormat:@"%@: %@\n", [NSDate date], msg];
  NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:@"/tmp/ictoast_log.txt"];
  if (!fh) {
    [@"" writeToFile:@"/tmp/ictoast_log.txt" atomically:NO
            encoding:NSUTF8StringEncoding error:nil];
    fh = [NSFileHandle fileHandleForWritingAtPath:@"/tmp/ictoast_log.txt"];
  }
  if (fh) {
    [fh seekToEndOfFile];
    [fh writeData:[log dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
  }
}

// ─── Toast display state ───────────────────────────────────────────────────
static UIWindow *gCurrentToastWindow = nil;
static NSTimer *gDismissTimer = nil;

static void cancelDismissTimer(void) {
  [gDismissTimer invalidate];
  gDismissTimer = nil;
}

// ─── Gray pill panel at bottom (XXTouch style) ──────────────────────────────
static void showToast(NSString *text, double duration) {
  ictlog(@"showToast: %@ (%.1fs)", text, duration);

  cancelDismissTimer();
  if (gCurrentToastWindow) {
    gCurrentToastWindow.hidden = YES;
    gCurrentToastWindow = nil;
  }

  CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
  CGFloat screenH = [UIScreen mainScreen].bounds.size.height;

  UIWindow *toastWindow =
      [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
  toastWindow.windowLevel = 20000099.9;
  toastWindow.backgroundColor = [UIColor clearColor];
  toastWindow.userInteractionEnabled = NO;
  toastWindow.rootViewController = [UIViewController new];

  CGFloat maxW = screenW - 60;
  UILabel *label = [[UILabel alloc] init];
  label.text = text;
  label.textColor = [UIColor whiteColor];
  label.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
  label.numberOfLines = 5;
  label.textAlignment = NSTextAlignmentCenter;
  label.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.93];
  label.layer.cornerRadius = 16;
  label.layer.masksToBounds = YES;

  CGSize sz = [label sizeThatFits:CGSizeMake(maxW - 32, 300)];
  sz.width = MIN(sz.width + 40, maxW);
  sz.height = MAX(sz.height + 20, 44);

  CGFloat x = (screenW - sz.width) / 2.0;
  CGFloat y = screenH - sz.height - 120;
  label.frame = CGRectMake(0, 0, sz.width, sz.height);
  toastWindow.frame = CGRectMake(x, y, sz.width, sz.height);

  [toastWindow addSubview:label];
  [toastWindow makeKeyAndVisible];
  gCurrentToastWindow = toastWindow;
  ictlog(@"window (%.0f, %.0f)", x, y);

  gDismissTimer = [NSTimer scheduledTimerWithTimeInterval:duration
                                                repeats:NO
                                                  block:^(NSTimer *t) {
    ictlog(@"auto-dismiss");
    if (gCurrentToastWindow) {
      gCurrentToastWindow.hidden = YES;
      gCurrentToastWindow = nil;
    }
  }];
}

// ─── Handle toast from payload file ───────────────────────────────────────
static void handleToastFromFile(void) {
  NSError *err;
  NSData *data = [NSData dataWithContentsOfFile:kToastPayloadFile
                                        options:0
                                          error:&err];
  if (!data || err) {
    ictlog(@"read payload failed: %@", err);
    return;
  }

  NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:data
                                                          options:NSJSONReadingAllowFragments
                                                            error:&err];
  if (![payload isKindOfClass:[NSDictionary class]]) {
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    ictlog(@"plain text: %@", text);
    dispatch_async(dispatch_get_main_queue(), ^{
      showToast(text, 2.0);
    });
    return;
  }

  NSString *text = payload[@"text"];
  double duration = [payload[@"duration"] doubleValue];
  if (duration <= 0) duration = 2.0;
  if (!text || text.length == 0) {
    ictlog(@"empty text");
    return;
  }

  ictlog(@"toast: %@ (%.1fs)", text, duration);
  dispatch_async(dispatch_get_main_queue(), ^{
    showToast(text, duration);
  });
}

// ─── Darwin notification callback ──────────────────────────────────────────
static void toastNotifyCallback(CFNotificationCenterRef c, void *o,
                                CFNotificationName n, const void *obj,
                                CFDictionaryRef info) {
  ictlog(@"Darwin notify received");
  handleToastFromFile();
}

// ─── Bootstrap UIKit ───────────────────────────────────────────────────────
static void bootstrapUIKit(void) {
  ictlog(@"bootstrapping UIKit...");

  void *bbsHandle = dlopen("/System/Library/PrivateFrameworks/"
                           "BackBoardServices.framework/BackBoardServices",
                           RTLD_LAZY);
  if (bbsHandle) {
    typedef void (*BKSDisplayServicesStartFunc)(void);
    BKSDisplayServicesStartFunc displayStart =
        (BKSDisplayServicesStartFunc)dlsym(bbsHandle, "BKSDisplayServicesStart");
    if (displayStart) {
      displayStart();
      ictlog(@"BKSDisplayServicesStart OK");
    }
  } else {
    ictlog(@"BackBoardServices dlopen failed");
  }

  void *uikitHandle =
      dlopen("/System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore", RTLD_LAZY);
  if (!uikitHandle) {
    uikitHandle = dlopen("/System/Library/Frameworks/UIKit.framework/UIKit", RTLD_LAZY);
  }

  if (uikitHandle) {
    typedef void (*UIApplicationInitializeFunc)(void);
    UIApplicationInitializeFunc appInit =
        (UIApplicationInitializeFunc)dlsym(uikitHandle, "UIApplicationInitialize");
    if (appInit) {
      appInit();
      ictlog(@"UIApplicationInitialize OK");
    }

    typedef void (*InstantiateSingletonFunc)(Class);
    InstantiateSingletonFunc instantiate =
        (InstantiateSingletonFunc)dlsym(uikitHandle, "UIApplicationInstantiateSingleton");
    if (instantiate) {
      instantiate([UIApplication class]);
      ictlog(@"sharedApplication: %@", [UIApplication sharedApplication]);
    }
  }

  ictlog(@"UIScreen: %@", [UIScreen mainScreen]);
}

// ─── main ─────────────────────────────────────────────────────────────────
int main(int argc, char *argv[]) {
  @autoreleasepool {
    pid_t myPid = getpid();
    ictlog(@"main() PID=%d", myPid);

    // Write PID so daemon watchdog can monitor us
    NSString *pidStr = [NSString stringWithFormat:@"%d", myPid];
    [pidStr writeToFile:kToastPIDFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
    ictlog(@"wrote PID to %@", kToastPIDFile);

    bootstrapUIKit();

    // Register Darwin notification listener
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        toastNotifyCallback,
        kToastNotifyName,
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
    ictlog(@"Darwin notify listener registered for '%@'", kToastNotifyName);

    // Health check timer (also cleans up PID file on exit)
    dispatch_source_t healthTimer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(healthTimer,
                             dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC),
                             30 * NSEC_PER_SEC, 1 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(healthTimer, ^{
      static int tick = 0;
      ictlog(@"alive tick=%d pid=%d", ++tick, myPid);
    });
    dispatch_resume(healthTimer);

    // Also handle SIGTERM gracefully
    signal(SIGTERM, SIG_DFL);

    ictlog(@"entering CFRunLoop...");
    CFRunLoopRun();
    ictlog(@"CFRunLoop exited");

    // Cleanup: remove PID file on exit
    [[NSFileManager defaultManager] removeItemAtPath:kToastPIDFile error:nil];
    return 0;
  }
}
