// ICLuaStdlib.m — Phase 10: Lua Standard Library
// Modules: json, base64, re, http, sys.alert / sys.toast (extended)
// All zero-dependency: NSJSONSerialization, NSRegularExpression, NSURLSession

#import "ICLuaStdlib.h"
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>
#import <objc/message.h>

#include "lua/lauxlib.h"
#include "lua/lua.h"
#include "lua/lualib.h"

extern void logMsg(const char *fmt, ...);
extern void ic_pressKey(const char *name);
extern void ic_holdKey(const char *name);
extern void ic_releaseKey(const char *name);
extern BOOL ic_keyInputText(NSString *text);

// ═══════════════════════════════════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════════════════════════════════

static void pushNSObject(lua_State *L, id obj);

static void pushNSDictionary(lua_State *L, NSDictionary *d) {
  lua_newtable(L);
  [d enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *s) {
    lua_pushstring(L, [k description].UTF8String);
    pushNSObject(L, v);
    lua_rawset(L, -3);
  }];
}

static void pushNSArray(lua_State *L, NSArray *a) {
  lua_newtable(L);
  for (int i = 0; i < (int)a.count; i++) {
    pushNSObject(L, a[i]);
    lua_rawseti(L, -2, i + 1);
  }
}

static void pushNSObject(lua_State *L, id obj) {
  if (!obj || obj == [NSNull null]) {
    lua_pushnil(L);
  } else if ([obj isKindOfClass:[NSNumber class]]) {
    // bool vs number
    if (strcmp([obj objCType], @encode(BOOL)) == 0 ||
        strcmp([obj objCType], @encode(bool)) == 0) {
      lua_pushboolean(L, [(NSNumber *)obj boolValue]);
    } else if ([obj respondsToSelector:@selector(integerValue)] &&
               [(NSNumber *)obj doubleValue] ==
                   (double)[(NSNumber *)obj integerValue]) {
      lua_pushinteger(L, [(NSNumber *)obj integerValue]);
    } else {
      lua_pushnumber(L, [(NSNumber *)obj doubleValue]);
    }
  } else if ([obj isKindOfClass:[NSString class]]) {
    lua_pushstring(L, [(NSString *)obj UTF8String]);
  } else if ([obj isKindOfClass:[NSDictionary class]]) {
    pushNSDictionary(L, obj);
  } else if ([obj isKindOfClass:[NSArray class]]) {
    pushNSArray(L, obj);
  } else {
    lua_pushstring(L, [[obj description] UTF8String]);
  }
}

// Convert Lua table at index to NSObject (recursive)
static id luaToNSObject(lua_State *L, int idx);

static NSDictionary *luaTableToDict(lua_State *L, int idx) {
  NSMutableDictionary *d = [NSMutableDictionary dictionary];
  lua_pushnil(L);
  while (lua_next(L, idx) != 0) {
    NSString *k = [NSString stringWithUTF8String:luaL_tolstring(L, -2, NULL)];
    lua_pop(L, 1); // pop tostring result
    id v = luaToNSObject(L, lua_gettop(L));
    if (k && v)
      d[k] = v;
    lua_pop(L, 1);
  }
  return d;
}

static NSArray *luaTableToArray(lua_State *L, int idx) {
  NSMutableArray *a = [NSMutableArray array];
  int n = (int)lua_rawlen(L, idx);
  for (int i = 1; i <= n; i++) {
    lua_rawgeti(L, idx, i);
    id v = luaToNSObject(L, lua_gettop(L));
    [a addObject:v ?: [NSNull null]];
    lua_pop(L, 1);
  }
  return a;
}

static id luaToNSObject(lua_State *L, int idx) {
  int t = lua_type(L, idx);
  switch (t) {
  case LUA_TNIL:
    return [NSNull null];
  case LUA_TBOOLEAN:
    return @((BOOL)lua_toboolean(L, idx));
  case LUA_TNUMBER:
    if (lua_isinteger(L, idx))
      return @(lua_tointeger(L, idx));
    return @(lua_tonumber(L, idx));
  case LUA_TSTRING:
    return [NSString stringWithUTF8String:lua_tostring(L, idx)];
  case LUA_TTABLE: {
    // Detect array vs dict: if key 1 exists, assume array
    lua_rawgeti(L, idx, 1);
    BOOL isArr = !lua_isnil(L, -1);
    lua_pop(L, 1);
    return isArr ? luaTableToArray(L, idx) : luaTableToDict(L, idx);
  }
  default:
    return [NSNull null];
  }
}

