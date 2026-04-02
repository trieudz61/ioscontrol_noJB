// ICHTTPServer.m — Lightweight HTTP server for IOSControl daemon
// POSIX sockets + CFSocket integration with CFRunLoop
// Zero external dependencies

#import "ICHTTPServer.h"
#import "ICAppControl.h"
#import "ICKeyInput.h"
#import "ICLuaEngine.h"
#import "ICScreenCapture.h"
#import "ICScriptManager.h"
#import <CommonCrypto/CommonDigest.h>
#import <arpa/inet.h>
#import <mach/mach.h>
#import <mach/mach_time.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <time.h>
#import <unistd.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>

// Forward declaration (defined in WS section below)
static uint64_t ms_now(void);

// ═══════════════════════════════════════════
// Forward declarations from IOSControlDaemon
// ═══════════════════════════════════════════

extern void logMsg(const char *fmt, ...);
extern void ic_tap(double x, double y);
extern void ic_swipe(double x1, double y1, double x2, double y2,
                     double duration);
extern void ic_longPress(double x, double y, double duration);
extern void ic_pressKey(const char *name);
extern void ic_touchDown(double x, double y, int finger);
extern void ic_touchMove(double x, double y, int finger);
extern void ic_touchUp(double x, double y, int finger);
extern double gScreenW;
extern double gScreenH;
extern uint64_t gSenderID;
extern dispatch_queue_t
    gScreenQueue; // serial: screen capture (UIKit/CG not thread-safe)
extern dispatch_queue_t gHIDQueue; // serial: HID touch dispatch

// ═══════════════════════════════════════════
// Lightweight JSON helpers
// ═══════════════════════════════════════════


static double jsonDouble(const char *json, const char *key, double defaultVal) {
  // Search for "key": or "key" :
  char pattern[64];
  snprintf(pattern, sizeof(pattern), "\"%s\"", key);
  const char *pos = strstr(json, pattern);
  if (!pos)
    return defaultVal;
  pos += strlen(pattern);
  // Skip whitespace and colon
  while (*pos && (*pos == ' ' || *pos == '\t' || *pos == ':'))
    pos++;
  if (!*pos)
    return defaultVal;
  return atof(pos);
}

static void jsonString(const char *json, const char *key, char *out,
                       size_t outLen) {
  out[0] = '\0';
  char pattern[64];
  // Include ':' so we match "key": not just "key" (avoids false match on
  // values)
  snprintf(pattern, sizeof(pattern), "\"%s\":", key);
  const char *pos = strstr(json, pattern);
  if (!pos)
    return;
  pos += strlen(pattern);
  while (*pos && (*pos == ' ' || *pos == '\t'))
    pos++; // skip whitespace after ':'
  if (*pos != '"')
    return;
  pos++; // skip opening quote
  size_t i = 0;
  while (*pos && *pos != '"' && i < outLen - 1) {
    out[i++] = *pos++;
  }
  out[i] = '\0';
}

// ═══════════════════════════════════════════
// HTTP response helpers
// ═══════════════════════════════════════════

static const char *kCORSHeaders =
    "Access-Control-Allow-Origin: *\r\n"
    "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
    "Access-Control-Allow-Headers: Content-Type\r\n";

static void sendResponse(int clientFd, int statusCode, const char *statusText,
                         const char *contentType, const char *body) {
  char header[512];
  int bodyLen = body ? (int)strlen(body) : 0;
  int headerLen =
      snprintf(header, sizeof(header),
               "HTTP/1.1 %d %s\r\n"
               "Content-Type: %s\r\n"
               "Content-Length: %d\r\n"
               "%s"
               "Connection: close\r\n"
               "\r\n",
               statusCode, statusText, contentType, bodyLen, kCORSHeaders);
  send(clientFd, header, headerLen, 0);
  if (body && bodyLen > 0) {
    send(clientFd, body, bodyLen, 0);
  }
}

static void sendJSON(int clientFd, int statusCode, const char *json) {
  const char *statusText = (statusCode == 200) ? "OK" : "Bad Request";
  sendResponse(clientFd, statusCode, statusText, "application/json", json);
}

static void sendOK(int clientFd, const char *message) {
  char json[256];
  snprintf(json, sizeof(json), "{\"ok\":true,\"message\":\"%s\"}", message);
  sendJSON(clientFd, 200, json);
}

static void sendError(int clientFd, int code, const char *message) {
  char json[256];
  snprintf(json, sizeof(json), "{\"ok\":false,\"error\":\"%s\"}", message);
  sendJSON(clientFd, code, json);
}

// ═══════════════════════════════════════════
// Binary response helper (for images)
// ═══════════════════════════════════════════

static void sendBinaryResponse(int clientFd, int statusCode,
                               const char *statusText, const char *contentType,
                               const void *data, size_t dataLen) {
  char header[512];
  int headerLen =
      snprintf(header, sizeof(header),
               "HTTP/1.1 %d %s\r\n"
               "Content-Type: %s\r\n"
               "Content-Length: %zu\r\n"
               "%s"
               "Connection: close\r\n"
               "\r\n",
               statusCode, statusText, contentType, dataLen, kCORSHeaders);
  send(clientFd, header, headerLen, 0);
  if (data && dataLen > 0) {
    // Send in chunks to handle large images
    const uint8_t *ptr = (const uint8_t *)data;
    size_t remaining = dataLen;
    while (remaining > 0) {
      size_t chunk = remaining > 65536 ? 65536 : remaining;
      ssize_t sent = send(clientFd, ptr, chunk, 0);
      if (sent <= 0)
        break;
      ptr += sent;
      remaining -= sent;
    }
  }
}

// ═══════════════════════════════════════════
// Query string parser (for GET params)
// ═══════════════════════════════════════════

static double queryDouble(const char *query, const char *key,
                          double defaultVal) {
  if (!query)
    return defaultVal;
  char search[64];
  snprintf(search, sizeof(search), "%s=", key);
  const char *pos = strstr(query, search);
  if (!pos)
    return defaultVal;
  pos += strlen(search);
  return atof(pos);
}

static int jsonInt(const char *json, const char *key) {
  return (int)jsonDouble(json, key, 0);
}

static void queryParam(const char *query, const char *key, char *out,
                       size_t outSize) {
  out[0] = '\0';
  if (!query) return;
  char search[64];
  snprintf(search, sizeof(search), "%s=", key);
  const char *pos = strstr(query, search);
  if (!pos) return;
  pos += strlen(search);
  size_t i = 0;
  while (pos[i] && pos[i] != '&' && i < outSize - 1) {
    out[i] = pos[i];
    i++;
  }
  out[i] = '\0';
}

// ═══════════════════════════════════════════
// Route handlers
// ═══════════════════════════════════════════

static void handleStatus(int clientFd) {
  char json[512];
  snprintf(json, sizeof(json),
           "{"
           "\"ok\":true,"
           "\"daemon\":\"IOSControlDaemon\","
           "\"version\":\"0.7.0\","
           "\"phase\":7,"
           "\"screenWidth\":%.0f,"
           "\"screenHeight\":%.0f,"
           "\"pid\":%d,"
           "\"senderID\":\"0x%llX\""
           "}",
           gScreenW, gScreenH, getpid(), gSenderID);
  sendJSON(clientFd, 200, json);
}

static void handleLog(int clientFd) {
  FILE *f = fopen("/var/tmp/ioscontrol-daemon.log", "r");
  if (!f) {
    sendError(clientFd, 500, "cannot read log");
    return;
  }
  // Read last 4KB
  fseek(f, 0, SEEK_END);
  long sz = ftell(f);
  long start = (sz > 4096) ? sz - 4096 : 0;
  fseek(f, start, SEEK_SET);
  char *buf = (char *)malloc(sz - start + 1);
  size_t n = fread(buf, 1, sz - start, f);
  buf[n] = '\0';
  fclose(f);
  sendResponse(clientFd, 200, "OK", "text/plain; charset=utf-8", buf);
  free(buf);
}

static void handleTap(int clientFd, const char *body) {
  double x = jsonDouble(body, "x", -1);
  double y = jsonDouble(body, "y", -1);
  if (x < 0 || y < 0) {
    sendError(clientFd, 400, "missing x or y");
    return;
  }
  ic_tap(x, y);
  logMsg("🌐 HTTP tap (%.0f, %.0f)", x, y);
  sendOK(clientFd, "tap dispatched");
}

