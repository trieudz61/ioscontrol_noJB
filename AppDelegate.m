// AppDelegate.m — IOSControl App Entry Point (Phase 8)
// Root UI: UITabBarController with 3 tabs
// Daemon spawned via ICDaemonLauncher on app launch
// Daemon watchdog: app polls daemon every 5s, respawns if dead (XXTouch
// pattern)

#import "AppDelegate.h"
#import "ICConsoleViewController.h"
#import "ICDaemonLauncher.h"
#import "ICScriptsViewController.h"
#import "ICSettingsViewController.h"
#import <CoreFoundation/CoreFoundation.h>
#import <UserNotifications/UserNotifications.h>

// ─── Constants ───────────────────────────────────────────────────────────
#define kICPasteTextFile @"/tmp/ioscontrol_paste_text.txt"
#define kICNotifSetPasteboard CFSTR("com.ioscontrol.setPasteboard")
#define kICNotifGetPasteboard CFSTR("com.ioscontrol.getPasteboard")
#define kICPasteboardResFile @"/tmp/ioscontrol_clipboard_res.txt"
#define kICPasteboardReqFile @"/tmp/ioscontrol_clipboard_req.txt"
#define kICPasteboardBakFile @"/tmp/ioscontrol_clipboard_bak.txt"
#define kICToastTextFile @"/tmp/ioscontrol_toast_text.txt"
#define kICNotifShowToast CFSTR("com.ioscontrol.showToast")

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

  // Tab 3: Settings
  ICSettingsViewController *settings = [[ICSettingsViewController alloc] init];
  UINavigationController *nav4 =
      [[UINavigationController alloc] initWithRootViewController:settings];
  nav4.tabBarItem = [[UITabBarItem alloc]
      initWithTitle:@"Settings"
              image:[UIImage systemImageNamed:@"gearshape"]
      selectedImage:[UIImage systemImageNamed:@"gearshape.fill"]];

  tabs.viewControllers = @[ nav1, nav2, nav4 ];

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

  // ── ICToastService is spawned by daemon watchdog (not by UIApp) ──
  // Daemon starts ICToastService after setsid(), watchdog keeps it alive

  // ── Request notification permission (for daemon → UNUserNotification toast)
  // ── Daemon posts local notifications so toast works even when app is killed
  [[UNUserNotificationCenter currentNotificationCenter]
      requestAuthorizationWithOptions:(UNAuthorizationOptionAlert |
                                       UNAuthorizationOptionSound |
                                       UNAuthorizationOptionBadge)
                    completionHandler:^(BOOL granted, NSError *error) {
                      NSLog(@"🔔 Notification permission: %@",
                            granted ? @"granted" : @"denied");
                    }];
  [UNUserNotificationCenter currentNotificationCenter].delegate = self;

  // ── IPC Listeners ──
  [self registerIPCListeners];

  return YES;
}

// ═══════════════════════════════════════════
// IPC — daemon → main app
// ═══════════════════════════════════════════

// ─── Darwin notification callbacks ────────────────────────────────────────

// IPC: pasteboard (daemon → app)
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

// IPC: get clipboard (daemon → app) — read clipboard and write to result file
static void ic_getPasteboardCallback(CFNotificationCenterRef c, void *o,
                                     CFNotificationName n, const void *obj,
                                     CFDictionaryRef info) {
  dispatch_async(dispatch_get_main_queue(), ^{
    NSString *clipText = [UIPasteboard generalPasteboard].string ?: @"";
    NSError *err;
    [clipText writeToFile:kICPasteboardResFile
               atomically:YES
                 encoding:NSUTF8StringEncoding
                    error:&err];
    if (err) {
      NSLog(@"📋 IPC: failed to write clipboard result: %@", err);
    } else {
      NSLog(@"📋 IPC: clipboard read, len=%lu", (unsigned long)clipText.length);
    }
  });
}

// IPC: toast (daemon → app) — reads file and shows UNNotification banner
static void ic_toastCallback(CFNotificationCenterRef c, void *o,
                             CFNotificationName n, const void *obj,
                             CFDictionaryRef info) {
  NSString *text = [NSString stringWithContentsOfFile:kICToastTextFile
                                             encoding:NSUTF8StringEncoding
                                                error:nil];
  if (!text || text.length == 0) {
    NSLog(@"🍞 IPC: toast text file empty");
    return;
  }

  UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
  content.title = @"IOSControl";
  content.body = text;
  content.sound = [UNNotificationSound defaultSound];

  UNTimeIntervalNotificationTrigger *trigger =
      [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:0.01 repeats:NO];

  NSString *identifier = [NSString stringWithFormat:@"ictoast-%f",
                           [[NSDate date] timeIntervalSince1970]];
  UNNotificationRequest *request =
      [UNNotificationRequest requestWithIdentifier:identifier
                                           content:content
                                           trigger:trigger];

  [[UNUserNotificationCenter currentNotificationCenter]
      addNotificationRequest:request
       withCompletionHandler:^(NSError *err) {
    if (err)
      NSLog(@"🍞 IPC: UNNotification error: %@", err);
    else
      NSLog(@"🍞 IPC: toast shown via UNNotification: %@", text);
  }];
}

- (void)registerIPCListeners {
  CFNotificationCenterRef darwin = CFNotificationCenterGetDarwinNotifyCenter();

  CFNotificationCenterAddObserver(
      darwin, (__bridge void *)self, ic_pasteboardCallback,
      kICNotifSetPasteboard, NULL,
      CFNotificationSuspensionBehaviorDeliverImmediately);
  NSLog(@"📡 IPC: Pasteboard listener registered");

  CFNotificationCenterAddObserver(
      darwin, (__bridge void *)self, ic_toastCallback,
      kICNotifShowToast, NULL,
      CFNotificationSuspensionBehaviorDeliverImmediately);
  NSLog(@"📡 IPC: Toast listener registered");

  CFNotificationCenterAddObserver(
      darwin, (__bridge void *)self, ic_getPasteboardCallback,
      kICNotifGetPasteboard, NULL,
      CFNotificationSuspensionBehaviorDeliverImmediately);
  NSLog(@"📡 IPC: GetPasteboard listener registered");
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

// ── UNUserNotificationCenterDelegate ──
// Show notification banner even when app is in foreground
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:
             (void (^)(UNNotificationPresentationOptions))completionHandler {
  completionHandler(UNNotificationPresentationOptionBanner |
                    UNNotificationPresentationOptionSound);
}

// Dismiss notification when user taps it
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
    didReceiveNotificationResponse:(UNNotificationResponse *)response
             withCompletionHandler:(void (^)(void))completionHandler {
  completionHandler();
}

@end