// ═══════════════════════════════════════════════════════════════════════
// 10a-1: json module
// ═══════════════════════════════════════════════════════════════════════

// json.encode(table) → string
static int lua_json_encode(lua_State *L) {
  luaL_checkany(L, 1);
  id obj = luaToNSObject(L, 1);
  if (!obj || obj == [NSNull null]) {
    lua_pushnil(L);
    return 1;
  }
  NSError *err;
  NSData *data =
      [NSJSONSerialization dataWithJSONObject:obj
                                      options:NSJSONWritingPrettyPrinted
                                        error:&err];
  if (!data) {
    lua_pushnil(L);
    lua_pushstring(L,
                   err.localizedDescription.UTF8String ?: "json.encode error");
    return 2;
  }
  lua_pushstring(L, [[NSString alloc] initWithData:data
                                          encoding:NSUTF8StringEncoding]
                        .UTF8String);
  return 1;
}

// json.decode(str) → table/value
static int lua_json_decode(lua_State *L) {
  const char *s = luaL_checkstring(L, 1);
  NSData *data = [NSData dataWithBytes:s length:strlen(s)];
  NSError *err;
  id obj = [NSJSONSerialization JSONObjectWithData:data
                                           options:NSJSONReadingAllowFragments
                                             error:&err];
  if (!obj) {
    lua_pushnil(L);
    lua_pushstring(L,
                   err.localizedDescription.UTF8String ?: "json.decode error");
    return 2;
  }
  pushNSObject(L, obj);
  return 1;
}

static const luaL_Reg kJsonLib[] = {
    {"encode", lua_json_encode}, {"decode", lua_json_decode}, {NULL, NULL}};

// ═══════════════════════════════════════════════════════════════════════
// 10a-2: base64 module
// ═══════════════════════════════════════════════════════════════════════

// base64.encode(str) → string
static int lua_b64_encode(lua_State *L) {
  size_t len;
  const char *s = luaL_checklstring(L, 1, &len);
  NSData *data = [NSData dataWithBytes:s length:len];
  NSString *b64 = [data base64EncodedStringWithOptions:0];
  lua_pushstring(L, b64.UTF8String ?: "");
  return 1;
}

// base64.decode(str) → string (raw bytes)
static int lua_b64_decode(lua_State *L) {
  const char *s = luaL_checkstring(L, 1);
  NSData *data = [[NSData alloc]
      initWithBase64EncodedString:[NSString stringWithUTF8String:s]
                          options:NSDataBase64DecodingIgnoreUnknownCharacters];
  if (!data) {
    lua_pushnil(L);
    return 1;
  }
  lua_pushlstring(L, (const char *)data.bytes, data.length);
  return 1;
}

static const luaL_Reg kBase64Lib[] = {
    {"encode", lua_b64_encode}, {"decode", lua_b64_decode}, {NULL, NULL}};

// ═══════════════════════════════════════════════════════════════════════
// 10a-3: re (regex) module
// ═══════════════════════════════════════════════════════════════════════

// re.match(str, pattern) → match_str or nil
static int lua_re_match(lua_State *L) {
  const char *str = luaL_checkstring(L, 1);
  const char *pat = luaL_checkstring(L, 2);
  NSString *input = [NSString stringWithUTF8String:str];
  NSError *err;
  NSRegularExpression *rx = [NSRegularExpression
      regularExpressionWithPattern:[NSString stringWithUTF8String:pat]
                           options:0
                             error:&err];
  if (!rx) {
    lua_pushnil(L);
    return 1;
  }
  NSTextCheckingResult *m =
      [rx firstMatchInString:input
                     options:0
                       range:NSMakeRange(0, input.length)];
  if (!m) {
    lua_pushnil(L);
    return 1;
  }
  lua_pushstring(L, [input substringWithRange:m.range].UTF8String);
  return 1;
}