static void handleSwipe(int clientFd, const char *body) {
  double x1 = jsonDouble(body, "x1", -1);
  double y1 = jsonDouble(body, "y1", -1);
  double x2 = jsonDouble(body, "x2", -1);
  double y2 = jsonDouble(body, "y2", -1);
  double duration = jsonDouble(body, "duration", 0.3);
  if (x1 < 0 || y1 < 0 || x2 < 0 || y2 < 0) {
    sendError(clientFd, 400, "missing x1/y1/x2/y2");
    return;
  }
  ic_swipe(x1, y1, x2, y2, duration);
  logMsg("🌐 HTTP swipe (%.0f,%.0f)→(%.0f,%.0f) %.2fs", x1, y1, x2, y2,
         duration);
  sendOK(clientFd, "swipe dispatched");
}

static void handleLongPress(int clientFd, const char *body) {
  double x = jsonDouble(body, "x", -1);
  double y = jsonDouble(body, "y", -1);
  double duration = jsonDouble(body, "duration", 1.0);
  if (x < 0 || y < 0) {
    sendError(clientFd, 400, "missing x or y");
    return;
  }
  ic_longPress(x, y, duration);
  logMsg("🌐 HTTP longpress (%.0f, %.0f) %.2fs", x, y, duration);
  sendOK(clientFd, "longpress dispatched");
}

static void handleTouch(int clientFd, const char *body) {
  char action[16];
  jsonString(body, "action", action, sizeof(action));
  double x = jsonDouble(body, "x", -1);
  double y = jsonDouble(body, "y", -1);
  int finger = (int)jsonDouble(body, "finger", 0);

  if (x < 0 || y < 0 || action[0] == '\0') {
    sendError(clientFd, 400, "missing action/x/y");
    return;
  }

  // Dispatch HID event on high-priority queue to avoid blocking the HTTP thread
  // This prevents request thread from hanging when HID system is busy
  BOOL isMoveAction = (strcmp(action, "move") == 0);

  if (strcmp(action, "down") == 0) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0),
                   ^{
                     ic_touchDown(x, y, finger);
                   });
  } else if (isMoveAction) {
    // move: fire-and-forget, don't block
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0),
                   ^{
                     ic_touchMove(x, y, finger);
                   });
  } else if (strcmp(action, "up") == 0) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0),
                   ^{
                     ic_touchUp(x, y, finger);
                   });
  } else {
    sendError(clientFd, 400, "invalid action (use down/move/up)");
    return;
  }

  // Only log down/up (not move — too spammy during drag)
  if (!isMoveAction) {
    logMsg("🌐 HTTP touch %s (%.0f, %.0f) finger=%d", action, x, y, finger);
  }
  sendOK(clientFd, "touch dispatched");
}

// ── Key press: POST /api/key body: {"key":"HOMEBUTTON"} ──
static void handleKey(int clientFd, const char *body) {
  char key[64];
  jsonString(body, "key", key, sizeof(key));
  if (key[0] == '\0') {
    sendError(clientFd, 400, "missing key name");
    return;
  }
  ic_pressKey(key);
  logMsg("🔑 HTTP key press: %s", key);
  sendOK(clientFd, "key dispatched");
}

// ── On-demand TTL screen cache ──
// Key invariant: only ONE thread ever calls dispatch_sync(gScreenQueue) at a
// time. All other concurrent /api/screen requests return stale cache instantly.
// This prevents thread pile-up and Jetsam.
static NSData *gCachedFrame = nil;
static uint64_t gCachedFrameTime = 0;
static float gCachedQuality = 0.40f;
static dispatch_semaphore_t gCaptureActiveSem = nil;
static dispatch_once_t gCaptureActiveOnce;
static const uint64_t CACHE_TTL_MS = 200; // max 5fps

void ic_startFrameCache(void) {
  dispatch_once(&gCaptureActiveOnce, ^{
    gCaptureActiveSem = dispatch_semaphore_create(1); // 1 = single slot
  });
  logMsg("📹 Frame cache ready (TTL=%llums, single-capture guard)",
         (unsigned long long)CACHE_TTL_MS);
}

static void handleScreen(int clientFd, const char *query) {
  // Ensure semaphore is initialised (in case startFrameCache not called yet)
  dispatch_once(&gCaptureActiveOnce, ^{
    gCaptureActiveSem = dispatch_semaphore_create(1);
  });

  double q = queryDouble(query, "quality", 40) / 100.0;
  if (q > 0.0 && q <= 1.0)
    gCachedQuality = (float)q;

  uint64_t now = ms_now();

  // ── Fast path: cache is fresh → return instantly, zero UIKit call ──
  if (gCachedFrame && (now - gCachedFrameTime) < CACHE_TTL_MS) {
    sendBinaryResponse(clientFd, 200, "OK", "image/jpeg", [gCachedFrame bytes],
                       [gCachedFrame length]);
    return;
  }

  // ── Slow path: cache stale → try to capture ──
  // DISPATCH_TIME_NOW: don't wait. If capture already in progress, serve stale.
  if (dispatch_semaphore_wait(gCaptureActiveSem, DISPATCH_TIME_NOW) != 0) {
    // Another thread is capturing right now — serve stale cache if available
    if (gCachedFrame) {
      sendBinaryResponse(clientFd, 200, "OK", "image/jpeg",
                         [gCachedFrame bytes], [gCachedFrame length]);
    } else {
      sendError(clientFd, 503, "warming up");
    }
    return;
  }

  // We own the semaphore — perform capture
  __block NSData *fresh = nil;
  dispatch_sync(gScreenQueue, ^{
    @autoreleasepool {
      fresh = ic_captureScreen(gCachedQuality);
    }
  });
  dispatch_semaphore_signal(gCaptureActiveSem);

  if (fresh && [fresh length] > 0) {
    gCachedFrame = fresh;
    gCachedFrameTime = ms_now();
    sendBinaryResponse(clientFd, 200, "OK", "image/jpeg", [fresh bytes],
                       [fresh length]);
  } else if (gCachedFrame) {
    sendBinaryResponse(clientFd, 200, "OK", "image/jpeg", [gCachedFrame bytes],
                       [gCachedFrame length]);
  } else {
    sendError(clientFd, 503, "screen capture unavailable");
  }
}

// gCaptureSem: ensures only 1 capture runs at a time
// If previous frame hasn't finished encoding, we skip (drop) the next frame
// instead of piling up work → prevents CPU runaway → prevents Jetsam
static dispatch_semaphore_t gCaptureSem = NULL;
static dispatch_once_t gCaptureSemOnce;

static void handleStream(int clientFd, const char *query) {
  dispatch_once(&gCaptureSemOnce, ^{
    gCaptureSem = dispatch_semaphore_create(1);
  });

  double quality = queryDouble(query, "quality", 60) / 100.0;
  if (quality <= 0.0 || quality > 1.0)
    quality = 0.60;

  // Hard cap: UIGetScreenImage ~50-80ms per call
  // 12fps = 83ms budget = safe for most devices (no CPU overload)
  // 15fps = 67ms budget = OK on fast devices (A15+)
  int fps = (int)queryDouble(query, "fps", 12);
  if (fps < 1)
    fps = 1;
  if (fps > 15)
    fps = 15;

  const char *hdr =
      "HTTP/1.1 200 OK\r\n"
      "Content-Type: multipart/x-mixed-replace; boundary=--ICFrame\r\n"
      "Cache-Control: no-cache, no-store\r\n"
      "Access-Control-Allow-Origin: *\r\n"
      "Connection: close\r\n\r\n";
  write(clientFd, hdr, strlen(hdr));

  uint64_t frameIntervalNs = (uint64_t)(1e9 / fps);
  mach_timebase_info_data_t tbInfo;
  mach_timebase_info(&tbInfo);

  for (int fc = 0; fc < fps * 300; fc++) {
    uint64_t t0 = mach_absolute_time();

    // Non-blocking: skip frame if a capture is already in-flight
    if (dispatch_semaphore_wait(gCaptureSem, DISPATCH_TIME_NOW) != 0) {
      usleep((useconds_t)(frameIntervalNs / 1000));
      continue;
    }

    __block NSData *jpeg = nil;
    dispatch_sync(gScreenQueue, ^{
      jpeg = ic_captureScreen((float)quality);
    });
    dispatch_semaphore_signal(gCaptureSem);

    if (jpeg && [jpeg length] > 0) {
      char ph[256];
      int plen = snprintf(ph, sizeof(ph),
                          "--ICFrame\r\nContent-Type: "
                          "image/jpeg\r\nContent-Length: %lu\r\n\r\n",
                          (unsigned long)[jpeg length]);
      if (write(clientFd, ph, plen) < 0)
        break;
      if (write(clientFd, [jpeg bytes], [jpeg length]) < 0)
        break;
      if (write(clientFd, "\r\n", 2) < 0)
        break;
    }

    // Sleep remaining budget so we never exceed target fps
    uint64_t elapsedNs =
        (mach_absolute_time() - t0) * tbInfo.numer / tbInfo.denom;
    if (elapsedNs < frameIntervalNs) {
      usleep((useconds_t)((frameIntervalNs - elapsedNs) / 1000));
    }
  }
}

