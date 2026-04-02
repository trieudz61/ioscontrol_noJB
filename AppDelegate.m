// AppDelegate.m — IOSControl App Entry Point (Phase 8)
// Root UI: UITabBarController with 4 tabs
// Daemon spawned via ICDaemonLauncher on app launch
// Daemon watchdog: app polls daemon every 5s, respawns if dead (XXTouch
// pattern)

#import "AppDelegate.h"
#import "ICConsoleViewController.h"
#import "ICDaemonLauncher.h"
#import "ICDeviceViewController.h"
#import "ICScriptsViewController.h"
#import "ICSettingsViewController.h"
#import <CoreFoundation/CoreFoundation.h>

// Path for daemon → app IPC (pasteboard text)
#define kICPasteTextFile @"/tmp/ioscontrol_paste_text.txt"
#define kICNotifSetPasteboard CFSTR("com.ioscontrol.setPasteboard")

// Note: toast IPC is now handled by ICToastService (hidden UIApp)

@interface AppDelegate ()
@property(nonatomic, strong) NSTimer *daemonWatchdog;
@property(nonatomic, assign) NSInteger watchdogMissCount;
@property(nonatomic, assign) BOOL isRespawning;
@property(nonatomic, assign) BOOL watchdogPaused;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {

  // ── Force Dark Mode ──
  self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
  if (@available(iOS 13.0, *)) {
    self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
  }

  // ── Global Tint (Purple #6C63FF) ──
  self.window.tintColor = [UIColor colorWithRed:0.42
                                          green:0.39
                                           blue:1.00
                                          alpha:1];

  // ── Build Tab Bar ──
  UITabBarController *tabs = [[UITabBarController alloc] init];

  // Tab 1: Scripts
  ICScriptsViewController *scripts = [[ICScriptsViewController alloc] init];
  UINavigationController *nav1 =
      [[UINavigationController alloc] initWithRootViewController:scripts];
  nav1.tabBarItem = [[UITabBarItem alloc]
      initWithTitle:@"Scripts"
              image:[UIImage systemImageNamed:@"doc.text"]
      selectedImage:[UIImage systemImageNamed:@"doc.text.fill"]];

  // Tab 2: Console
  ICConsoleViewController *console = [[ICConsoleViewController alloc] init];
  UINavigationController *nav2 =
      [[UINavigationController alloc] initWithRootViewController:console];
  nav2.tabBarItem = [[UITabBarItem alloc]
      initWithTitle:@"Console"
              image:[UIImage systemImageNamed:@"terminal"]
      selectedImage:[UIImage systemImageNamed:@"terminal.fill"]];

  // Tab 3: Device
  ICDeviceViewController *device = [[ICDeviceViewController alloc] init];
  UINavigationController *nav3 =
      [[UINavigationController alloc] initWithRootViewController:device];
  nav3.tabBarItem =
      [[UITabBarItem alloc] initWithTitle:@"Device"
                                    image:[UIImage systemImageNamed:@"iphone"]
                            selectedImage:[UIImage systemImageNamed:@"iphone"]];

  // Tab 4: Settings
  ICSettingsViewController *settings = [[ICSettingsViewController alloc] init];
  UINavigationController *nav4 =
      [[UINavigationController alloc] initWithRootViewController:settings];
  nav4.tabBarItem = [[UITabBarItem alloc]
      initWithTitle:@"Settings"
              image:[UIImage systemImageNamed:@"gearshape"]
      selectedImage:[UIImage systemImageNamed:@"gearshape.fill"]];

  tabs.viewControllers = @[ nav1, nav2, nav3, nav4 ];

  // ── Style Tab Bar ──
  UITabBarAppearance *tabAppearance = [UITabBarAppearance new];
  [tabAppearance configureWithOpaqueBackground];
  tabAppearance.backgroundColor = [UIColor colorWithRed:0.08
                                                  green:0.08
                                                   blue:0.14
                                                  alpha:1];
  // Selected item color
  UITabBarItemAppearance *itemAppearance = [UITabBarItemAppearance new];
  [itemAppearance.selected.iconColor set];
  itemAppearance.selected.iconColor = [UIColor colorWithRed:0.42
                                                      green:0.39
                                                       blue:1.00
                                                      alpha:1];
  itemAppearance.selected.titleTextAttributes = @{
    NSForegroundColorAttributeName : [UIColor colorWithRed:0.42
                                                     green:0.39
                                                      blue:1.00
                                                     alpha:1]
  };
  itemAppearance.normal.iconColor = [UIColor colorWithWhite:0.5 alpha:1];
  itemAppearance.normal.titleTextAttributes =
      @{NSForegroundColorAttributeName : [UIColor colorWithWhite:0.5 alpha:1]};
  tabAppearance.stackedLayoutAppearance = itemAppearance;
  tabs.tabBar.standardAppearance = tabAppearance;
  if (@available(iOS 15.0, *)) {
    tabs.tabBar.scrollEdgeAppearance = tabAppearance;
  }

  self.window.rootViewController = tabs;
  [self.window makeKeyAndVisible];

  // ── Spawn daemon on launch ──
  [[ICDaemonLauncher shared] spawnDaemonWithCompletion:^(BOOL success) {
    NSLog(@"%@ ICDaemonLauncher spawn: %@", success ? @"🚀" : @"❌",
          success ? @"OK" : @"FAILED");
    // Start watchdog after first spawn attempt
    dispatch_async(dispatch_get_main_queue(), ^{
      [self startDaemonWatchdog];
    });
  }];

  // ── IPC Listeners ──
  [self registerIPCListeners];

  return YES;
}

