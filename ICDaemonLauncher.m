// ICDaemonLauncher.m — Daemon process lifecycle manager

#import "ICDaemonLauncher.h"
#import <signal.h>
#import <spawn.h>

extern char **environ;

static const int kDaemonPort = 46952;

@implementation ICDaemonLauncher

+ (instancetype)shared {
  static ICDaemonLauncher *instance;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    instance = [self new];
  });
  return instance;
}

- (void)killDaemon {
  pid_t killPid;
  const char *argv[] = {"/usr/bin/killall", "-9", "IOSControlDaemon", NULL};
  posix_spawn(&killPid, "/usr/bin/killall", NULL, NULL, (char **)argv, environ);
  waitpid(killPid, NULL, 0);
}

- (void)spawnDaemonWithCompletion:(void (^)(BOOL success))completion {
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
    [self killDaemon];
    usleep(200000); // 200ms gap

    NSString *appPath = [[NSBundle mainBundle] bundlePath];
    NSString *daemonPath =
        [appPath stringByAppendingPathComponent:@"IOSControlDaemon"];

    CGSize screen = [UIScreen mainScreen].bounds.size;
    NSString *w = [NSString stringWithFormat:@"%.0f", screen.width];
    NSString *h = [NSString stringWithFormat:@"%.0f", screen.height];

    const char *argv[] = {
        [daemonPath UTF8String], [w UTF8String], [h UTF8String], NULL};

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
    posix_spawnattr_setpgroup(&attr, 0);

    pid_t pid;
    int result = posix_spawn(&pid, [daemonPath UTF8String], NULL, &attr,
                             (char **)argv, environ);
    posix_spawnattr_destroy(&attr);

    BOOL ok = (result == 0);
    NSLog(@"%@ Daemon spawn PID=%d result=%d", ok ? @"🚀" : @"❌", pid, result);

    dispatch_async(dispatch_get_main_queue(), ^{
      if (completion)
        completion(ok);
    });
  });
}

- (void)checkStatusWithCompletion:(void (^)(BOOL alive,
                                            NSString *version))completion {
  NSURL *url = [NSURL
      URLWithString:[NSString
                        stringWithFormat:@"http://127.0.0.1:%d/api/status",
                                         kDaemonPort]];
  NSURLRequest *req =
      [NSURLRequest requestWithURL:url
                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                   timeoutInterval:2.0];
  [[[NSURLSession sharedSession]
      dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
          BOOL alive = NO;
          NSString *version = @"unknown";
          if (!error && data) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data
                                                                 options:0
                                                                   error:nil];
            alive = [json[@"ok"] boolValue];
            version = json[@"version"] ?: @"?";
          }
          dispatch_async(dispatch_get_main_queue(), ^{
            if (completion)
              completion(alive, version);
          });
        }] resume];
}

- (void)spawnToastService {
  // Kill any existing ICToastService instance
  pid_t killPid;
  const char *killArgv[] = {"/usr/bin/killall", "-9", "ICToastService", NULL};
  posix_spawn(&killPid, "/usr/bin/killall", NULL, NULL, (char **)killArgv,
              environ);
  waitpid(killPid, NULL, 0);
  usleep(100000); // 100ms gap

  NSString *appPath = [[NSBundle mainBundle] bundlePath];
  NSString *svcPath = [appPath
      stringByAppendingPathComponent:@"ICToastService.app/ICToastService"];

  if (![[NSFileManager defaultManager] fileExistsAtPath:svcPath]) {
    NSLog(@"⚠️ ICToastService binary not found at: %@", svcPath);
    return;
  }

  // Spawn from UIApp context (NOT from daemon) — this inherits the
  // display server (backboardd) Mach port, allowing UIWindow creation.
  // Same pattern as XXTouch watchdog spawning XXTUIService.
  posix_spawnattr_t attr;
  posix_spawnattr_init(&attr);
  posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
  posix_spawnattr_setpgroup(&attr, 0);

  const char *argv[] = {[svcPath UTF8String], NULL};
  pid_t pid = 0;
  int result = posix_spawn(&pid, [svcPath UTF8String], NULL, &attr,
                           (char **)argv, environ);
  posix_spawnattr_destroy(&attr);

  if (result == 0) {
    NSLog(@"🍞 ICToastService launched from UIApp context (PID=%d)", pid);
  } else {
    NSLog(@"❌ ICToastService spawn failed: %d (%s)", result, strerror(result));
  }
}

@end