static void handleScreenColor(int clientFd, const char *query) {
  if (!query) {
    sendError(clientFd, 400, "missing x and y params");
    return;
  }
  int x = (int)queryDouble(query, "x", -1);
  int y = (int)queryDouble(query, "y", -1);
  if (x < 0 || y < 0) {
    sendError(clientFd, 400, "missing or invalid x/y");
    return;
  }

  int r = 0, g = 0, b = 0;
  BOOL ok = ic_getColorAtPoint(x, y, &r, &g, &b);
  if (!ok) {
    sendError(clientFd, 500, "color sampling failed");
    return;
  }

  char json[256];
  snprintf(json, sizeof(json),
           "{\"r\":%d,\"g\":%d,\"b\":%d,\"hex\":\"#%02X%02X%02X\"}", r, g, b, r,
           g, b);
  sendJSON(clientFd, 200, json);
}

// ═══════════════════════════════════════════
// Script (Lua) route handlers (Phase 5)
// ═══════════════════════════════════════════

static void handleScriptRun(int clientFd, const char *body) {
  if (!body || strlen(body) == 0) {
    sendError(clientFd, 400, "missing body with code");
    return;
  }

  // Extract "code" field from JSON body
  // We support both {"code":"..."}  and raw script in body
  const char *codeStart = NULL;
  char *codeStr = NULL;

  // Try JSON extraction first
  const char *codeKey = strstr(body, "\"code\"");
  if (codeKey) {
    codeKey += 6; // skip "code"
    while (*codeKey && (*codeKey == ' ' || *codeKey == ':' || *codeKey == '\t'))
      codeKey++;
    if (*codeKey == '"') {
      codeKey++; // skip opening quote
      // Unescape simple JSON string (\n → newline, \\ → \, \" → ")
      size_t maxLen = strlen(codeKey) + 1;
      codeStr = (char *)malloc(maxLen);
      size_t i = 0;
      while (*codeKey && *codeKey != '"' && i < maxLen - 1) {
        if (*codeKey == '\\' && *(codeKey + 1)) {
          codeKey++;
          switch (*codeKey) {
          case 'n':
            codeStr[i++] = '\n';
            break;
          case 'r':
            codeStr[i++] = '\r';
            break;
          case 't':
            codeStr[i++] = '\t';
            break;
          case '"':
            codeStr[i++] = '"';
            break;
          case '\\':
            codeStr[i++] = '\\';
            break;
          default:
            codeStr[i++] = *codeKey;
            break;
          }
          codeKey++;
        } else {
          codeStr[i++] = *codeKey++;
        }
      }
      codeStr[i] = '\0';
      codeStart = codeStr;
    }
  }

  if (!codeStart || strlen(codeStart) == 0) {
    // Fall back: treat entire body as raw Lua (plain text)
    codeStart = body;
  }

  ic_luaExec(codeStart);
  if (codeStr)
    free(codeStr);

  sendOK(clientFd, "script started");
}

static void handleScriptStop(int clientFd) {
  ic_luaStop();
  sendOK(clientFd, "stop requested");
}

static void handleScriptStatus(int clientFd) {
  ICLuaStatus s = ic_luaGetStatus();
  const char *statusStr = (s == kLuaRunning) ? "running"
                          : (s == kLuaError) ? "error"
                                             : "idle";
  const char *lastErr = ic_luaGetLastError();
  char json[512];
  snprintf(json, sizeof(json), "{\"status\":\"%s\",\"error\":\"%s\"}",
           statusStr, lastErr ? lastErr : "");
  sendJSON(clientFd, 200, json);
}

// ═══════════════════════════════════════════
// Phase 7a: Script File Manager routes
// ═══════════════════════════════════════════

static void handleScriptList(int clientFd) {
  NSArray<NSString *> *scripts = ic_scriptList();
  NSMutableString *json =
      [NSMutableString stringWithString:@"{\"ok\":true,\"scripts\"["];
  // Build JSON array
  NSMutableString *arr = [NSMutableString string];
  for (int i = 0; i < (int)scripts.count; i++) {
    if (i > 0)
      [arr appendString:@","];
    NSString *name = scripts[i];
    // Escape any quotes in filename
    NSString *escaped = [name stringByReplacingOccurrencesOfString:@"\""
                                                        withString:@"\\\""];
    [arr appendFormat:@"\"%@\"", escaped];
  }
  char out[4096];
  snprintf(out, sizeof(out), "{\"ok\":true,\"scripts\":[%s]}", arr.UTF8String);
  sendJSON(clientFd, 200, out);
}

static void handleScriptRead(int clientFd, const char *query) {
  if (!query) {
    sendError(clientFd, 400, "missing name param");
    return;
  }
  // Extract ?name=
  const char *pos = strstr(query, "name=");
  if (!pos) {
    sendError(clientFd, 400, "missing name param");
    return;
  }
  pos += 5;
  char nameBuf[256] = {0};
  int i = 0;
  while (*pos && *pos != '&' && i < 255)
    nameBuf[i++] = *pos++;
  NSString *name = [NSString stringWithUTF8String:nameBuf];
  NSString *content = ic_scriptRead(name);
  if (!content) {
    sendError(clientFd, 404, "script not found");
    return;
  }
  // Return as JSON {ok, name, content}
  // Use chunked response for large scripts
  NSData *contentData = [content dataUsingEncoding:NSUTF8StringEncoding];
  sendResponse(clientFd, 200, "OK", "text/plain; charset=utf-8",
               content.UTF8String);
}

static void handleScriptWrite(int clientFd, const char *query,
                              const char *body) {
  if (!query) {
    sendError(clientFd, 400, "missing name param");
    return;
  }
  const char *pos = strstr(query, "name=");
  if (!pos) {
    sendError(clientFd, 400, "missing name param");
    return;
  }
  pos += 5;
  char nameBuf[256] = {0};
  int i = 0;
  while (*pos && *pos != '&' && i < 255)
    nameBuf[i++] = *pos++;
  NSString *name = [NSString stringWithUTF8String:nameBuf];
  NSString *content = [NSString stringWithUTF8String:body ?: ""];
  BOOL ok = ic_scriptWrite(name, content);
  if (ok) {
    sendOK(clientFd, "saved");
  } else {
    sendError(clientFd, 500, "save failed");
  }
}

static void handleScriptDeleteFile(int clientFd, const char *query) {
  if (!query) {
    sendError(clientFd, 400, "missing name param");
    return;
  }
  const char *pos = strstr(query, "name=");
  if (!pos) {
    sendError(clientFd, 400, "missing name param");
    return;
  }
  pos += 5;
  char nameBuf[256] = {0};
  int i = 0;
  while (*pos && *pos != '&' && i < 255)
    nameBuf[i++] = *pos++;
  NSString *name = [NSString stringWithUTF8String:nameBuf];
  BOOL ok = ic_scriptDelete(name);
  if (ok) {
    sendOK(clientFd, "deleted");
  } else {
    sendError(clientFd, 404, "not found");
  }
}

// ═══════════════════════════════════════════
// Phase 7b: App Control routes
// ═══════════════════════════════════════════

static void handleAppList(int clientFd) {
  NSArray<NSDictionary *> *apps = ic_appList();
  NSMutableString *arr = [NSMutableString string];
  for (int i = 0; i < (int)apps.count; i++) {
    if (i > 0)
      [arr appendString:@","];
    NSDictionary *app = apps[i];
    NSString *bid =
        [app[@"bundleID"] stringByReplacingOccurrencesOfString:@"\""
                                                    withString:@"\\\""];
    NSString *name =
        [app[@"name"] stringByReplacingOccurrencesOfString:@"\""
                                                withString:@"\\\""];
    NSString *ver =
        [app[@"version"] stringByReplacingOccurrencesOfString:@"\""
                                                   withString:@"\\\""];
    [arr appendFormat:
             @"{\"bundleID\":\"%@\",\"name\":\"%@\",\"version\":\"%@\"}", bid,
             name, ver];
  }
  char out[65536];
  snprintf(out, sizeof(out), "{\"ok\":true,\"count\":%d,\"apps\":[%s]}",
           (int)apps.count, arr.UTF8String);
  sendJSON(clientFd, 200, out);
}