// ═══════════════════════════════════════════
// IPC — daemon → main app
// ═══════════════════════════════════════════

static UIWindow *gToastWindow = nil;

static void ic_pasteboardCallback(CFNotificationCenterRef c, void *o,
                                  CFNotificationName n, const void *obj,
                                  CFDictionaryRef info) {
  NSString *path = @"/tmp/ioscontrol_paste_text.txt";
  NSError *err;
  NSString *text = [NSString stringWithContentsOfFile:path
                                             encoding:NSUTF8StringEncoding
                                                error:&err];
  if (!text || err) {
    NSLog(@"📋 IPC: failed to read paste text: %@", err);
    return;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    [UIPasteboard generalPasteboard].string = text;
    NSLog(@"📋 IPC: clipboard set to: %@", text);
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
  });
}

static void ic_toastCallback(CFNotificationCenterRef c, void *o,
                             CFNotificationName n, const void *obj,
                             CFDictionaryRef info) {
  NSString *path = @"/tmp/ioscontrol_toast_text.txt";
  NSError *err;
  NSString *text = [NSString stringWithContentsOfFile:path
                                             encoding:NSUTF8StringEncoding
                                                error:&err];
  if (!text || err)
    return;
  NSString *toastText = [text copy];
  [[NSFileManager defaultManager] removeItemAtPath:path error:nil];

  dispatch_async(dispatch_get_main_queue(), ^{
    // Dismiss previous toast
    if (gToastWindow) {
      gToastWindow.hidden = YES;
      gToastWindow = nil;
    }

    CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
    CGFloat screenH = [UIScreen mainScreen].bounds.size.height;

    UIWindow *w = [[UIWindow alloc] init];
    w.windowLevel = 20000099.9;
    w.backgroundColor = [UIColor clearColor];
    w.userInteractionEnabled = NO;
    w.hidden = NO;
    gToastWindow = w;

    CGFloat maxW = screenW - 60;
    UILabel *label = [[UILabel alloc] init];
    label.text = toastText;
    label.textColor = [UIColor whiteColor];
    label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    label.numberOfLines = 3;
    label.textAlignment = NSTextAlignmentCenter;
    label.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.92];
    label.layer.cornerRadius = 14;
    label.layer.masksToBounds = YES;

    CGSize sz = [label sizeThatFits:CGSizeMake(maxW - 32, 200)];
    sz.width = MIN(sz.width + 40, maxW);
    sz.height = MAX(sz.height + 20, 40);

    w.frame = CGRectMake((screenW - sz.width) / 2.0, screenH - sz.height - 120,
                         sz.width, sz.height);
    label.frame = CGRectMake(0, 0, sz.width, sz.height);
    [w addSubview:label];

    w.alpha = 0;
    w.transform = CGAffineTransformMakeScale(0.85, 0.85);
    [UIView animateWithDuration:0.2
        delay:0
        usingSpringWithDamping:0.7
        initialSpringVelocity:0.5
        options:0
        animations:^{
          w.alpha = 1;
          w.transform = CGAffineTransformIdentity;
        }
        completion:^(BOOL _) {
          dispatch_after(
              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
              dispatch_get_main_queue(), ^{
                [UIView animateWithDuration:0.25
                    animations:^{
                      w.alpha = 0;
                    }
                    completion:^(BOOL __) {
                      w.hidden = YES;
                      if (gToastWindow == w)
                        gToastWindow = nil;
                    }];
              });
        }];
  });
}