// re.gmatch(str, pattern) → table of matches
static int lua_re_gmatch(lua_State *L) {
  const char *str = luaL_checkstring(L, 1);
  const char *pat = luaL_checkstring(L, 2);
  NSString *input = [NSString stringWithUTF8String:str];
  NSError *err;
  NSRegularExpression *rx = [NSRegularExpression
      regularExpressionWithPattern:[NSString stringWithUTF8String:pat]
                           options:0
                             error:&err];
  lua_newtable(L);
  if (!rx)
    return 1;
  NSArray<NSTextCheckingResult *> *matches =
      [rx matchesInString:input options:0 range:NSMakeRange(0, input.length)];
  for (int i = 0; i < (int)matches.count; i++) {
    lua_pushstring(L, [input substringWithRange:matches[i].range].UTF8String);
    lua_rawseti(L, -2, i + 1);
  }
  return 1;
}

// re.gsub(str, pattern, replacement) → new string
static int lua_re_gsub(lua_State *L) {
  const char *str = luaL_checkstring(L, 1);
  const char *pat = luaL_checkstring(L, 2);
  const char *rep = luaL_checkstring(L, 3);
  NSString *input = [NSString stringWithUTF8String:str];
  NSError *err;
  NSRegularExpression *rx = [NSRegularExpression
      regularExpressionWithPattern:[NSString stringWithUTF8String:pat]
                           options:0
                             error:&err];
  if (!rx) {
    lua_pushstring(L, str);
    return 1;
  }
  NSString *result =
      [rx stringByReplacingMatchesInString:input
                                   options:0
                                     range:NSMakeRange(0, input.length)
                              withTemplate:[NSString stringWithUTF8String:rep]];
  lua_pushstring(L, result.UTF8String ?: str);
  return 1;
}

// re.test(str, pattern) → bool
static int lua_re_test(lua_State *L) {
  const char *str = luaL_checkstring(L, 1);
  const char *pat = luaL_checkstring(L, 2);
  NSString *input = [NSString stringWithUTF8String:str];
  NSError *err;
  NSRegularExpression *rx = [NSRegularExpression
      regularExpressionWithPattern:[NSString stringWithUTF8String:pat]
                           options:0
                             error:&err];
  BOOL found =
      rx && [rx firstMatchInString:input
                           options:0
                             range:NSMakeRange(0, input.length)] != nil;
  lua_pushboolean(L, found);
  return 1;
}

static const luaL_Reg kReLib[] = {{"match", lua_re_match},
                                  {"gmatch", lua_re_gmatch},
                                  {"gsub", lua_re_gsub},
                                  {"test", lua_re_test},
                                  {NULL, NULL}};

// ═══════════════════════════════════════════════════════════════════════
// 10c: http module (synchronous via semaphore — Lua runs on bg queue)
// ═══════════════════════════════════════════════════════════════════════

// http.get(url [, headers_table]) → {status, body, headers} or nil, err
static int lua_http_get(lua_State *L) {
  const char *u = luaL_checkstring(L, 1);
  NSURL *url = [NSURL URLWithString:[NSString stringWithUTF8String:u]];
  if (!url) {
    lua_pushnil(L);
    lua_pushstring(L, "invalid URL");
    return 2;
  }
  NSMutableURLRequest *req = [NSMutableURLRequest
       requestWithURL:url
          cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
      timeoutInterval:30.0];
  // Optional headers table at arg 2
  if (lua_istable(L, 2)) {
    lua_pushnil(L);
    while (lua_next(L, 2)) {
      const char *k = lua_tostring(L, -2);
      const char *v = lua_tostring(L, -1);
      if (k && v)
        [req setValue:[NSString stringWithUTF8String:v]
            forHTTPHeaderField:[NSString stringWithUTF8String:k]];
      lua_pop(L, 1);
    }
  }

  __block NSData *resData = nil;
  __block NSHTTPURLResponse *resHttp = nil;
  __block NSError *resErr = nil;
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  [[[NSURLSession sharedSession]
      dataTaskWithRequest:req
        completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
          resData = d;
          resHttp = (NSHTTPURLResponse *)r;
          resErr = e;
          dispatch_semaphore_signal(sem);
        }] resume];
  dispatch_semaphore_wait(sem,
                          dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));

  if (resErr) {
    lua_pushnil(L);
    lua_pushstring(L, resErr.localizedDescription.UTF8String ?: "http error");
    return 2;
  }
  // Return table: {status, body, headers}
  lua_newtable(L);
  lua_pushinteger(L, resHttp.statusCode);
  lua_setfield(L, -2, "status");
  if (resData) {
    lua_pushlstring(L, (const char *)resData.bytes, resData.length);
  } else {
    lua_pushstring(L, "");
  }
  lua_setfield(L, -2, "body");
  // headers
  lua_newtable(L);
  [resHttp.allHeaderFields
      enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *s) {
        lua_pushstring(L, v.UTF8String);
        lua_setfield(L, -2, k.UTF8String);
      }];
  lua_setfield(L, -2, "headers");
  return 1;
}

