// ICLuaEngine.h — Lua 5.4 scripting engine for IOSControl daemon
// Zero external dependencies (Lua source embedded in lua/ directory)

#pragma once
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, ICLuaStatus) {
    kLuaIdle    = 0,
    kLuaRunning = 1,
    kLuaError   = 2,
};

/// Initialize the Lua engine (call once at daemon startup)
void ic_luaInit(void);

/// Execute a Lua script snippet asynchronously on the script queue.
/// Completion block is called on the main queue when script finishes.
void ic_luaExec(const char *code);

/// Request script stop (sets interrupt hook; script may not stop instantly)
void ic_luaStop(void);

/// Current execution status
ICLuaStatus ic_luaGetStatus(void);

/// Last error message (valid when status == kLuaError, else empty string)
const char *ic_luaGetLastError(void);
