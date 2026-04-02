// ICScriptManager.m — Script file management for IOSControl daemon
// Stores Lua scripts in the app's Documents/scripts/ directory

#import "ICScriptManager.h"

extern void logMsg(const char *fmt, ...);

// ═══════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════

NSString *ic_scriptsDir(void) {
  // Use NSDocumentDirectory relative to app container
  // Daemon inherits the app's sandbox, so this works via posix_spawn
  NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                       NSUserDomainMask, YES);
  NSString *docs = paths.firstObject;
  if (!docs) {
    // Fallback for daemon that may not have HomeDir set
    docs = @"/var/mobile/Containers/Data/Application";
    logMsg("⚠️ [ScriptMgr] NSDocumentDirectory nil, using fallback");
  }
  NSString *scriptsDir = [docs stringByAppendingPathComponent:@"scripts"];
  NSFileManager *fm = [NSFileManager defaultManager];
  if (![fm fileExistsAtPath:scriptsDir]) {
    NSError *err = nil;
    [fm createDirectoryAtPath:scriptsDir
        withIntermediateDirectories:YES
                         attributes:nil
                              error:&err];
    if (err) {
      logMsg("❌ [ScriptMgr] Cannot create scripts dir: %s",
             err.localizedDescription.UTF8String);
    } else {
      logMsg("📁 [ScriptMgr] Created scripts dir: %s", scriptsDir.UTF8String);
    }
  }
  return scriptsDir;
}

// Sanitize filename: strip directory traversal, ensure .lua extension
static NSString *sanitizeName(NSString *name) {
  if (!name || name.length == 0)
    return nil;
  // Strip any path components
  name = name.lastPathComponent;
  // Ensure .lua extension
  if (![name.pathExtension.lowercaseString isEqualToString:@"lua"]) {
    name = [name stringByAppendingPathExtension:@"lua"];
  }
  return name;
}

// ═══════════════════════════════════════════
// Public API
// ═══════════════════════════════════════════

NSArray<NSString *> *ic_scriptList(void) {
  NSString *dir = ic_scriptsDir();
  NSFileManager *fm = [NSFileManager defaultManager];
  NSError *err = nil;
  NSArray *all = [fm contentsOfDirectoryAtPath:dir error:&err];
  if (err) {
    logMsg("❌ [ScriptMgr] List error: %s",
           err.localizedDescription.UTF8String);
    return @[];
  }
  // Filter to .lua only, sort alphabetically
  NSArray *lua = [all
      filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(
                                                   NSString *name,
                                                   NSDictionary *bindings) {
        return [name.pathExtension.lowercaseString isEqualToString:@"lua"];
      }]];
  return [lua sortedArrayUsingSelector:@selector(compare:)];
}

NSString *ic_scriptRead(NSString *name) {
  name = sanitizeName(name);
  if (!name)
    return nil;
  NSString *path = [ic_scriptsDir() stringByAppendingPathComponent:name];
  NSError *err = nil;
  NSString *content = [NSString stringWithContentsOfFile:path
                                                encoding:NSUTF8StringEncoding
                                                   error:&err];
  if (err) {
    logMsg("❌ [ScriptMgr] Read '%s' error: %s", name.UTF8String,
           err.localizedDescription.UTF8String);
    return nil;
  }
  return content;
}

BOOL ic_scriptWrite(NSString *name, NSString *content) {
  name = sanitizeName(name);
  if (!name || !content)
    return NO;
  NSString *path = [ic_scriptsDir() stringByAppendingPathComponent:name];
  NSError *err = nil;
  BOOL ok = [content writeToFile:path
                      atomically:YES
                        encoding:NSUTF8StringEncoding
                           error:&err];
  if (!ok) {
    logMsg("❌ [ScriptMgr] Write '%s' error: %s", name.UTF8String,
           err.localizedDescription.UTF8String);
  } else {
    logMsg("💾 [ScriptMgr] Saved: %s (%zu bytes)", name.UTF8String,
           content.length);
  }
  return ok;
}

BOOL ic_scriptDelete(NSString *name) {
  name = sanitizeName(name);
  if (!name)
    return NO;
  NSString *path = [ic_scriptsDir() stringByAppendingPathComponent:name];
  NSFileManager *fm = [NSFileManager defaultManager];
  if (![fm fileExistsAtPath:path])
    return NO;
  NSError *err = nil;
  BOOL ok = [fm removeItemAtPath:path error:&err];
  if (!ok) {
    logMsg("❌ [ScriptMgr] Delete '%s' error: %s", name.UTF8String,
           err.localizedDescription.UTF8String);
  } else {
    logMsg("🗑 [ScriptMgr] Deleted: %s", name.UTF8String);
  }
  return ok;
}
