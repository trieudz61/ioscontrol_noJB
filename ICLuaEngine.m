// ICLuaEngine.m — Lua 5.4 scripting engine for IOSControl daemon
// Embeds Lua 5.4 VM; provides sys/touch/screen API to scripts.
// Each script run creates a fresh lua_State for clean isolation.

#import "ICLuaEngine.h"
#import "ICAppControl.h"
#import "ICKeyInput.h"
#import "ICLuaStdlib.h"
#import "ICScreenCapture.h"
#import "ICVision.h"

// Lua C API (from embedded source)
#include "lua/lauxlib.h"
#include "lua/lua.h"
#include "lua/lualib.h"

// ═══════════════════════════════════════════
// Forward declarations from IOSControlDaemon
// ═══════════════════════════════════════════

extern void logMsg(const char *fmt, ...);
extern void ic_tap(double x, double y);
extern void ic_swipe(double x1, double y1, double x2, double y2,
                     double duration);
extern void ic_longPress(double x, double y, double duration);
extern void ic_touchDown(double x, double y, int finger);
extern void ic_touchMove(double x, double y, int finger);
extern void ic_touchUp(double x, double y, int finger);
extern double gScreenW;
extern double gScreenH;

// ═══════════════════════════════════════════
// Global state
// ═══════════════════════════════════════════

static dispatch_queue_t gLuaQueue; // serial queue for script execution
static volatile int gStopFlag;     // atomic stop request
static ICLuaStatus gStatus = kLuaIdle;
static char gLastError[1024] = {0};
static dispatch_semaphore_t gRunSema; // prevents concurrent runs

// ═══════════════════════════════════════════
// Interrupt hook — checks gStopFlag every N instructions
// ═══════════════════════════════════════════

static void luaInterruptHook(lua_State *L, lua_Debug *ar) {
  (void)ar;
  if (gStopFlag) {
    luaL_error(L, "script stopped by user");
  }
}

// ═══════════════════════════════════════════
// sys bindings
// ═══════════════════════════════════════════

// sys.log(msg)
static int lua_sys_log(lua_State *L) {
  const char *msg = luaL_checkstring(L, 1);
  logMsg("💬 [Lua] %s", msg);
  return 0;
}

// sys.toast(msg)  — alias for sys.log on daemon (no UI toast available)
static int lua_sys_toast(lua_State *L) { return lua_sys_log(L); }

// sys.msleep(ms)
static int lua_sys_msleep(lua_State *L) {
  lua_Integer ms = luaL_checkinteger(L, 1);
  if (ms > 0) {
    usleep((useconds_t)(ms * 1000));
  }
  return 0;
}

// sys.sleep(sec)
static int lua_sys_sleep(lua_State *L) {
  lua_Number sec = luaL_checknumber(L, 1);
  if (sec > 0) {
    usleep((useconds_t)(sec * 1000000.0));
  }
  return 0;
}

static const luaL_Reg kSysLib[] = {{"log", lua_sys_log},
                                   {"toast", lua_sys_toast},
                                   {"msleep", lua_sys_msleep},
                                   {"sleep", lua_sys_sleep},
                                   {NULL, NULL}};

// ═══════════════════════════════════════════
// touch bindings
// ═══════════════════════════════════════════

// touch.tap(x, y)
static int lua_touch_tap(lua_State *L) {
  double x = luaL_checknumber(L, 1);
  double y = luaL_checknumber(L, 2);
  ic_tap(x, y);
  logMsg("🤖 [Lua] touch.tap(%.0f, %.0f)", x, y);
  return 0;
}

// touch.swipe(x1, y1, x2, y2 [, duration])
static int lua_touch_swipe(lua_State *L) {
  double x1 = luaL_checknumber(L, 1);
  double y1 = luaL_checknumber(L, 2);
  double x2 = luaL_checknumber(L, 3);
  double y2 = luaL_checknumber(L, 4);
  double dur = luaL_optnumber(L, 5, 0.3);
  ic_swipe(x1, y1, x2, y2, dur);
  logMsg("🤖 [Lua] touch.swipe(%.0f,%.0f→%.0f,%.0f) %.2fs", x1, y1, x2, y2,
         dur);
  return 0;
}

// touch.long_press(x, y [, duration])
static int lua_touch_long_press(lua_State *L) {
  double x = luaL_checknumber(L, 1);
  double y = luaL_checknumber(L, 2);
  double dur = luaL_optnumber(L, 3, 1.0);
  ic_longPress(x, y, dur);
  logMsg("🤖 [Lua] touch.long_press(%.0f, %.0f) %.2fs", x, y, dur);
  return 0;
}

// touch.down(x, y [, finger])
static int lua_touch_down(lua_State *L) {
  double x = luaL_checknumber(L, 1);
  double y = luaL_checknumber(L, 2);
  lua_Integer f = luaL_optinteger(L, 3, 0);
  ic_touchDown(x, y, (int)f);
  return 0;
}

