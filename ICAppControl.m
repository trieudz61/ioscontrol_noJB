// ICAppControl.m — App launch/kill/list for IOSControl daemon
// Uses LSApplicationWorkspace + BKSProcessAssertion via ObjC runtime
// No direct linking to private frameworks — pure runtime calls

#import "ICAppControl.h"
#import <objc/runtime.h>
#import <signal.h>
#import <unistd.h>
#import <spawn.h>
#import <sys/wait.h>
#import <dlfcn.h>

extern void logMsg(const char *fmt, ...);

// ═══════════════════════════════════════════
// Lazy LSApplicationWorkspace accessor
// ═══════════════════════════════════════════

static id _workspace(void) {
  static id ws = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    Class cls = NSClassFromString(@"LSApplicationWorkspace");
    if (cls) {
      ws = [cls performSelector:NSSelectorFromString(@"defaultWorkspace")];
    }
    if (!ws) {
      logMsg("⚠️ [AppCtrl] LSApplicationWorkspace not available");
    }
  });
  return ws;
}

// ═══════════════════════════════════════════
// LSApplicationProxy helpers
// ═══════════════════════════════════════════

static id _proxy(NSString *bundleID) {
  id ws = _workspace();
  if (!ws)
    return nil;
  return [ws
      performSelector:NSSelectorFromString(@"applicationProxyForIdentifier:")
           withObject:bundleID];
}

// ═══════════════════════════════════════════
// Public API
// ═══════════════════════════════════════════

NSArray<NSDictionary *> *ic_appList(void) {
  id ws = _workspace();

  // Primary: LSApplicationWorkspace
  if (ws) {
    NSArray *proxies =
        [ws performSelector:NSSelectorFromString(@"allInstalledApplications")];
    if (proxies.count > 0) {
      NSMutableArray *result = [NSMutableArray arrayWithCapacity:proxies.count];
      for (id proxy in proxies) {
        @try {
          NSString *bid = [proxy
              performSelector:NSSelectorFromString(@"applicationIdentifier")];
          NSString *name =
              [proxy performSelector:NSSelectorFromString(@"localizedName")];
          NSString *version = [proxy
              performSelector:NSSelectorFromString(@"shortVersionString")];
          if (!bid)
            continue;
          [result addObject:@{
            @"bundleID" : bid ?: @"",
            @"name" : name ?: bid,
            @"version" : version ?: @""
          }];
        } @catch (__unused NSException *e) {
        }
      }
      if (result.count > 0) {
        [result sortUsingComparator:^NSComparisonResult(NSDictionary *a,
                                                        NSDictionary *b) {
          return [a[@"name"] compare:b[@"name"]
                             options:NSCaseInsensitiveSearch];
        }];
        logMsg("📋 [AppCtrl] Listed %d apps (LSWorkspace)", (int)result.count);
        return result;
      }
    }
  }

  // Fallback: filesystem scan of /var/containers/Bundle/Application/
  logMsg("⚠️ [AppCtrl] LSWorkspace empty, falling back to fs scan");
  NSMutableArray *result = [NSMutableArray array];
  NSArray *scanPaths = @[
    @"/var/containers/Bundle/Application",
    @"/private/var/containers/Bundle/Application",
  ];
  NSFileManager *fm = [NSFileManager defaultManager];
  for (NSString *base in scanPaths) {
    NSArray *dirs = [fm contentsOfDirectoryAtPath:base error:nil];
    if (!dirs)
      continue;
    for (NSString *uuid in dirs) {
      NSString *appDir = [base stringByAppendingPathComponent:uuid];
      // Find .app bundle inside
      NSArray *contents = [fm contentsOfDirectoryAtPath:appDir error:nil];
      for (NSString *item in contents) {
        if (![item hasSuffix:@".app"])
          continue;
        NSString *appPath = [appDir stringByAppendingPathComponent:item];
        NSString *infoPlistPath =
            [appPath stringByAppendingPathComponent:@"Info.plist"];
        NSDictionary *info =
            [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
        NSString *bid = info[@"CFBundleIdentifier"];
        if (!bid)
          continue;
        NSString *name = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: bid;
        NSString *ver = info[@"CFBundleShortVersionString"] ?: @"";
        [result
            addObject:@{@"bundleID" : bid, @"name" : name, @"version" : ver}];
        break; // only one .app per UUID dir
      }
    }
    if (result.count > 0)
      break; // found with first path
  }
  [result sortUsingComparator:^NSComparisonResult(NSDictionary *a,
                                                  NSDictionary *b) {
    return [a[@"name"] compare:b[@"name"] options:NSCaseInsensitiveSearch];
  }];
  logMsg("📋 [AppCtrl] Listed %d apps (fs scan)", (int)result.count);
  return result;
}

BOOL ic_appLaunch(NSString *bundleID) {
  if (!bundleID.length)
    return NO;
  id ws = _workspace();
  if (!ws)
    return NO;

  // Use openApplicationWithBundleID: (available in LSApplicationWorkspace)
  SEL sel = NSSelectorFromString(@"openApplicationWithBundleID:");
  if (![ws respondsToSelector:sel]) {
    logMsg("❌ [AppCtrl] openApplicationWithBundleID: not available");
    return NO;
  }

  BOOL ok = NO;
  @try {
    ok = (BOOL)[ws performSelector:sel withObject:bundleID];
  } @catch (NSException *e) {
    logMsg("❌ [AppCtrl] Launch exception: %s", e.reason.UTF8String);
    return NO;
  }

  if (ok) {
    logMsg("✅ [AppCtrl] Launched: %s", bundleID.UTF8String);
  } else {
    logMsg("❌ [AppCtrl] Failed to launch: %s", bundleID.UTF8String);
  }
  return ok;
}

// ═══════════════════════════════════════════
// PID lookup via sysctl(KERN_PROC)
// ═══════════════════════════════════════════

#import <sys/sysctl.h>

// proc_pidpath declaration (from libproc)
extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);
#define PROC_PIDPATHINFO_MAXSIZE 4096

