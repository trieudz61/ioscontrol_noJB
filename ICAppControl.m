// ICAppControl.m — App launch/kill/list for IOSControl daemon
// Uses LSApplicationWorkspace + BKSProcessAssertion via ObjC runtime
// No direct linking to private frameworks — pure runtime calls

#import "ICAppControl.h"
#import <objc/runtime.h>
#import <signal.h>

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

BOOL ic_appKill(NSString *bundleID) {
  if (!bundleID.length)
    return NO;

  // Try FBSSystemService killService approach
  // Fallback: find PID via sysctl and kill it
  id proxy = _proxy(bundleID);
  if (!proxy) {
    logMsg("❌ [AppCtrl] No proxy for: %s", bundleID.UTF8String);
    return NO;
  }

  // Try terminateApplicationWithBundleID via workspace
  id ws = _workspace();
  SEL sel = NSSelectorFromString(@"terminateApplicationWithBundleID:");
  if ([ws respondsToSelector:sel]) {
    @try {
      [ws performSelector:sel withObject:bundleID];
      logMsg("✅ [AppCtrl] Killed: %s", bundleID.UTF8String);
      return YES;
    } @catch (NSException *e) {
      logMsg("⚠️ [AppCtrl] Kill exception: %s", e.reason.UTF8String);
    }
  }

  logMsg("❌ [AppCtrl] kill not supported on this OS version");
  return NO;
}

BOOL ic_appIsRunning(NSString *bundleID) {
  if (!bundleID.length)
    return NO;
  id ws = _workspace();
  if (!ws)
    return NO;

  // applicationProcessInfo:forBundleID is available on older iOS
  // Attempt via frontmost / running processes
  SEL sel = NSSelectorFromString(@"applicationProcessIdentifierForBundleID:");
  if ([ws respondsToSelector:sel]) {
    @try {
      int pid = (int)(intptr_t)[ws performSelector:sel withObject:bundleID];
      return (pid > 0);
    } @catch (__unused NSException *e) {
    }
  }

  // Fallback: check via proxy state
  id proxy = _proxy(bundleID);
  if (!proxy)
    return NO;
  SEL stateSel = NSSelectorFromString(@"isRunning");
  if ([proxy respondsToSelector:stateSel]) {
    return (BOOL)[proxy performSelector:stateSel];
  }
  return NO;
}

NSString *ic_appFrontmost(void) {
  // Use SBApplication / SpringBoard to get frontmost
  // Available approach: FBSSystemService or SpringBoard notifications
  // Simple: use LSApplicationWorkspace frontmostApplication
  id ws = _workspace();
  if (!ws)
    return nil;

  SEL sel = NSSelectorFromString(@"frontmostApplicationIdentifier");
  if ([ws respondsToSelector:sel]) {
    @try {
      NSString *bid = [ws performSelector:sel];
      logMsg("📱 [AppCtrl] Frontmost: %s", bid.UTF8String ?: "nil");
      return bid;
    } @catch (__unused NSException *e) {
    }
  }

  // Alternative: check via SBApplicationController
  Class sbCtrl = NSClassFromString(@"SBApplicationController");
  if (sbCtrl) {
    id ctrl = [sbCtrl performSelector:NSSelectorFromString(@"sharedInstance")];
    id app =
        [ctrl performSelector:NSSelectorFromString(@"frontmostApplication")];
    if (app) {
      return [app performSelector:NSSelectorFromString(@"bundleIdentifier")];
    }
  }

  return nil;
}
