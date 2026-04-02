// ICScriptManager.h — Script file management for IOSControl daemon
// Stores Lua scripts in <AppDataDir>/Documents/scripts/

#pragma once
#import <Foundation/Foundation.h>

// Returns path to scripts directory (creates if needed)
NSString *ic_scriptsDir(void);

// List all .lua scripts → NSArray of filenames (basename only)
NSArray<NSString *> *ic_scriptList(void);

// Read script content → NSString (nil if not found)
NSString *ic_scriptRead(NSString *name);

// Write script content → YES on success
BOOL ic_scriptWrite(NSString *name, NSString *content);

// Delete script → YES on success
BOOL ic_scriptDelete(NSString *name);