static void handleAppLaunch(int clientFd, const char *body) {
  char bid[256] = {0};
  jsonString(body, "bundleID", bid, sizeof(bid));
  if (!bid[0]) {
    sendError(clientFd, 400, "missing bundleID");
    return;
  }
  NSString *bundleID = [NSString stringWithUTF8String:bid];
  BOOL ok = ic_appLaunch(bundleID);
  if (ok)
    sendOK(clientFd, "launched");
  else
    sendError(clientFd, 500, "launch failed");
}

static void handleAppKill(int clientFd, const char *body) {
  char bid[256] = {0};
  jsonString(body, "bundleID", bid, sizeof(bid));
  if (!bid[0]) {
    sendError(clientFd, 400, "missing bundleID");
    return;
  }
  NSString *bundleID = [NSString stringWithUTF8String:bid];
  BOOL ok = ic_appKill(bundleID);
  if (ok)
    sendOK(clientFd, "killed");
  else
    sendError(clientFd, 500, "kill failed");
}

static void handleAppFrontmost(int clientFd) {
  NSString *bid = ic_appFrontmost();
  char out[512];
  snprintf(out, sizeof(out), "{\"ok\":true,\"bundleID\":\"%s\"}",
           bid ? bid.UTF8String : "");
  sendJSON(clientFd, 200, out);
}

// ═══════════════════════════════════════════
// Phase 7c: HID Keyboard routes
// ═══════════════════════════════════════════

static void handleKeyPress(int clientFd, const char *body) {
  double page = jsonDouble(body, "page", 0x07);
  double usage = jsonDouble(body, "usage", 0);
  if (usage <= 0) {
    sendError(clientFd, 400, "missing usage");
    return;
  }
  BOOL ok = ic_keyPress((uint32_t)page, (uint32_t)usage);
  if (ok)
    sendOK(clientFd, "key pressed");
  else
    sendError(clientFd, 500, "key dispatch failed");
}

static void handleKeyInputText(int clientFd, const char *body) {
  char text[4096] = {0};
  jsonString(body, "text", text, sizeof(text));
  if (!text[0]) {
    sendError(clientFd, 400, "missing text");
    return;
  }
  NSString *str = [NSString stringWithUTF8String:text];
  BOOL ok = ic_keyInputText(str);
  if (ok)
    sendOK(clientFd, "text input dispatched");
  else
    sendError(clientFd, 500, "input failed");
}

// ═══════════════════════════════════════════
// Phase 7d: Clipboard routes
// ═══════════════════════════════════════════

static void handleClipboardRead(int clientFd) {
  // Use UIPasteboard via ObjC runtime
  Class pb = NSClassFromString(@"UIPasteboard");
  NSString *text = nil;
  if (pb) {
    id general =
        [pb performSelector:NSSelectorFromString(@"generalPasteboard")];
    if (general) {
      text = [general performSelector:NSSelectorFromString(@"string")];
    }
  }
  char out[4096];
  NSString *escaped =
      [text ?: @"" stringByReplacingOccurrencesOfString:@"\""
                                             withString:@"\\\""];
  snprintf(out, sizeof(out), "{\"ok\":true,\"text\":\"%s\"}",
           escaped.UTF8String ?: "");
  sendJSON(clientFd, 200, out);
}

static void handleClipboardWrite(int clientFd, const char *body) {
  char text[4096] = {0};
  jsonString(body, "text", text, sizeof(text));
  NSString *str = [NSString stringWithUTF8String:text];
  Class pb = NSClassFromString(@"UIPasteboard");
  if (pb) {
    id general =
        [pb performSelector:NSSelectorFromString(@"generalPasteboard")];
    if (general) {
      [general performSelector:NSSelectorFromString(@"setString:")
                    withObject:str];
      logMsg("📋 Clipboard written: %zu chars", str.length);
      sendOK(clientFd, "clipboard written");
      return;
    }
  }
  sendError(clientFd, 500, "clipboard not available");
}

// ═══════════════════════════════════════════
// Phase 7e: Device Info + System Log routes
// ═══════════════════════════════════════════

static void handleDeviceInfo(int clientFd) {
  // Hardware identifier via uname (e.g. "iPhone16,2")
  struct utsname uts;
  uname(&uts);
  NSString *hwID = [NSString stringWithUTF8String:uts.machine];

  // Marketing name lookup table (top 50 models)
  NSDictionary *modelMap = @{
    // iPhone 16 series
    @"iPhone17,1" : @"iPhone 16 Pro",
    @"iPhone17,2" : @"iPhone 16 Pro Max",
    @"iPhone17,3" : @"iPhone 16",
    @"iPhone17,4" : @"iPhone 16 Plus",
    // iPhone 15 series
    @"iPhone16,1" : @"iPhone 15 Pro",
    @"iPhone16,2" : @"iPhone 15 Pro Max",
    @"iPhone15,4" : @"iPhone 15",
    @"iPhone15,5" : @"iPhone 15 Plus",
    // iPhone 14 series
    @"iPhone15,2" : @"iPhone 14 Pro",
    @"iPhone15,3" : @"iPhone 14 Pro Max",
    @"iPhone14,7" : @"iPhone 14",
    @"iPhone14,8" : @"iPhone 14 Plus",
    // iPhone 13 series
    @"iPhone14,2" : @"iPhone 13 Pro",
    @"iPhone14,3" : @"iPhone 13 Pro Max",
    @"iPhone14,4" : @"iPhone 13 mini",
    @"iPhone14,5" : @"iPhone 13",
    // iPhone 12 series
    @"iPhone13,1" : @"iPhone 12 mini",
    @"iPhone13,2" : @"iPhone 12",
    @"iPhone13,3" : @"iPhone 12 Pro",
    @"iPhone13,4" : @"iPhone 12 Pro Max",
    // iPhone 11 series
    @"iPhone12,1" : @"iPhone 11",
    @"iPhone12,3" : @"iPhone 11 Pro",
    @"iPhone12,5" : @"iPhone 11 Pro Max",
    // iPhone X/XS/XR
    @"iPhone10,3" : @"iPhone X",
    @"iPhone10,6" : @"iPhone X",
    @"iPhone11,2" : @"iPhone XS",
    @"iPhone11,4" : @"iPhone XS Max",
    @"iPhone11,6" : @"iPhone XS Max",
    @"iPhone11,8" : @"iPhone XR",
    // iPhone SE
    @"iPhone14,6" : @"iPhone SE (3rd)",
    @"iPhone12,8" : @"iPhone SE (2nd)",
    @"iPhone8,4" : @"iPhone SE (1st)",
    // Simulator
    @"x86_64" : @"Simulator (x86_64)",
    @"arm64" : @"Simulator (arm64)",
  };
  NSString *marketingName = modelMap[hwID] ?: hwID;

  // iOS version via UIDevice runtime
  NSString *sysVersion = @"";
  NSString *sysName = @"iOS";
  Class UIDeviceCls = NSClassFromString(@"UIDevice");
  if (UIDeviceCls) {
    id dev =
        [UIDeviceCls performSelector:NSSelectorFromString(@"currentDevice")];
    if (dev) {
      NSString *sv =
          [dev performSelector:NSSelectorFromString(@"systemVersion")];
      NSString *sn = [dev performSelector:NSSelectorFromString(@"systemName")];
      if (sv)
        sysVersion = sv;
      if (sn)
        sysName = sn;
    }
  }

  // Memory info
  uint64_t totalMemory = [NSProcessInfo processInfo].physicalMemory;
  uint64_t usedMemory = 0;
  struct task_basic_info info;
  mach_msg_type_number_t infoCount = TASK_BASIC_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_BASIC_INFO, (task_info_t)&info,
                &infoCount) == KERN_SUCCESS) {
    usedMemory = info.resident_size;
  }

  char out[1024];
  snprintf(out, sizeof(out),
           "{\"ok\":true,"
           "\"model\":\"%s\","
           "\"hwID\":\"%s\","
           "\"systemName\":\"%s\","
           "\"systemVersion\":\"%s\","
           "\"screenWidth\":%.0f,"
           "\"screenHeight\":%.0f,"
           "\"totalMemoryMB\":%llu,"
           "\"usedMemoryMB\":%llu,"
           "\"pid\":%d"
           "}",
           marketingName.UTF8String, hwID.UTF8String, sysName.UTF8String,
           sysVersion.UTF8String, gScreenW, gScreenH,
           totalMemory / (1024 * 1024), usedMemory / (1024 * 1024), getpid());
  sendJSON(clientFd, 200, out);
}

