// ICToastService.m — Global toast overlay service
// Pure CFRunLoop daemon (UIApplicationMain hangs for spawned processes)
// Creates UIWindow overlay without UIApplicationMain by bootstrapping
// UIApplication singleton directly
#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>

// ─── File-based logging ───────────────────────────────────────────────────
static void ictlog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void ictlog(NSString *fmt, ...) {
  va_list args;
  va_start(args, fmt);
  NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
  va_end(args);
  NSLog(@"🍞 ICToastService: %@", msg);
  NSString *log = [NSString stringWithFormat:@"%@: %@\n", [NSDate date], msg];
  NSFileHandle *fh =
      [NSFileHandle fileHandleForWritingAtPath:@"/tmp/ictoast_log.txt"];
  if (!fh) {
    [@"" writeToFile:@"/tmp/ictoast_log.txt"
          atomically:NO
            encoding:NSUTF8StringEncoding
               error:nil];
    fh = [NSFileHandle fileHandleForWritingAtPath:@"/tmp/ictoast_log.txt"];
  }
  [fh seekToEndOfFile];
  [fh writeData:[log dataUsingEncoding:NSUTF8StringEncoding]];
  [fh closeFile];
}

// ─── IPC constants ────────────────────────────────────────────────────────
static NSString *const kICToastTextFile = @"/tmp/ioscontrol_toast_text.txt";
static CFStringRef kICNotifShowToast = CFSTR("com.ioscontrol.showToast");

// ─── Toast display via UIWindow (created without UIApplicationMain) ───────
static UIWindow *gCurrentToastWindow = nil;

static void showToast(NSString *text) {
  ictlog(@"showToast: %@", text);

  // Dismiss previous
  if (gCurrentToastWindow) {
    gCurrentToastWindow.hidden = YES;
    gCurrentToastWindow = nil;
  }

  CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
  CGFloat screenH = [UIScreen mainScreen].bounds.size.height;
  ictlog(@"screen: %gx%g", screenW, screenH);

  // Create window
  UIWindow *toastWindow =
      [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
  toastWindow.windowLevel = 20000099.9;
  toastWindow.backgroundColor = [UIColor clearColor];
  toastWindow.userInteractionEnabled = NO;
  toastWindow.rootViewController = [UIViewController new];

  // Pill label
  CGFloat maxW = screenW - 60;
  UILabel *label = [[UILabel alloc] init];
  label.text = text;
  label.textColor = [UIColor whiteColor];
  label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
  label.numberOfLines = 3;
  label.textAlignment = NSTextAlignmentCenter;
  label.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.92];
  label.layer.cornerRadius = 14;
  label.layer.masksToBounds = YES;
  label.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.15].CGColor;
  label.layer.borderWidth = 0.5;

  CGSize sz = [label sizeThatFits:CGSizeMake(maxW - 32, 200)];
  sz.width = MIN(sz.width + 40, maxW);
  sz.height = MAX(sz.height + 20, 40);

  CGFloat x = (screenW - sz.width) / 2.0;
  CGFloat y = screenH - sz.height - 120;
  label.frame = CGRectMake(0, 0, sz.width, sz.height);
  toastWindow.frame = CGRectMake(x, y, sz.width, sz.height);

  [toastWindow addSubview:label];
  [toastWindow makeKeyAndVisible];
  gCurrentToastWindow = toastWindow;
  ictlog(@"window created and makeKeyAndVisible");

  // Auto-dismiss after 2s
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        toastWindow.hidden = YES;
        if (gCurrentToastWindow == toastWindow) {
          gCurrentToastWindow = nil;
        }
        ictlog(@"toast dismissed");
      });
}

// ─── Darwin notification callback ─────────────────────────────────────────
static void toastNotificationCallback(CFNotificationCenterRef c, void *o,
                                      CFNotificationName n, const void *obj,
                                      CFDictionaryRef info) {
  NSError *err;
  NSString *text = [NSString stringWithContentsOfFile:kICToastTextFile
                                             encoding:NSUTF8StringEncoding
                                                error:&err];
  if (!text || err) {
    ictlog(@"failed to read toast text: %@", err);
    return;
  }
  [[NSFileManager defaultManager] removeItemAtPath:kICToastTextFile error:nil];

  NSString *toastText = [text copy];
  dispatch_async(dispatch_get_main_queue(), ^{
    showToast(toastText);
  });
}