// http.post(url, body [, content_type [, headers]]) → {status, body} or nil,
// err
static int lua_http_post(lua_State *L) {
  const char *u = luaL_checkstring(L, 1);
  size_t bodyLen;
  const char *bodyBytes = luaL_checklstring(L, 2, &bodyLen);
  const char *ct = luaL_optstring(L, 3, "application/x-www-form-urlencoded");

  NSURL *url = [NSURL URLWithString:[NSString stringWithUTF8String:u]];
  if (!url) {
    lua_pushnil(L);
    lua_pushstring(L, "invalid URL");
    return 2;
  }

  NSMutableURLRequest *req = [NSMutableURLRequest
       requestWithURL:url
          cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
      timeoutInterval:30.0];
  req.HTTPMethod = @"POST";
  req.HTTPBody = [NSData dataWithBytes:bodyBytes length:bodyLen];
  [req setValue:[NSString stringWithUTF8String:ct]
      forHTTPHeaderField:@"Content-Type"];

  // Optional extra headers at arg 4
  if (lua_istable(L, 4)) {
    lua_pushnil(L);
    while (lua_next(L, 4)) {
      const char *k = lua_tostring(L, -2);
      const char *v = lua_tostring(L, -1);
      if (k && v)
        [req setValue:[NSString stringWithUTF8String:v]
            forHTTPHeaderField:[NSString stringWithUTF8String:k]];
      lua_pop(L, 1);
    }
  }

  __block NSData *resData = nil;
  __block NSHTTPURLResponse *resHttp = nil;
  __block NSError *resErr = nil;
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  [[[NSURLSession sharedSession]
      dataTaskWithRequest:req
        completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
          resData = d;
          resHttp = (NSHTTPURLResponse *)r;
          resErr = e;
          dispatch_semaphore_signal(sem);
        }] resume];
  dispatch_semaphore_wait(sem,
                          dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));

  if (resErr) {
    lua_pushnil(L);
    lua_pushstring(L, resErr.localizedDescription.UTF8String ?: "http error");
    return 2;
  }
  lua_newtable(L);
  lua_pushinteger(L, resHttp.statusCode);
  lua_setfield(L, -2, "status");
  if (resData)
    lua_pushlstring(L, (const char *)resData.bytes, resData.length);
  else
    lua_pushstring(L, "");
  lua_setfield(L, -2, "body");
  return 1;
}

static const luaL_Reg kHttpLib[] = {
    {"get", lua_http_get}, {"post", lua_http_post}, {NULL, NULL}};

// ═══════════════════════════════════════════════════════════════════════
// 10b: sys.alert / sys.toast (extended sys table additions)
// These are added to existing sys table so we use different register fn
// ═══════════════════════════════════════════════════════════════════════

