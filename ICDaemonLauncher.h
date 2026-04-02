// ICDaemonLauncher.h — Manages IOSControlDaemon process lifecycle
// Extracted from AppDelegate to keep launcher logic reusable

#pragma once
#import <UIKit/UIKit.h>

@interface ICDaemonLauncher : NSObject

+ (instancetype)shared;

/// Spawn daemon binary (kills existing first). Completion on main thread.
- (void)spawnDaemonWithCompletion:(void (^)(BOOL success))completion;

/// Kill daemon (SIGKILL)
- (void)killDaemon;

/// Check if daemon HTTP server is reachable
- (void)checkStatusWithCompletion:(void (^)(BOOL alive,
                                            NSString *version))completion;

@end
