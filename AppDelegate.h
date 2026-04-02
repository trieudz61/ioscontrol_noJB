// AppDelegate.h
#import <UIKit/UIKit.h>

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property(strong, nonatomic) UIWindow *window;

// Watchdog coordination — used by ICSettingsViewController for manual daemon
// control
- (void)pauseWatchdog;
- (void)resumeWatchdog;
- (void)respawnDaemon;

@end