static void handleSystemLog(int clientFd, const char *method) {
  if (strcmp(method, "DELETE") == 0) {
    // Clear the log file
    FILE *f = fopen("/var/tmp/ioscontrol-daemon.log", "w");
    if (f) {
      fclose(f);
    }
    sendOK(clientFd, "log cleared");
    return;
  }
  // GET — return last 8KB
  FILE *f = fopen("/var/tmp/ioscontrol-daemon.log", "r");
  if (!f) {
    sendError(clientFd, 500, "cannot read log");
    return;
  }
  fseek(f, 0, SEEK_END);
  long sz = ftell(f);
  long start = (sz > 8192) ? sz - 8192 : 0;
  fseek(f, start, SEEK_SET);
  char *buf = (char *)malloc(sz - start + 1);
  size_t n = fread(buf, 1, sz - start, f);
  buf[n] = '\0';
  fclose(f);
  sendResponse(clientFd, 200, "OK", "text/plain; charset=utf-8", buf);
  free(buf);
}

// ═══════════════════════════════════════════
// Static file server (Phase 4 — Web IDE)
// ═══════════════════════════════════════════

static const char *mimeTypeForPath(const char *path) {
  const char *dot = strrchr(path, '.');
  if (!dot)
    return "application/octet-stream";
  if (strcasecmp(dot, ".html") == 0)
    return "text/html; charset=utf-8";
  if (strcasecmp(dot, ".css") == 0)
    return "text/css; charset=utf-8";
  if (strcasecmp(dot, ".js") == 0)
    return "application/javascript; charset=utf-8";
  if (strcasecmp(dot, ".json") == 0)
    return "application/json";
  if (strcasecmp(dot, ".png") == 0)
    return "image/png";
  if (strcasecmp(dot, ".jpg") == 0 || strcasecmp(dot, ".jpeg") == 0)
    return "image/jpeg";
  if (strcasecmp(dot, ".svg") == 0)
    return "image/svg+xml";
  if (strcasecmp(dot, ".ico") == 0)
    return "image/x-icon";
  if (strcasecmp(dot, ".woff2") == 0)
    return "font/woff2";
  return "application/octet-stream";
}

static void handleStaticFile(int clientFd, const char *urlPath) {
  // Security: block directory traversal
  if (strstr(urlPath, "..") != NULL) {
    sendError(clientFd, 403, "forbidden");
    return;
  }

  // Strip leading /static/ prefix to get relative path
  const char *relPath = urlPath;
  if (strncmp(relPath, "/static/", 8) == 0) {
    relPath = urlPath + 8; // skip "/static/"
  } else if (strcmp(relPath, "/") == 0) {
    relPath = "index.html";
  } else if (relPath[0] == '/') {
    relPath = urlPath + 1;
  }

  // Find static/ dir inside app bundle
  NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
  NSString *filePath =
      [NSString stringWithFormat:@"%@/static/%s", bundlePath, relPath];

  NSData *fileData = [NSData dataWithContentsOfFile:filePath];
  if (!fileData) {
    sendError(clientFd, 404, "not found");
    return;
  }

  const char *mime = mimeTypeForPath(relPath);
  sendBinaryResponse(clientFd, 200, "OK", mime, [fileData bytes],
                     [fileData length]);
}

// ═══════════════════════════════════════════
// WebSocket Control Channel — /ws/control
// ═══════════════════════════════════════════
// Architecture (mirrors XXTouch screen.js):
//   Screen stream:  HTTP GET /api/stream  → MJPEG (blocking, gScreenQueue)
//   Touch control:  WS  GET /ws/control  → persistent (gHIDQueue, non-blocking)
// Touch events arrive as non-blocking WS frames — no HTTP request overhead,
// no response buffering, no timeout issues that caused daemon crashes.

#import <CommonCrypto/CommonDigest.h>

