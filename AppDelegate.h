// AppDelegate.h
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>

@interface AppDelegate
    : UIResponder <UIApplicationDelegate, UNUserNotificationCenterDelegate>
@property(strong, nonatomic) UIWindow *window;

// Watchdog coordination — used by ICSettingsViewController for manual daemon
// control
- (void)pauseWatchdog;
- (void)resumeWatchdog;
- (void)respawnDaemon;

@end