// ─── Bootstrap UIApplication without UIApplicationMain ────────────────────
// UIApplicationMain hangs for posix_spawned processes because RunningBoard
// doesn't know about them. But we can create a UIApplication singleton
// directly and create UIWindows on it.

static void bootstrapUIKit(void) {
  ictlog(@"bootstrapping UIKit (3-step XXTUIService pattern)...");

  // Step 0: GraphicsServices (GSInitialize / GSEventInitialize)
  // Initializes core graphics subsystem, required before BackBoard
  void *gsHandle = dlopen("/System/Library/PrivateFrameworks/"
                          "GraphicsServices.framework/GraphicsServices",
                          RTLD_LAZY);
  if (gsHandle) {
    typedef void (*InitFunc)(void);
    InitFunc gsInit = (InitFunc)dlsym(gsHandle, "GSInitialize");
    if (gsInit)
      gsInit();
    InitFunc gsEventInit = (InitFunc)dlsym(gsHandle, "GSEventInitialize");
    if (gsEventInit)
      gsEventInit();
    ictlog(@"GraphicsServices initialization OK");
  } else {
    ictlog(@"GraphicsServices dlopen failed");
  }

  // Step 1: BKSDisplayServicesStart — connect to BackBoard display server
  // This establishes the rendering pipeline (Mach port to backboardd)
  // From: BackBoardServices.framework
  void *bbsHandle = dlopen("/System/Library/PrivateFrameworks/"
                           "BackBoardServices.framework/BackBoardServices",
                           RTLD_LAZY);
  if (bbsHandle) {
    typedef void (*BKSDisplayServicesStartFunc)(void);
    BKSDisplayServicesStartFunc displayStart =
        (BKSDisplayServicesStartFunc)dlsym(bbsHandle,
                                           "BKSDisplayServicesStart");
    if (displayStart) {
      displayStart();
      ictlog(@"BKSDisplayServicesStart OK");
    } else {
      ictlog(@"BKSDisplayServicesStart not found");
    }
  } else {
    ictlog(@"BackBoardServices dlopen failed");
  }

  // Step 2: UIApplicationInitialize — setup UIKit internal state
  // This initializes UIKit's display/rendering subsystem
  void *uikitHandle =
      dlopen("/System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore",
             RTLD_LAZY);
  if (!uikitHandle) {
    uikitHandle =
        dlopen("/System/Library/Frameworks/UIKit.framework/UIKit", RTLD_LAZY);
  }

  if (uikitHandle) {
    typedef void (*UIApplicationInitializeFunc)(void);
    UIApplicationInitializeFunc appInit = (UIApplicationInitializeFunc)dlsym(
        uikitHandle, "UIApplicationInitialize");
    if (appInit) {
      appInit();
      ictlog(@"UIApplicationInitialize OK");
    } else {
      ictlog(@"UIApplicationInitialize not found");
    }

    // Step 3: UIApplicationInstantiateSingleton — create UIApplication
    typedef void (*InstantiateSingletonFunc)(Class);
    InstantiateSingletonFunc instantiate = (InstantiateSingletonFunc)dlsym(
        uikitHandle, "UIApplicationInstantiateSingleton");
    if (instantiate) {
      instantiate([UIApplication class]);
      ictlog(@"UIApplicationInstantiateSingleton OK, shared=%@",
             [UIApplication sharedApplication]);
    } else {
      ictlog(@"UIApplicationInstantiateSingleton not found");
    }
  } else {
    ictlog(@"UIKitCore dlopen failed");
  }

  UIScreen *screen = [UIScreen mainScreen];
  ictlog(@"UIScreen: %@, bounds=%@", screen, NSStringFromCGRect(screen.bounds));
}

// ─── main ─────────────────────────────────────────────────────────────────
int main(int argc, char *argv[]) {
  @autoreleasepool {
    // Write early log
    ictlog(@"main() entered (PID=%d)", getpid());

    // Bootstrap UIKit without UIApplicationMain
    bootstrapUIKit();

    // Register Darwin notification listener
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(), NULL,
        toastNotificationCallback, kICNotifShowToast, NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
    ictlog(@"Darwin listener registered");

    // Run main run loop forever
    ictlog(@"entering CFRunLoop...");
    CFRunLoopRun();

    ictlog(@"CFRunLoop exited (unexpected)");
    return 0;
  }
}