// sys.alert(msg [, title]) — modal alert via runtime
static int lua_sys_alert(lua_State *L) {
  const char *msg = luaL_checkstring(L, 1);
  const char *title = luaL_optstring(L, 2, "IOSControl");
  NSString *msgStr = [NSString stringWithUTF8String:msg];
  NSString *titleStr = [NSString stringWithUTF8String:title];
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  dispatch_async(dispatch_get_main_queue(), ^{
    // UIAlertController via runtime
    Class alertCls = NSClassFromString(@"UIAlertController");
    if (!alertCls) {
      dispatch_semaphore_signal(sem);
      return;
    }

    // +alertControllerWithTitle:message:preferredStyle:  (NSInteger style=0)
    id (*create)(Class, SEL, NSString *, NSString *, NSInteger) =
        (id(*)(Class, SEL, NSString *, NSString *, NSInteger))objc_msgSend;
    id alert = create(alertCls,
                      NSSelectorFromString(
                          @"alertControllerWithTitle:message:preferredStyle:"),
                      titleStr, msgStr, 0);

    // UIAlertAction +actionWithTitle:style:handler:
    Class actionCls = NSClassFromString(@"UIAlertAction");
    id (*mkAction)(Class, SEL, NSString *, NSInteger, void (^)(id)) =
        (id(*)(Class, SEL, NSString *, NSInteger, void (^)(id)))objc_msgSend;
    id okAction = mkAction(
        actionCls, NSSelectorFromString(@"actionWithTitle:style:handler:"),
        @"OK", 0, ^(id a) {
          dispatch_semaphore_signal(sem);
        });

    // [alert addAction:okAction]
    void (*addAct)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
    addAct(alert, NSSelectorFromString(@"addAction:"), okAction);

    // Present
    id app = [NSClassFromString(@"UIApplication")
        performSelector:NSSelectorFromString(@"sharedApplication")];
    id window = [app performSelector:NSSelectorFromString(@"keyWindow")];
    id vc =
        [window performSelector:NSSelectorFromString(@"rootViewController")];
    if (vc) {
      void (*present)(id, SEL, id, BOOL, id) =
          (void (*)(id, SEL, id, BOOL, id))objc_msgSend;
      present(
          vc,
          NSSelectorFromString(@"presentViewController:animated:completion:"),
          alert, YES, nil);
    } else {
      dispatch_semaphore_signal(sem);
    }
  });
  dispatch_semaphore_wait(sem,
                          dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC));
  return 0;
}

// sys.toast(msg) — daemon writes IPC file + posts Darwin notification
// The main UIApp receives it and posts the real UNUserNotification
static int lua_sys_toast(lua_State *L) {
  const char *msg = luaL_checkstring(L, 1);
  NSString *msgStr = [NSString stringWithUTF8String:msg];

  logMsg("🍞 [toast] %s", msg);

  // Write to temp file for IPC
  [msgStr writeToFile:@"/tmp/ioscontrol_toast_text.txt"
           atomically:YES
             encoding:NSUTF8StringEncoding
                error:nil];

  // Signal the main UIApp — it will post UNUserNotification from its process
  // (daemon cannot post notifications: "Notifications are not allowed for this
  // application")
  CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(),
      CFSTR("com.ioscontrol.showToast"), NULL, NULL, true);

  return 0;
}

// sys.getenv(key) → string or nil
static int lua_sys_getenv(lua_State *L) {
  const char *key = luaL_checkstring(L, 1);
  const char *val = getenv(key);
  if (val)
    lua_pushstring(L, val);
  else
    lua_pushnil(L);
  return 1;
}

// sys.time() → seconds since epoch (float)
static int lua_sys_time(lua_State *L) {
  lua_pushnumber(L, [[NSDate date] timeIntervalSince1970]);
  return 1;
}

// sys.date([format]) → formatted date string
static int lua_sys_date(lua_State *L) {
  const char *fmt = luaL_optstring(L, 1, "%Y-%m-%d %H:%M:%S");
  NSDateFormatter *df = [NSDateFormatter new];
  NSString *fmtStr = [NSString stringWithUTF8String:fmt];
  // Convert strftime-ish to NSDateFormatter tokens (basic)
  fmtStr = [fmtStr stringByReplacingOccurrencesOfString:@"%Y"
                                             withString:@"yyyy"];
  fmtStr = [fmtStr stringByReplacingOccurrencesOfString:@"%m" withString:@"MM"];
  fmtStr = [fmtStr stringByReplacingOccurrencesOfString:@"%d" withString:@"dd"];
  fmtStr = [fmtStr stringByReplacingOccurrencesOfString:@"%H" withString:@"HH"];
  fmtStr = [fmtStr stringByReplacingOccurrencesOfString:@"%M" withString:@"mm"];
  fmtStr = [fmtStr stringByReplacingOccurrencesOfString:@"%S" withString:@"ss"];
  df.dateFormat = fmtStr;
  lua_pushstring(L, [df stringFromDate:[NSDate date]].UTF8String);
  return 1;
}

// ═══════════════════════════════════════════════════════════════════════
// 10d: timer module (simple one-shot + repeating)
// ═══════════════════════════════════════════════════════════════════════