// touch.move(x, y [, finger])
static int lua_touch_move(lua_State *L) {
  double x = luaL_checknumber(L, 1);
  double y = luaL_checknumber(L, 2);
  lua_Integer f = luaL_optinteger(L, 3, 0);
  ic_touchMove(x, y, (int)f);
  return 0;
}

// touch.up(x, y [, finger])
static int lua_touch_up(lua_State *L) {
  double x = luaL_checknumber(L, 1);
  double y = luaL_checknumber(L, 2);
  lua_Integer f = luaL_optinteger(L, 3, 0);
  ic_touchUp(x, y, (int)f);
  return 0;
}

static const luaL_Reg kTouchLib[] = {{"tap", lua_touch_tap},
                                     {"swipe", lua_touch_swipe},
                                     {"long_press", lua_touch_long_press},
                                     {"down", lua_touch_down},
                                     {"move", lua_touch_move},
                                     {"up", lua_touch_up},
                                     {NULL, NULL}};

// ═══════════════════════════════════════════
// screen bindings
// ═══════════════════════════════════════════

// screen.get_size() → width, height (two return values)
static int lua_screen_get_size(lua_State *L) {
  lua_pushnumber(L, gScreenW);
  lua_pushnumber(L, gScreenH);
  return 2;
}

// screen.get_color(x, y) → "#RRGGBB"
static int lua_screen_get_color(lua_State *L) {
  int x = (int)luaL_checkinteger(L, 1);
  int y = (int)luaL_checkinteger(L, 2);
  int r = 0, g = 0, b = 0;
  BOOL ok = ic_getColorAtPoint(x, y, &r, &g, &b);
  if (!ok) {
    lua_pushnil(L);
    lua_pushstring(L, "color sampling failed");
    return 2;
  }
  char hex[10];
  snprintf(hex, sizeof(hex), "#%02X%02X%02X", r, g, b);
  lua_pushstring(L, hex);
  return 1;
}

// screen.capture() — triggers a capture and caches internally (uses existing
// ic_captureScreen)
static int lua_screen_capture(lua_State *L) {
  NSData *jpeg = ic_captureScreen(0.8f);
  if (!jpeg || [jpeg length] == 0) {
    lua_pushboolean(L, 0);
    lua_pushstring(L, "capture failed");
    return 2;
  }
  lua_pushboolean(L, 1);
  lua_pushinteger(L, (lua_Integer)[jpeg length]);
  return 2;
}

// screen.ocr() → table of strings (or nil, errmsg)
static int lua_screen_ocr(lua_State *L) {
  NSArray<NSString *> *texts = ic_ocrScreen();
  if (!texts) {
    lua_pushnil(L);
    lua_pushstring(L, "OCR failed");
    return 2;
  }
  lua_newtable(L);
  for (int i = 0; i < (int)texts.count; i++) {
    lua_pushstring(L, texts[i].UTF8String);
    lua_rawseti(L, -2, i + 1);
  }
  return 1;
}

// screen.find_color(r, g, b [, tolerance]) → x, y  (or nil, errmsg)
static int lua_screen_find_color(lua_State *L) {
  int r = (int)luaL_checkinteger(L, 1);
  int g = (int)luaL_checkinteger(L, 2);
  int b = (int)luaL_checkinteger(L, 3);
  int tol = (int)luaL_optinteger(L, 4, 10);
  int outX = 0, outY = 0;
  BOOL found = ic_findColor(r, g, b, tol, &outX, &outY);
  if (!found) {
    lua_pushnil(L);
    lua_pushstring(L, "color not found");
    return 2;
  }
  lua_pushinteger(L, outX);
  lua_pushinteger(L, outY);
  return 2;
}

// screen.find_multi_color(r, g, b [, tolerance [, max]]) → table of {x,y}
static int lua_screen_find_multi_color(lua_State *L) {
  int r = (int)luaL_checkinteger(L, 1);
  int g = (int)luaL_checkinteger(L, 2);
  int b = (int)luaL_checkinteger(L, 3);
  int tol = (int)luaL_optinteger(L, 4, 10);
  int maxN = (int)luaL_optinteger(L, 5, 100);
  NSArray<NSDictionary *> *pts = ic_findMultiColor(r, g, b, tol, maxN);
  lua_newtable(L);
  for (int i = 0; i < (int)pts.count; i++) {
    lua_newtable(L);
    lua_pushinteger(L, [pts[i][@"x"] intValue]);
    lua_setfield(L, -2, "x");
    lua_pushinteger(L, [pts[i][@"y"] intValue]);
    lua_setfield(L, -2, "y");
    lua_rawseti(L, -2, i + 1);
  }
  return 1;
}