// ── Base64 encode (for WS handshake) ──
static const char kB64C[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
static void b64_encode(const uint8_t *in, size_t len, char *out) {
  size_t i = 0, j = 0;
  for (; i + 2 < len; i += 3) {
    out[j++] = kB64C[in[i] >> 2];
    out[j++] = kB64C[((in[i] & 3) << 4) | (in[i + 1] >> 4)];
    out[j++] = kB64C[((in[i + 1] & 0xF) << 2) | (in[i + 2] >> 6)];
    out[j++] = kB64C[in[i + 2] & 0x3F];
  }
  if (i < len) {
    out[j++] = kB64C[in[i] >> 2];
    if (i + 1 < len) {
      out[j++] = kB64C[((in[i] & 3) << 4) | (in[i + 1] >> 4)];
      out[j++] = kB64C[(in[i + 1] & 0xF) << 2];
    } else {
      out[j++] = kB64C[(in[i] & 3) << 4];
      out[j++] = '=';
    }
    out[j++] = '=';
  }
  out[j] = '\0';
}

// ── RFC 6455 WebSocket handshake ──
static BOOL wsHandshake(int fd, const char *reqBuf) {
  // Extract Sec-WebSocket-Key header value
  const char *keyHdr = strcasestr(reqBuf, "Sec-WebSocket-Key:");
  if (!keyHdr)
    return NO;
  keyHdr += 18; // skip header name
  while (*keyHdr == ' ')
    keyHdr++;
  char key[128] = {0};
  size_t ki = 0;
  while (*keyHdr && *keyHdr != '\r' && *keyHdr != '\n' && ki < 127)
    key[ki++] = *keyHdr++;
  key[ki] = '\0';

  // Compute accept key: SHA1(key + GUID) → base64
  const char *guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
  char combined[256];
  snprintf(combined, sizeof(combined), "%s%s", key, guid);
  uint8_t sha1[CC_SHA1_DIGEST_LENGTH];
  CC_SHA1(combined, (CC_LONG)strlen(combined), sha1);
  char accept[64] = {0};
  b64_encode(sha1, CC_SHA1_DIGEST_LENGTH, accept);

  // Send 101 Switching Protocols
  char resp[512];
  int rlen = snprintf(resp, sizeof(resp),
                      "HTTP/1.1 101 Switching Protocols\r\n"
                      "Upgrade: websocket\r\n"
                      "Connection: Upgrade\r\n"
                      "Sec-WebSocket-Accept: %s\r\n"
                      "Access-Control-Allow-Origin: *\r\n"
                      "\r\n",
                      accept);
  return (write(fd, resp, rlen) == rlen);
}

// ── Send WebSocket text frame (server→client, no masking) ──
static void wsSendText(int fd, const char *json) {
  size_t plen = strlen(json);
  uint8_t hdr[10];
  int hlen;
  hdr[0] = 0x81; // FIN + text opcode
  if (plen <= 125) {
    hdr[1] = (uint8_t)plen;
    hlen = 2;
  } else if (plen <= 65535) {
    hdr[1] = 126;
    hdr[2] = (plen >> 8) & 0xFF;
    hdr[3] = plen & 0xFF;
    hlen = 4;
  } else {
    return; // won't happen for our small messages
  }
  write(fd, hdr, hlen);
  write(fd, json, plen);
}

// ── Receive one WebSocket frame → returns payload in out_buf (caller frees) ──
// Returns payload length, -1 on error/close
static ssize_t wsRecvFrame(int fd, char **out_buf) {
  uint8_t hdr[2];
  if (recv(fd, hdr, 2, MSG_WAITALL) != 2)
    return -1;

  BOOL fin = (hdr[0] & 0x80) != 0;
  int op = hdr[0] & 0x0F; // 1=text, 8=close, 9=ping, 0xA=pong
  BOOL mask = (hdr[1] & 0x80) != 0;
  size_t plen = hdr[1] & 0x7F;

  (void)fin;

  if (op == 8)
    return -1; // close frame

  if (plen == 126) {
    uint8_t ext[2];
    if (recv(fd, ext, 2, MSG_WAITALL) != 2)
      return -1;
    plen = ((size_t)ext[0] << 8) | ext[1];
  } else if (plen == 127) {
    uint8_t ext[8];
    if (recv(fd, ext, 8, MSG_WAITALL) != 8)
      return -1;
    plen = 0;
    for (int i = 0; i < 8; i++)
      plen = (plen << 8) | ext[i];
  }

  uint8_t mkey[4] = {0};
  if (mask) {
    if (recv(fd, mkey, 4, MSG_WAITALL) != 4)
      return -1;
  }

  if (plen == 0) {
    *out_buf = NULL;
    return 0;
  }
  if (plen > 65536)
    return -1; // sanity limit

  char *buf = malloc(plen + 1);
  if (!buf)
    return -1;
  if ((size_t)recv(fd, buf, plen, MSG_WAITALL) != plen) {
    free(buf);
    return -1;
  }

  // Unmask payload (browser always masks client→server frames)
  if (mask) {
    for (size_t i = 0; i < plen; i++)
      buf[i] ^= mkey[i % 4];
  }
  buf[plen] = '\0';
  *out_buf = buf;
  return (ssize_t)plen;
}

// ── Send WebSocket binary frame (server→client, for JPEG frames) ──
static void wsSendBinary(int fd, const void *data, size_t plen) {
  uint8_t hdr[10];
  int hlen;
  hdr[0] = 0x82; // FIN + binary opcode
  if (plen <= 125) {
    hdr[1] = (uint8_t)plen;
    hlen = 2;
  } else if (plen <= 65535) {
    hdr[1] = 126;
    hdr[2] = (plen >> 8) & 0xFF;
    hdr[3] = plen & 0xFF;
    hlen = 4;
  } else {
    hdr[1] = 127;
    for (int i = 9; i >= 2; i--) {
      hdr[i] = plen & 0xFF;
      plen >>= 8;
    }
    hlen = 10;
    plen = ((size_t *)data)[-1]; // restore (hack-free: recalculate below)
  }
  // Simple path — JPEG is always < 400KB so use <= 65535 path above
  write(fd, hdr, hlen);
  write(fd, data, plen);
}

static uint64_t ms_now(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static void wsSendFrame(int fd, NSData *frame) {
  if (!frame || [frame length] == 0)
    return;
  size_t plen = [frame length];
  uint8_t hdr[10];
  hdr[0] = 0x82; // FIN + binary
  int hlen;
  if (plen <= 125) {
    hdr[1] = (uint8_t)plen;
    hlen = 2;
  } else if (plen <= 65535) {
    hdr[1] = 126;
    hdr[2] = (plen >> 8) & 0xFF;
    hdr[3] = plen & 0xFF;
    hlen = 4;
  } else {
    hdr[1] = 127;
    hdr[2] = 0;
    hdr[3] = 0;
    hdr[4] = 0;
    hdr[5] = 0;
    hdr[6] = (plen >> 24) & 0xFF;
    hdr[7] = (plen >> 16) & 0xFF;
    hdr[8] = (plen >> 8) & 0xFF;
    hdr[9] = plen & 0xFF;
    hlen = 10;
  }
  if (write(fd, hdr, hlen) < 0)
    return;
  write(fd, [frame bytes], plen);
}

// ── WebSocket touch/key/heartbeat control loop (/ws/control) ──
// XXTouch architecture: WS handles ONLY touch/key/heart (fast, never blocks).
// Screen = separate HTTP GET /api/screen (browser polls, served from cache).
// Two independent channels, zero contention.
static void handleWebSocketControl(int fd) {
  logMsg("🔌 WS /ws/control connected fd=%d", fd);
  wsSendText(fd, "{\"mode\":\"connected\"}");

  char jsonKey[64];
  const uint64_t HEART_INTERVAL_MS = 1000; // daemon→browser 1s
  const uint64_t HEART_TIMEOUT_MS = 5000;  // disconnect if silent > 5s
  uint64_t lastHeartSent = ms_now();
  uint64_t lastHeartRecv = ms_now();

  while (1) {
    // Wait up to 1s for touch data (heartbeat drives the timeout)
    uint64_t now = ms_now();
    uint64_t sinceHeart = now - lastHeartSent;
    uint64_t waitMs =
        (sinceHeart < HEART_INTERVAL_MS) ? HEART_INTERVAL_MS - sinceHeart : 0;

    fd_set rfds;
    FD_ZERO(&rfds);
    FD_SET(fd, &rfds);
    // POSIX: tv_usec must be 0-999999. Normalize properly.
    struct timeval tv = {(int)(waitMs / 1000), (int)((waitMs % 1000) * 1000)};
    int sel = select(fd + 1, &rfds, NULL, NULL, &tv);
    if (sel < 0)
      break;

    // ── Process incoming touch/control frame ──
    if (sel > 0) {
      char *payload = NULL;
      ssize_t n = wsRecvFrame(fd, &payload);
      if (n < 0) {
        logMsg("🔌 WS disconnected fd=%d", fd);
        ic_touchUp(0, 0, 0);
        break;
      }
      lastHeartRecv = ms_now();
      if (payload && n > 0) {
        jsonString(payload, "mode", jsonKey, sizeof(jsonKey));
        if (!strcmp(jsonKey, "down") || !strcmp(jsonKey, "move") ||
            !strcmp(jsonKey, "up")) {
          double x = jsonDouble(payload, "x", -1);
          double y = jsonDouble(payload, "y", -1);
          if (x >= 0 && y >= 0) {
            if (!strcmp(jsonKey, "down"))
              ic_touchDown(x, y, 0);
            else if (!strcmp(jsonKey, "move"))
              ic_touchMove(x, y, 0);
            else
              ic_touchUp(x, y, 0);
          }
        } else if (!strcmp(jsonKey, "key")) {
          char keyName[64];
          jsonString(payload, "key", keyName, sizeof(keyName));
          ic_pressKey(keyName);
        } else if (!strcmp(jsonKey, "text")) {
          // Browser keyboard forwarding: single printable char
          char textVal[32];
          jsonString(payload, "text", textVal, sizeof(textVal));
          if (textVal[0]) {
            NSString *s = [NSString stringWithUTF8String:textVal];
            ic_keyInputText(s);
          }

        } else if (!strcmp(jsonKey, "heart")) {
          // reset done via lastHeartRecv above
        } else if (!strcmp(jsonKey, "quit")) {
          ic_touchUp(0, 0, 0);
          free(payload);
          break;
        }
        free(payload);
      }
    }

    now = ms_now();
    // ── Heartbeat timeout ──
    if (now - lastHeartRecv > HEART_TIMEOUT_MS) {
      logMsg("🔌 WS timeout fd=%d — browser gone", fd);
      ic_touchUp(0, 0, 0);
      break;
    }
    // ── Send heart to browser ──
    if (now - lastHeartSent >= HEART_INTERVAL_MS) {
      lastHeartSent = now;
      wsSendText(fd, "{\"mode\":\"heart\"}");
    }
  }
}

// ── Helper: extract Sec-WebSocket-Key and check upgrade request ──
static BOOL isWebSocketUpgrade(const char *buf) {
  return (strcasestr(buf, "Upgrade: websocket") != NULL ||
          strcasestr(buf, "Upgrade:websocket") != NULL);
}

// ═══════════════════════════════════════════
// HTTP request parser + router
// ═══════════════════════════════════════════

// ═══════════════════════════════════════════
// Template Management — crop, list, delete
// ═══════════════════════════════════════════

static NSString *templateDir(void) {
  NSString *dir = @"/var/mobile/Documents/templates";
  NSFileManager *fm = [NSFileManager defaultManager];
  if (![fm fileExistsAtPath:dir]) {
    [fm createDirectoryAtPath:dir
        withIntermediateDirectories:YES
                         attributes:nil
                              error:nil];
  }
  return dir;
}

// POST /api/screen/crop  body: {"x":100,"y":200,"w":50,"h":50,"name":"btn"}
static void handleScreenCrop(int clientFd, const char *body) {
  int x = jsonInt(body, "x");
  int y = jsonInt(body, "y");
  int w = jsonInt(body, "w");
  int h = jsonInt(body, "h");
  char nameBuf[128];
  jsonString(body, "name", nameBuf, sizeof(nameBuf));

  if (w <= 0 || h <= 0 || nameBuf[0] == '\0') {
    sendError(clientFd, 400, "need x, y, w, h, name");
    return;
  }

  // Sanitize name
  NSString *name = [[NSString stringWithUTF8String:nameBuf]
      stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
  NSString *filename =
      [NSString stringWithFormat:@"%@.png", name];
  NSString *savePath =
      [templateDir() stringByAppendingPathComponent:filename];

  // Capture screen at full quality
  __block NSData *jpeg = nil;
  dispatch_sync(gScreenQueue, ^{
    @autoreleasepool { jpeg = ic_captureScreen(1.0f); }
  });

  if (!jpeg || jpeg.length == 0) {
    sendError(clientFd, 500, "screen capture failed");
    return;
  }

  // Decode JPEG → CGImage
  CGDataProviderRef prov =
      CGDataProviderCreateWithCFData((__bridge CFDataRef)jpeg);
  CGImageRef fullImg =
      CGImageCreateWithJPEGDataProvider(prov, NULL, true,
                                        kCGRenderingIntentDefault);
  CGDataProviderRelease(prov);
  if (!fullImg) {
    sendError(clientFd, 500, "JPEG decode failed");
    return;
  }

  size_t imgW = CGImageGetWidth(fullImg);
  size_t imgH = CGImageGetHeight(fullImg);

  // Clamp region
  if (x < 0) x = 0;
  if (y < 0) y = 0;
  if (x + w > (int)imgW) w = (int)imgW - x;
  if (y + h > (int)imgH) h = (int)imgH - y;

  if (w <= 0 || h <= 0) {
    CGImageRelease(fullImg);
    sendError(clientFd, 400, "region out of bounds");
    return;
  }

  // Crop
  CGRect cropRect = CGRectMake(x, y, w, h);
  CGImageRef cropped = CGImageCreateWithImageInRect(fullImg, cropRect);
  CGImageRelease(fullImg);
  if (!cropped) {
    sendError(clientFd, 500, "crop failed");
    return;
  }

  // Encode to PNG
  NSMutableData *pngData = [NSMutableData data];
  CGImageDestinationRef dest = CGImageDestinationCreateWithData(
      (__bridge CFMutableDataRef)pngData,
      (__bridge CFStringRef)@"public.png", 1, NULL);
  if (!dest) {
    CGImageRelease(cropped);
    sendError(clientFd, 500, "PNG encoder init failed");
    return;
  }
  CGImageDestinationAddImage(dest, cropped, NULL);
  CGImageDestinationFinalize(dest);
  CFRelease(dest);
  CGImageRelease(cropped);

  // Save
  BOOL ok = [pngData writeToFile:savePath atomically:YES];
  if (!ok) {
    sendError(clientFd, 500, "file write failed");
    return;
  }

  logMsg("✅ [Template] Saved %s (%dx%d, %zu bytes)", savePath.UTF8String, w,
         h, pngData.length);

  char resp[512];
  snprintf(resp, sizeof(resp),
           "{\"ok\":true,\"path\":\"%s\",\"size\":%zu,\"w\":%d,\"h\":%d}",
           savePath.UTF8String, pngData.length, w, h);
  sendResponse(clientFd, 200, "OK", "application/json", resp);
}

// GET /api/templates → list saved templates
static void handleTemplateList(int clientFd) {
  NSString *dir = templateDir();
  NSArray *files = [[NSFileManager defaultManager]
      contentsOfDirectoryAtPath:dir error:nil];
  NSMutableArray *items = [NSMutableArray array];
  for (NSString *f in files) {
    if (![f hasSuffix:@".png"]) continue;
    NSString *fullPath = [dir stringByAppendingPathComponent:f];
    NSDictionary *attrs = [[NSFileManager defaultManager]
        attributesOfItemAtPath:fullPath error:nil];
    NSString *name = [f stringByDeletingPathExtension];
    [items addObject:@{
      @"name": name,
      @"path": fullPath,
      @"size": @([attrs fileSize]),
    }];
  }
  NSData *json = [NSJSONSerialization dataWithJSONObject:items options:0 error:nil];
  NSString *str = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
  sendResponse(clientFd, 200, "OK", "application/json", str.UTF8String);
}

// DELETE /api/templates?name=xxx → delete a template
static void handleTemplateDelete(int clientFd, const char *query) {
  char nameBuf[128];
  queryParam(query, "name", nameBuf, sizeof(nameBuf));
  if (nameBuf[0] == '\0') {
    sendError(clientFd, 400, "missing name");
    return;
  }
  NSString *name = [NSString stringWithUTF8String:nameBuf];
  NSString *path = [templateDir()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"%@.png", name]];
  NSFileManager *fm = [NSFileManager defaultManager];
  if ([fm fileExistsAtPath:path]) {
    [fm removeItemAtPath:path error:nil];
    logMsg("🗑️ [Template] Deleted: %s", path.UTF8String);
    sendOK(clientFd, "deleted");
  } else {
    sendError(clientFd, 404, "template not found");
  }
}

static void handleClient(int clientFd) {
  // ── Phase 1: read initial chunk (headers + possibly partial body) ──
  char buf[4096];
  ssize_t n = recv(clientFd, buf, sizeof(buf) - 1, 0);
  if (n <= 0) {
    close(clientFd);
    return;
  }
  buf[n] = '\0';

  // Parse method and path (with query string)
  char method[8] = {0};
  char fullPath[256] = {0};
  sscanf(buf, "%7s %255s", method, fullPath);

  // Split path and query string
  char path[128] = {0};
  char *query = NULL;
  strncpy(path, fullPath, sizeof(path) - 1);
  char *qmark = strchr(path, '?');
  if (qmark) {
    *qmark = '\0';
    query = qmark + 1;
  }

  // ── Phase 2: ensure we have the full HTTP body ──
  // Find Content-Length header
  int contentLength = 0;
  const char *clHdr = strcasestr(buf, "Content-Length:");
  if (clHdr) {
    clHdr += 15;
    while (*clHdr == ' ')
      clHdr++;
    contentLength = atoi(clHdr);
  }

  // Find header/body boundary
  char *bodyStart = strstr(buf, "\r\n\r\n");
  char *fullBody = NULL; // dynamically allocated if we need extra reads

  if (bodyStart) {
    bodyStart += 4;
    int bodyAlready = (int)(n - (bodyStart - buf)); // bytes of body in buf

    if (contentLength > 0 && bodyAlready < contentLength) {
      // Need to read more body bytes
      int need = contentLength - bodyAlready;
      // Cap at 64KB to prevent abuse
      if (need > 65536)
        need = 65536;
      fullBody = (char *)malloc(contentLength + 1);
      if (fullBody) {
        memcpy(fullBody, bodyStart, bodyAlready);
        int got = bodyAlready;
        while (got < contentLength) {
          ssize_t r = recv(clientFd, fullBody + got, contentLength - got, 0);
          if (r <= 0)
            break;
          got += r;
        }
        fullBody[got] = '\0';
      }
    }
  }

  const char *body;
  if (fullBody) {
    body = fullBody;
  } else if (bodyStart) {
    body = bodyStart;
  } else {
    body = "";
  }

  // Skip logging for high-frequency polling routes (Web IDE auto-polls these)
  if (strcmp(path, "/api/screen") != 0 &&
      strcmp(path, "/api/status") != 0 &&
      strcmp(path, "/api/stream") != 0 &&
      strcmp(path, "/api/screen/color") != 0 &&
      strcmp(path, "/api/log") != 0 &&
      strcmp(path, "/api/script/status") != 0 &&
      strcmp(path, "/api/system/log") != 0 &&
      strcmp(method, "OPTIONS") != 0) {
    logMsg("🌐 %s %s (body=%zu bytes)", method, path, strlen(body));
  }

  // ── WebSocket upgrade ──
  if (strcmp(path, "/ws/control") == 0 && isWebSocketUpgrade(buf)) {
    if (wsHandshake(clientFd, buf)) {
      handleWebSocketControl(clientFd); // blocks until client disconnects
    }
    close(clientFd);
    return;
  }

  // OPTIONS preflight
  if (strcmp(method, "OPTIONS") == 0) {
    sendResponse(clientFd, 204, "No Content", "text/plain", NULL);
    close(clientFd);
    return;
  }

  // Root → redirect to Web IDE
  if (strcmp(path, "/") == 0 && strcmp(method, "GET") == 0) {
    handleStaticFile(clientFd, "/");
    close(clientFd);
    return;
  }

  // Route
  if (strcmp(path, "/api/status") == 0 && strcmp(method, "GET") == 0) {
    handleStatus(clientFd);
  } else if (strcmp(path, "/api/log") == 0 && strcmp(method, "GET") == 0) {
    handleLog(clientFd);
  } else if (strcmp(path, "/api/tap") == 0 && strcmp(method, "POST") == 0) {
    handleTap(clientFd, body);
  } else if (strcmp(path, "/api/swipe") == 0 && strcmp(method, "POST") == 0) {
    handleSwipe(clientFd, body);
  } else if (strcmp(path, "/api/longpress") == 0 &&
             strcmp(method, "POST") == 0) {
    handleLongPress(clientFd, body);
  } else if (strcmp(path, "/api/touch") == 0 && strcmp(method, "POST") == 0) {
    handleTouch(clientFd, body);
  } else if (strcmp(path, "/api/key") == 0 && strcmp(method, "POST") == 0) {
    handleKey(clientFd, body);
  } else if (strcmp(path, "/api/screen") == 0 && strcmp(method, "GET") == 0) {
    handleScreen(clientFd, query);
  } else if (strcmp(path, "/api/stream") == 0 && strcmp(method, "GET") == 0) {
    // MJPEG push stream — blocks until client disconnects
    handleStream(clientFd, query);
  } else if (strcmp(path, "/api/screen/color") == 0 &&
             strcmp(method, "GET") == 0) {
    handleScreenColor(clientFd, query);
  } else if (strcmp(path, "/api/script/run") == 0 &&
             strcmp(method, "POST") == 0) {
    handleScriptRun(clientFd, body);
  } else if (strcmp(path, "/api/script/stop") == 0 &&
             strcmp(method, "POST") == 0) {
    handleScriptStop(clientFd);
  } else if (strcmp(path, "/api/script/status") == 0 &&
             strcmp(method, "GET") == 0) {
    handleScriptStatus(clientFd);
  } else if (strcmp(path, "/api/kill") == 0 && strcmp(method, "GET") == 0) {
    logMsg("💀 /api/kill — daemon shutting down");
    sendResponse(clientFd, 200, "OK", "application/json",
                 "{\"ok\":true,\"message\":\"daemon killed\"}");
    close(clientFd);
    exit(0);
    // ── Phase 7a: Script File Manager ──
  } else if (strcmp(path, "/api/script/list") == 0 &&
             strcmp(method, "GET") == 0) {
    handleScriptList(clientFd);
  } else if (strcmp(path, "/api/script/file") == 0 &&
             strcmp(method, "GET") == 0) {
    handleScriptRead(clientFd, query);
  } else if (strcmp(path, "/api/script/file") == 0 &&
             strcmp(method, "PUT") == 0) {
    handleScriptWrite(clientFd, query, body);
  } else if (strcmp(path, "/api/script/file") == 0 &&
             strcmp(method, "DELETE") == 0) {
    handleScriptDeleteFile(clientFd, query);
    // ── Phase 7b: App Control ──
  } else if (strcmp(path, "/api/app/list") == 0 && strcmp(method, "GET") == 0) {
    handleAppList(clientFd);
  } else if (strcmp(path, "/api/app/launch") == 0 &&
             strcmp(method, "POST") == 0) {
    handleAppLaunch(clientFd, body);
  } else if (strcmp(path, "/api/app/kill") == 0 &&
             strcmp(method, "POST") == 0) {
    handleAppKill(clientFd, body);
  } else if (strcmp(path, "/api/app/frontmost") == 0 &&
             strcmp(method, "GET") == 0) {
    handleAppFrontmost(clientFd);
    // ── Phase 7c: Key Input ──
  } else if (strcmp(path, "/api/key/press") == 0 &&
             strcmp(method, "POST") == 0) {
    handleKeyPress(clientFd, body);
  } else if (strcmp(path, "/api/key/input") == 0 &&
             strcmp(method, "POST") == 0) {
    handleKeyInputText(clientFd, body);
    // ── Phase 7d: Clipboard ──
  } else if (strcmp(path, "/api/clipboard") == 0 &&
             strcmp(method, "GET") == 0) {
    handleClipboardRead(clientFd);
  } else if (strcmp(path, "/api/clipboard") == 0 &&
             strcmp(method, "POST") == 0) {
    handleClipboardWrite(clientFd, body);
    // ── Phase 7e: Device Info + System Log ──
  } else if (strcmp(path, "/api/device/info") == 0 &&
             strcmp(method, "GET") == 0) {
    handleDeviceInfo(clientFd);
  } else if (strcmp(path, "/api/system/log") == 0 &&
             (strcmp(method, "GET") == 0 || strcmp(method, "DELETE") == 0)) {
    handleSystemLog(clientFd, method);
    // ── Template Management ──
  } else if (strcmp(path, "/api/screen/crop") == 0 &&
             strcmp(method, "POST") == 0) {
    handleScreenCrop(clientFd, body);
  } else if (strcmp(path, "/api/templates") == 0 &&
             strcmp(method, "GET") == 0) {
    handleTemplateList(clientFd);
  } else if (strcmp(path, "/api/templates") == 0 &&
             strcmp(method, "DELETE") == 0) {
    handleTemplateDelete(clientFd, query);
  } else if (strcmp(method, "GET") == 0 && strncmp(path, "/static/", 8) == 0) {
    handleStaticFile(clientFd, path);
  } else {
    sendError(clientFd, 404, "not found");
  }

  if (fullBody)
    free(fullBody);
  close(clientFd);
}

// ═══════════════════════════════════════════
// CFSocket accept callback (runs on CFRunLoop)
// ═══════════════════════════════════════════

static void acceptCallback(CFSocketRef s, CFSocketCallBackType type,
                           CFDataRef address, const void *data, void *info) {
  if (type != kCFSocketAcceptCallBack || !data)
    return;

  int clientFd = *(const int *)data;

  // Set timeouts to prevent blocking on slow/dead clients
  struct timeval tv = {.tv_sec = 2, .tv_usec = 0};
  setsockopt(clientFd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
  struct timeval tvw = {.tv_sec = 5, .tv_usec = 0}; // write timeout
  setsockopt(clientFd, SOL_SOCKET, SO_SNDTIMEO, &tvw, sizeof(tvw));

  // Handle on a background queue to not block the run loop
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                 ^{
                   handleClient(clientFd);
                 });
}

// ═══════════════════════════════════════════
// Public: Start HTTP Server
// ═══════════════════════════════════════════

void ic_startHTTPServer(int port) {
  // Create TCP socket
  int sockFd = socket(AF_INET, SOCK_STREAM, 0);
  if (sockFd < 0) {
    logMsg("❌ HTTP: socket() failed");
    return;
  }

  // Allow address reuse
  int yes = 1;
  setsockopt(sockFd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

  // Bind to all interfaces
  struct sockaddr_in addr;
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_port = htons(port);
  addr.sin_addr.s_addr = htonl(INADDR_ANY);

  if (bind(sockFd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
    logMsg("❌ HTTP: bind() failed on port %d (errno=%d)", port, errno);
    close(sockFd);
    return;
  }

  if (listen(sockFd, 8) < 0) {
    logMsg("❌ HTTP: listen() failed");
    close(sockFd);
    return;
  }

  // Wrap in CFSocket for RunLoop integration
  CFSocketContext ctx = {0, NULL, NULL, NULL, NULL};
  CFSocketRef cfSocket =
      CFSocketCreateWithNative(kCFAllocatorDefault, sockFd,
                               kCFSocketAcceptCallBack, acceptCallback, &ctx);

  if (!cfSocket) {
    logMsg("❌ HTTP: CFSocketCreateWithNative failed");
    close(sockFd);
    return;
  }

  CFRunLoopSourceRef source =
      CFSocketCreateRunLoopSource(kCFAllocatorDefault, cfSocket, 0);
  CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopDefaultMode);
  CFRelease(source);
  CFRelease(cfSocket);

  logMsg("═══════════════════════════════════════");
  logMsg("🌐 HTTP Server listening on port %d", port);
  logMsg("   Routes: /api/screen, /api/stream, /ws/control");
  logMsg("           /api/tap, /api/swipe, /api/touch, /api/key");
  logMsg("           /api/script/run, /api/script/stop, /api/status");
  logMsg("═══════════════════════════════════════");

  // Start background frame cache (XXTouch /snapshot pattern)
  // Must be called AFTER gScreenQueue is initialized in main()
  ic_startFrameCache();
}