// ═══════════════════════════════════════════════════════════════════════
// 10e: sys.home / sys.lock + key module
// ═══════════════════════════════════════════════════════════════════════

// sys.home() — press Home button
static int lua_sys_home(lua_State *L) {
  ic_pressKey("HOMEBUTTON");
  return 0;
}

// sys.lock() — press Lock/Sleep button
static int lua_sys_lock(lua_State *L) {
  ic_pressKey("LOCK");
  return 0;
}

// key.input_text(str) — type a string character by character
static int lua_key_input_text(lua_State *L) {
  const char *s = luaL_checkstring(L, 1);
  NSString *str = [NSString stringWithUTF8String:s];
  // ic_keyInputText handles its own threading internally
  ic_keyInputText(str);
  return 0;
}

// key.press(name) — press and release a named key
// Names: HOMEBUTTON, LOCK, VOLUMEUP, VOLUMEDOWN, MUTE,
//        RETURN, BACKSPACE, SPACE, ESCAPE, SCREENSAVE, SPOTLIGHT
static int lua_key_press(lua_State *L) {
  const char *name = luaL_checkstring(L, 1);
  ic_pressKey(name);
  return 0;
}

// key.down(name) — hold key down
static int lua_key_down(lua_State *L) {
  const char *name = luaL_checkstring(L, 1);
  ic_holdKey(name);
  return 0;
}

// key.up(name) — release key
static int lua_key_up(lua_State *L) {
  const char *name = luaL_checkstring(L, 1);
  ic_releaseKey(name);
  return 0;
}

static const luaL_Reg kKeyLib[] = {{"press", lua_key_press},
                                   {"down", lua_key_down},
                                   {"up", lua_key_up},
                                   {"input_text", lua_key_input_text},
                                   {NULL, NULL}};

// timer.sleep(ms) — alias for sys.msleep compatible
static int lua_timer_sleep(lua_State *L) {
  double ms = luaL_checknumber(L, 1);
  usleep((useconds_t)(ms * 1000));
  return 0;
}

// timer.now() → milliseconds since boot
static int lua_timer_now(lua_State *L) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  double ms = ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
  lua_pushnumber(L, ms);
  return 1;
}

static const luaL_Reg kTimerLib[] = {
    {"sleep", lua_timer_sleep}, {"now", lua_timer_now}, {NULL, NULL}};

// ═══════════════════════════════════════════════════════════════════════
// Public: register all stdlib modules
// ═══════════════════════════════════════════════════════════════════════

void ic_luaStdlibRegister(lua_State *L) {
  // json table
  lua_newtable(L);
  luaL_setfuncs(L, kJsonLib, 0);
  lua_setglobal(L, "json");

  // base64 table
  lua_newtable(L);
  luaL_setfuncs(L, kBase64Lib, 0);
  lua_setglobal(L, "base64");

  // re table
  lua_newtable(L);
  luaL_setfuncs(L, kReLib, 0);
  lua_setglobal(L, "re");

  // http table
  lua_newtable(L);
  luaL_setfuncs(L, kHttpLib, 0);
  lua_setglobal(L, "http");

  // timer table
  lua_newtable(L);
  luaL_setfuncs(L, kTimerLib, 0);
  lua_setglobal(L, "timer");

  // Extend existing sys table with alert/toast/getenv/time/date/home/lock
  lua_getglobal(L, "sys");
  if (lua_istable(L, -1)) {
    lua_pushcfunction(L, lua_sys_alert);
    lua_setfield(L, -2, "alert");
    lua_pushcfunction(L, lua_sys_toast);
    lua_setfield(L, -2, "toast");
    lua_pushcfunction(L, lua_sys_getenv);
    lua_setfield(L, -2, "getenv");
    lua_pushcfunction(L, lua_sys_time);
    lua_setfield(L, -2, "time");
    lua_pushcfunction(L, lua_sys_date);
    lua_setfield(L, -2, "date");
    lua_pushcfunction(L, lua_sys_home);
    lua_setfield(L, -2, "home");
    lua_pushcfunction(L, lua_sys_lock);
    lua_setfield(L, -2, "lock");
  }
  lua_pop(L, 1);

  // key table: key.press / key.down / key.up
  lua_newtable(L);
  luaL_setfuncs(L, kKeyLib, 0);
  lua_setglobal(L, "key");
}