static const luaL_Reg kScreenLib[] = {
    {"get_size", lua_screen_get_size},
    {"get_color", lua_screen_get_color},
    {"capture", lua_screen_capture},
    {"ocr", lua_screen_ocr},
    {"find_color", lua_screen_find_color},
    {"find_multi_color", lua_screen_find_multi_color},
    {NULL, NULL}};

// ═══════════════════════════════════════════
// Phase 7b: app bindings
// ═══════════════════════════════════════════

// app.launch(bundleID) → true/false
static int lua_app_launch(lua_State *L) {
  const char *bid = luaL_checkstring(L, 1);
  BOOL ok = ic_appLaunch([NSString stringWithUTF8String:bid]);
  lua_pushboolean(L, ok);
  return 1;
}

// app.kill(bundleID) → true/false
static int lua_app_kill(lua_State *L) {
  const char *bid = luaL_checkstring(L, 1);
  BOOL ok = ic_appKill([NSString stringWithUTF8String:bid]);
  lua_pushboolean(L, ok);
  return 1;
}

// app.is_running(bundleID) → true/false
static int lua_app_is_running(lua_State *L) {
  const char *bid = luaL_checkstring(L, 1);
  BOOL ok = ic_appIsRunning([NSString stringWithUTF8String:bid]);
  lua_pushboolean(L, ok);
  return 1;
}

// app.frontmost() → bundleID string or nil
static int lua_app_frontmost(lua_State *L) {
  NSString *bid = ic_appFrontmost();
  if (bid)
    lua_pushstring(L, bid.UTF8String);
  else
    lua_pushnil(L);
  return 1;
}

// app.list() → table of {bundleID, name, version}
static int lua_app_list(lua_State *L) {
  NSArray<NSDictionary *> *apps = ic_appList();
  lua_newtable(L);
  for (int i = 0; i < (int)apps.count; i++) {
    lua_newtable(L);
    lua_pushstring(L, [apps[i][@"bundleID"] UTF8String] ?: "");
    lua_setfield(L, -2, "bundleID");
    lua_pushstring(L, [apps[i][@"name"] UTF8String] ?: "");
    lua_setfield(L, -2, "name");
    lua_pushstring(L, [apps[i][@"version"] UTF8String] ?: "");
    lua_setfield(L, -2, "version");
    lua_rawseti(L, -2, i + 1);
  }
  return 1;
}

static const luaL_Reg kAppLib[] = {{"launch", lua_app_launch},
                                   {"kill", lua_app_kill},
                                   {"is_running", lua_app_is_running},
                                   {"frontmost", lua_app_frontmost},
                                   {"list", lua_app_list},
                                   {NULL, NULL}};

// ═══════════════════════════════════════════
// Phase 7c: key bindings
// ═══════════════════════════════════════════

// key.press(page, usage) → true/false
static int lua_key_press(lua_State *L) {
  lua_Integer page = luaL_optinteger(L, 1, 0x07);
  lua_Integer usage = luaL_checkinteger(L, 2);
  BOOL ok = ic_keyPress((uint32_t)page, (uint32_t)usage);
  lua_pushboolean(L, ok);
  return 1;
}

// key.input_text(text) → true/false
static int lua_key_input_text(lua_State *L) {
  const char *text = luaL_checkstring(L, 1);
  BOOL ok = ic_keyInputText([NSString stringWithUTF8String:text]);
  lua_pushboolean(L, ok);
  return 1;
}

static const luaL_Reg kKeyLib[] = {
    {"press", lua_key_press}, {"input_text", lua_key_input_text}, {NULL, NULL}};

// ═══════════════════════════════════════════
// Phase 7d: clipboard bindings
// ═══════════════════════════════════════════

// clipboard.read() → string
static int lua_clipboard_read(lua_State *L) {
  Class pb = NSClassFromString(@"UIPasteboard");
  NSString *text = nil;
  if (pb) {
    id gen = [pb performSelector:NSSelectorFromString(@"generalPasteboard")];
    if (gen)
      text = [gen performSelector:NSSelectorFromString(@"string")];
  }
  lua_pushstring(L, text ? text.UTF8String : "");
  return 1;
}

// clipboard.write(text)
static int lua_clipboard_write(lua_State *L) {
  const char *text = luaL_checkstring(L, 1);
  NSString *str = [NSString stringWithUTF8String:text];
  Class pb = NSClassFromString(@"UIPasteboard");
  BOOL ok = NO;
  if (pb) {
    id gen = [pb performSelector:NSSelectorFromString(@"generalPasteboard")];
    if (gen) {
      [gen performSelector:NSSelectorFromString(@"setString:") withObject:str];
      ok = YES;
    }
  }
  lua_pushboolean(L, ok);
  return 1;
}

