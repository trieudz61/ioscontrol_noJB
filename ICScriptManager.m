// ICScriptManager.m — Script file management for IOSControl daemon
// Stores Lua scripts in the app's Documents/scripts/ directory

#import "ICScriptManager.h"

extern void logMsg(const char *fmt, ...);

// ═══════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════

NSString *ic_scriptsDir(void) {
  // Use /var/mobile/Documents/scripts — shared path accessible from both
  // daemon sandbox and user-accessible via e.g. Filza/ssh
  static NSString *scriptsDir = @"/var/mobile/Documents/scripts";
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

// Sanitize filename: strip directory traversal
// Auto-assign .lua if no extension; accept both .lua and .txt
static NSString *sanitizeName(NSString *name) {
  if (!name || name.length == 0)
    return nil;
  // Strip any path components
  name = name.lastPathComponent;
  NSString *ext = name.pathExtension.lowercaseString;
  if (ext.length == 0) {
    name = [name stringByAppendingPathExtension:@"lua"];
  } else if (![ext isEqualToString:@"lua"] && ![ext isEqualToString:@"txt"]) {
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
  // Filter to .lua and .txt, sort alphabetically
  NSArray *scripts = [all
      filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(
                                                   NSString *name,
                                                   NSDictionary *bindings) {
        NSString *ext = name.pathExtension.lowercaseString;
        return [ext isEqualToString:@"lua"] || [ext isEqualToString:@"txt"];
      }]];
  return [scripts sortedArrayUsingSelector:@selector(compare:)];
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