static pid_t findPidForBundleID(NSString *bundleID) {
  if (!bundleID.length) return -1;

  // Get all process PIDs
  int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
  size_t size = 0;
  if (sysctl(mib, 4, NULL, &size, NULL, 0) < 0) return -1;

  struct kinfo_proc *procs = (struct kinfo_proc *)malloc(size);
  if (!procs) return -1;
  if (sysctl(mib, 4, procs, &size, NULL, 0) < 0) {
    free(procs);
    return -1;
  }

  int count = (int)(size / sizeof(struct kinfo_proc));
  const char *target = bundleID.UTF8String;
  // Extract app name from bundleID (e.g., "com.apple.mobilesafari" → "MobileSafari")
  NSString *appName = [bundleID componentsSeparatedByString:@"."].lastObject;
  pid_t foundPid = -1;

  for (int i = 0; i < count; i++) {
    pid_t pid = procs[i].kp_proc.p_pid;
    if (pid <= 1) continue;

    // Get executable path for this PID
    char pathBuf[PROC_PIDPATHINFO_MAXSIZE];
    int pathLen = proc_pidpath(pid, pathBuf, sizeof(pathBuf));
    if (pathLen > 0) {
      NSString *path = [NSString stringWithUTF8String:pathBuf];
      // Check if path contains the bundleID or app name
      if ([path containsString:bundleID] ||
          [path.lastPathComponent.lowercaseString
              isEqualToString:appName.lowercaseString]) {
        foundPid = pid;
        break;
      }
    }

    // Also check process name
    const char *pname = procs[i].kp_proc.p_comm;
    if (pname && appName &&
        strcasecmp(pname, appName.UTF8String) == 0) {
      foundPid = pid;
      break;
    }
  }
  free(procs);
  return foundPid;
}