static const luaL_Reg kClipboardLib[] = {
    {"read", lua_clipboard_read}, {"write", lua_clipboard_write}, {NULL, NULL}};

// ═══════════════════════════════════════════
// Register all custom libraries into a state
// ═══════════════════════════════════════════

static void registerLibs(lua_State *L) {
  // sys table
  lua_newtable(L);
  luaL_setfuncs(L, kSysLib, 0);
  lua_setglobal(L, "sys");

  // touch table
  lua_newtable(L);
  luaL_setfuncs(L, kTouchLib, 0);
  lua_setglobal(L, "touch");

  // screen table
  lua_newtable(L);
  luaL_setfuncs(L, kScreenLib, 0);
  lua_setglobal(L, "screen");

  // app table (Phase 7b)
  lua_newtable(L);
  luaL_setfuncs(L, kAppLib, 0);
  lua_setglobal(L, "app");

  // key table (Phase 7c)
  lua_newtable(L);
  luaL_setfuncs(L, kKeyLib, 0);
  lua_setglobal(L, "key");

  // clipboard table (Phase 7d)
  lua_newtable(L);
  luaL_setfuncs(L, kClipboardLib, 0);
  lua_setglobal(L, "clipboard");

  // Also alias print → sys.log so print() works
  lua_pushcfunction(L, lua_sys_log);
  lua_setglobal(L, "print");

  // Phase 10: stdlib (json, base64, re, http, timer, sys.alert/toast)
  ic_luaStdlibRegister(L);
}

// ═══════════════════════════════════════════
// Public API
// ═══════════════════════════════════════════

void ic_luaInit(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    gLuaQueue =
        dispatch_queue_create("com.ioscontrol.lua", DISPATCH_QUEUE_SERIAL);
    gRunSema = dispatch_semaphore_create(1); // 1 = allow one runner at a time
    gStatus = kLuaIdle;
    gStopFlag = 0;
    logMsg("🌙 Lua 5.4 scripting engine initialized");
  });
}

void ic_luaExec(const char *code) {
  if (!code || strlen(code) == 0)
    return;

  // Make a copy so the caller's buffer can be freed
  NSString *codeStr = [NSString stringWithUTF8String:code];

  dispatch_async(gLuaQueue, ^{
    // If another script is already in the slot, bail
    if (dispatch_semaphore_wait(gRunSema, DISPATCH_TIME_NOW) != 0) {
      logMsg("⚠️ [Lua] Script already running, ignoring new exec request");
      return;
    }

    gStopFlag = 0;
    gStatus = kLuaRunning;
    gLastError[0] = '\0';

    logMsg("▶️  [Lua] Script started");

    // Create fresh state per run
    lua_State *L = luaL_newstate();
    if (!L) {
      snprintf(gLastError, sizeof(gLastError), "luaL_newstate() failed");
      gStatus = kLuaError;
      dispatch_semaphore_signal(gRunSema);
      return;
    }

    // Open safe standard libs (no io/os/package for security)
    luaL_requiref(L, "_G", luaopen_base, 1);
    lua_pop(L, 1);
    luaL_requiref(L, LUA_MATHLIBNAME, luaopen_math, 1);
    lua_pop(L, 1);
    luaL_requiref(L, LUA_STRLIBNAME, luaopen_string, 1);
    lua_pop(L, 1);
    luaL_requiref(L, LUA_TABLIBNAME, luaopen_table, 1);
    lua_pop(L, 1);

    // Register custom libs
    registerLibs(L);

    // Install interrupt hook (every 1000 instructions)
    lua_sethook(L, luaInterruptHook, LUA_MASKCOUNT, 1000);

    // Execute
    int rc = luaL_dostring(L, [codeStr UTF8String]);
    if (rc != LUA_OK) {
      const char *err = lua_tostring(L, -1);
      // Don't report "stopped by user" as real error
      if (err && strstr(err, "script stopped by user")) {
        logMsg("⏹  [Lua] Script stopped by user");
        gStatus = kLuaIdle;
      } else {
        snprintf(gLastError, sizeof(gLastError), "%s",
                 err ? err : "unknown error");
        logMsg("❌ [Lua] Error: %s", gLastError);
        gStatus = kLuaError;
      }
      lua_pop(L, 1);
    } else {
      logMsg("✅ [Lua] Script completed successfully");
      gStatus = kLuaIdle;
    }

    lua_close(L);
    gStopFlag = 0;
    dispatch_semaphore_signal(gRunSema);
  });
}

void ic_luaStop(void) {
  if (gStatus == kLuaRunning) {
    __atomic_store_n(&gStopFlag, 1, __ATOMIC_RELEASE);
    logMsg("⏹  [Lua] Stop requested");
  }
}

ICLuaStatus ic_luaGetStatus(void) { return gStatus; }

const char *ic_luaGetLastError(void) { return gLastError; }
