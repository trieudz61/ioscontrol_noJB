// ICToastService.m — Hidden UIApplication for global toast overlay
// Mirrors XXTUIService.app architecture: always-running hidden UIApp
// Daemon posix_spawns this at startup → it listens for Darwin notifications
// and creates UIWindow at windowLevel=20000099.9 to overlay on ALL apps.
// SBAppTags:hidden prevents user from seeing/killing it via app switcher.

#import <CoreFoundation/CoreFoundation.h>
#import <UIKit/UIKit.h>

// ─── IPC constants (same as daemon) ───────────────────────────────────────
static NSString *const kICToastTextFile = @"/tmp/ioscontrol_toast_text.txt";
static CFStringRef kICNotifShowToast = CFSTR("com.ioscontrol.showToast");

// Keep a strong reference to current toast window so ARC doesn't release it
static UIWindow *gCurrentToastWindow = nil;

// ─── Toast display ────────────────────────────────────────────────────────

static void showToast(NSString *text) {
  // Dismiss previous toast immediately
  if (gCurrentToastWindow) {
    gCurrentToastWindow.hidden = YES;
    gCurrentToastWindow = nil;
  }

  CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
  CGFloat screenH = [UIScreen mainScreen].bounds.size.height;

  // ── Create UIWindow at XXTouch's window level ──
  UIWindow *toastWindow = [[UIWindow alloc] init];
  toastWindow.windowLevel = 20000099.9;
  toastWindow.backgroundColor = [UIColor clearColor];
  toastWindow.userInteractionEnabled = NO;
  toastWindow.hidden = NO;

  // ── Pill label ──
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

  // Size to fit content
  CGSize sz = [label sizeThatFits:CGSizeMake(maxW - 32, 200)];
  sz.width = MIN(sz.width + 40, maxW);
  sz.height = MAX(sz.height + 20, 40);

  // Position: bottom of screen above home indicator
  CGFloat x = (screenW - sz.width) / 2.0;
  CGFloat y = screenH - sz.height - 120;
  label.frame = CGRectMake(0, 0, sz.width, sz.height);
  toastWindow.frame = CGRectMake(x, y, sz.width, sz.height);

  [toastWindow addSubview:label];
  gCurrentToastWindow = toastWindow;

  // ── Animate in ──
  toastWindow.alpha = 0.0;
  toastWindow.transform = CGAffineTransformMakeScale(0.85, 0.85);
  [UIView animateWithDuration:0.2
      delay:0
      usingSpringWithDamping:0.7
      initialSpringVelocity:0.5
      options:UIViewAnimationOptionCurveEaseOut
      animations:^{
        toastWindow.alpha = 1.0;
        toastWindow.transform = CGAffineTransformIdentity;
      }
      completion:^(BOOL done) {
        // Auto-dismiss after 2s
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
              [UIView animateWithDuration:0.25
                  animations:^{
                    toastWindow.alpha = 0.0;
                    toastWindow.transform =
                        CGAffineTransformMakeScale(0.9, 0.9);
                  }
                  completion:^(BOOL d) {
                    toastWindow.hidden = YES;
                    if (gCurrentToastWindow == toastWindow) {
                      gCurrentToastWindow = nil;
                    }
                  }];
            });
      }];
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
    NSLog(@"🍞 ICToastService: failed to read toast text: %@", err);
    return;
  }
  [[NSFileManager defaultManager] removeItemAtPath:kICToastTextFile error:nil];

  dispatch_async(dispatch_get_main_queue(), ^{
    showToast(text);
  });
}

// ─── AppDelegate ──────────────────────────────────────────────────────────

@interface ICToastAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation ICToastAppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {

  NSLog(@"🍞 ICToastService: started (PID=%d)", getpid());

  // Register Darwin notification listener
  CFNotificationCenterAddObserver(
      CFNotificationCenterGetDarwinNotifyCenter(), (__bridge void *)self,
      toastNotificationCallback, kICNotifShowToast, NULL,
      CFNotificationSuspensionBehaviorDeliverImmediately);

  NSLog(@"🍞 ICToastService: listener registered for %@",
        (__bridge NSString *)kICNotifShowToast);

  // Minimal hidden window — no UI needed, we create windows on demand
  self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
  self.window.windowLevel = UIWindowLevelNormal - 1;
  self.window.backgroundColor = [UIColor clearColor];
  self.window.hidden = YES;

  return YES;
}

// Keep running forever — never suspend
- (void)applicationDidEnterBackground:(UIApplication *)application {
  // Do nothing — stay alive
}

@end

// ─── main ─────────────────────────────────────────────────────────────────

int main(int argc, char *argv[]) {
  @autoreleasepool {
    return UIApplicationMain(argc, argv, nil,
                             NSStringFromClass([ICToastAppDelegate class]));
  }
}