BOOL ic_appKill(NSString *bundleID) {
  if (!bundleID.length)
    return NO;

  logMsg("🔪 [AppCtrl] Killing: %s", bundleID.UTF8String);

  // ── Strategy 1: Find PID via sysctl + SIGKILL (most reliable on TrollStore) ──
  pid_t pid = findPidForBundleID(bundleID);
  if (pid > 1) {
    // Try SIGTERM first (graceful)
    if (kill(pid, SIGTERM) == 0) {
      logMsg("📡 [AppCtrl] Sent SIGTERM to pid=%d", pid);
      // Wait briefly for graceful shutdown
      usleep(300000); // 300ms

      // Check if still alive, if so SIGKILL
      if (kill(pid, 0) == 0) {
        kill(pid, SIGKILL);
        logMsg("📡 [AppCtrl] Sent SIGKILL to pid=%d", pid);
        usleep(100000); // 100ms
      }

      // Verify
      if (kill(pid, 0) != 0) {
        logMsg("✅ [AppCtrl] Killed via signal (pid=%d): %s", pid,
               bundleID.UTF8String);
        return YES;
      }
    } else {
      logMsg("⚠️ [AppCtrl] kill(%d, SIGTERM) failed: %s", pid, strerror(errno));
    }
  } else {
    logMsg("⚠️ [AppCtrl] PID not found for: %s", bundleID.UTF8String);
  }

  // ── Strategy 2: killall by process name variants ──
  // Try various name derivations from bundleID
  NSString *lastComponent = [bundleID componentsSeparatedByString:@"."].lastObject;
  NSArray *namesToTry = @[
    lastComponent,
    [lastComponent lowercaseString],
    bundleID,
  ];

  for (NSString *procName in namesToTry) {
    extern char **environ;
    char *argv[] = {"/usr/bin/killall", "-9", (char *)procName.UTF8String, NULL};
    pid_t spawnPid = 0;
    int spawnRet = posix_spawn(&spawnPid, "/usr/bin/killall", NULL, NULL, argv, environ);
    if (spawnRet == 0) {
      int status = 0;
      waitpid(spawnPid, &status, 0);
      if (WIFEXITED(status) && WEXITSTATUS(status) == 0) {
        logMsg("✅ [AppCtrl] Killed via killall '%s': %s",
               procName.UTF8String, bundleID.UTF8String);
        return YES;
      }
    }
  }

  // ── Strategy 3: FBSSystemService (jailbreak/advanced entitlements only) ──
  Class fbsSvc = NSClassFromString(@"FBSSystemService");
  if (fbsSvc) {
    @try {
      id svc = [fbsSvc performSelector:NSSelectorFromString(@"sharedService")];
      if (svc) {
        SEL termSel = NSSelectorFromString(
            @"terminateApplication:forReason:andReport:withDescription:");
        if ([svc respondsToSelector:termSel]) {
          NSMethodSignature *sig = [svc methodSignatureForSelector:termSel];
          NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
          [inv setSelector:termSel];
          [inv setTarget:svc];
          [inv setArgument:&bundleID atIndex:2];
          int reason = 5;
          [inv setArgument:&reason atIndex:3];
          BOOL report = NO;
          [inv setArgument:&report atIndex:4];
          NSString *desc = @"IOSControl kill";
          [inv setArgument:&desc atIndex:5];
          [inv invoke];
          logMsg("✅ [AppCtrl] Killed via FBSSystemService: %s",
                 bundleID.UTF8String);
          return YES;
        }
      }
    } @catch (NSException *e) {
      logMsg("⚠️ [AppCtrl] FBS kill exception: %s", e.reason.UTF8String);
    }
  }

  logMsg("❌ [AppCtrl] All kill strategies failed for: %s",
         bundleID.UTF8String);
  return NO;
}

BOOL ic_appIsRunning(NSString *bundleID) {
  if (!bundleID.length)
    return NO;

  // Most reliable: check if we can find a PID for this bundle
  pid_t pid = findPidForBundleID(bundleID);
  if (pid > 1) {
    // Verify the process is actually alive
    if (kill(pid, 0) == 0) {
      logMsg("📱 [AppCtrl] %s is running (pid=%d)", bundleID.UTF8String, pid);
      return YES;
    }
  }

  logMsg("📱 [AppCtrl] %s is NOT running", bundleID.UTF8String);
  return NO;
}

NSString *ic_appFrontmost(void) {
  // Strategy 1: Use SBSSpringBoardServerPort + SBSCopyFrontmostApplicationDisplayIdentifier
  // This is the most reliable on TrollStore
  void *sbServices = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
  if (sbServices) {
    typedef mach_port_t (*SBSSpringBoardServerPortFunc)(void);
    typedef CFStringRef (*SBSCopyFrontmostFunc)(mach_port_t);

    SBSSpringBoardServerPortFunc getPort =
        (SBSSpringBoardServerPortFunc)dlsym(sbServices, "SBSSpringBoardServerPort");
    SBSCopyFrontmostFunc copyFrontmost =
        (SBSCopyFrontmostFunc)dlsym(sbServices, "SBSCopyFrontmostApplicationDisplayIdentifier");

    if (getPort && copyFrontmost) {
      mach_port_t port = getPort();
      if (port != MACH_PORT_NULL) {
        CFStringRef cfBid = copyFrontmost(port);
        if (cfBid) {
          NSString *bid = (__bridge_transfer NSString *)cfBid;
          if (bid.length > 0) {
            logMsg("📱 [AppCtrl] Frontmost: %s (SBS)", bid.UTF8String);
            return bid;
          }
        }
      }
    }
  }

  // Strategy 2: Just return nil gracefully
  logMsg("⚠️ [AppCtrl] Cannot determine frontmost app");
  return nil;
}