- (void)registerIPCListeners {
  CFNotificationCenterRef darwin = CFNotificationCenterGetDarwinNotifyCenter();
  CFNotificationCenterAddObserver(
      darwin, (__bridge void *)self, ic_pasteboardCallback,
      CFSTR("com.ioscontrol.setPasteboard"), NULL,
      CFNotificationSuspensionBehaviorDeliverImmediately);
  CFNotificationCenterAddObserver(
      darwin, (__bridge void *)self, ic_toastCallback,
      CFSTR("com.ioscontrol.showToast"), NULL,
      CFNotificationSuspensionBehaviorDeliverImmediately);
  NSLog(@"📡 IPC: Pasteboard + Toast listeners registered");
}

// ═══════════════════════════════════════════
// Daemon Watchdog — auto respawn if daemon dies
// Same approach as XXTouch: host app supervises daemon
// ═══════════════════════════════════════════

- (void)startDaemonWatchdog {
  [self.daemonWatchdog invalidate];
  self.watchdogMissCount = 0;
  self.isRespawning = NO;
  self.watchdogPaused = NO;

  // Poll every 3s (faster than before) — respawn on FIRST miss
  self.daemonWatchdog =
      [NSTimer scheduledTimerWithTimeInterval:3.0
                                       target:self
                                     selector:@selector(watchdogTick)
                                     userInfo:nil
                                      repeats:YES];
  NSLog(@"🐕 Daemon watchdog started (3s interval)");
}

- (void)stopDaemonWatchdog {
  [self.daemonWatchdog invalidate];
  self.daemonWatchdog = nil;
}

// Pause watchdog so Settings buttons can do manual kill/spawn without race
- (void)pauseWatchdog {
  self.watchdogPaused = YES;
  NSLog(@"⏸️ Watchdog paused (manual control)");
}
- (void)resumeWatchdog {
  self.watchdogPaused = NO;
  self.watchdogMissCount = 0;
  self.isRespawning = NO;
  NSLog(@"▶️ Watchdog resumed");
}

- (void)watchdogTick {
  if (self.watchdogPaused || self.isRespawning)
    return;

  [[ICDaemonLauncher shared]
      checkStatusWithCompletion:^(BOOL alive, NSString *version) {
        if (alive) {
          self.watchdogMissCount = 0;
        } else {
          self.watchdogMissCount++;
          NSLog(@"⚠️ Watchdog: daemon not responding (miss #%ld)",
                (long)self.watchdogMissCount);
          // Respawn on first miss (no grace period — miss = dead)
          if (self.watchdogMissCount >= 1) {
            [self respawnDaemon];
          }
        }
      }];
}

- (void)respawnDaemon {
  if (self.isRespawning)
    return;
  self.isRespawning = YES;
  self.watchdogMissCount = 0;

  NSLog(@"🔄 Watchdog: respawning daemon...");
  [[ICDaemonLauncher shared] spawnDaemonWithCompletion:^(BOOL success) {
    self.isRespawning = NO;
    NSLog(@"%@ Watchdog respawn: %@", success ? @"✅" : @"❌",
          success ? @"OK" : @"FAILED");
  }];
}

// ── Respawn immediately when app comes to foreground ──
- (void)applicationDidBecomeActive:(UIApplication *)application {
  // Check daemon status immediately (don't wait for watchdog tick)
  if (self.isRespawning)
    return;

  [[ICDaemonLauncher shared]
      checkStatusWithCompletion:^(BOOL alive, NSString *version) {
        if (!alive) {
          NSLog(@"🔄 App foregrounded: daemon dead, respawning...");
          [self respawnDaemon];
        } else {
          NSLog(@"✅ App foregrounded: daemon alive (v%@)", version);
        }
      }];
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
  // Keep watchdog running in background (app has voip/audio background modes)
  NSLog(@"📱 App backgrounded — watchdog continues");
}

@end
