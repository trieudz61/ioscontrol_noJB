// ICLuaStdlib.h — Phase 10: Lua stdlib modules
// Provides: json, base64, re (regex), http, sys.alert, sys.toast

#pragma once
#include "lua/lua.h"

/// Register all stdlib modules into a lua_State
void ic_luaStdlibRegister(lua_State *L);
