// IOSControl.h — Phase 1: Touch injection API
// Functions exposed from Tweak.xm to other modules (HTTPServer, LuaEngine in
// later phases)

#ifndef IOSCONTROL_H
#define IOSCONTROL_H

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// ── Touch Injection (direct HID dispatch) ──
void ic_touchDown(double x, double y, int finger);
void ic_touchMove(double x, double y, int finger);
void ic_touchUp(double x, double y, int finger);
void ic_tap(double x, double y);
void ic_swipe(double x1, double y1, double x2, double y2, double duration);
void ic_longPress(double x, double y, double duration);
void ic_pinch(double cx, double cy, double scale, double duration);

// ── System Commands ──
void ic_pressHome(void);
void ic_vibrate(void);
void ic_showToast(NSString *message);
void ic_launchApp(NSString *bundleId);
void ic_killApp(NSString *bundleId);

// ── Device Info ──
NSDictionary *ic_deviceInfo(void);
void ic_getScreenSize(double *outW, double *outH);
int ic_getOrientation(void);
NSString *ic_frontMostAppId(void);

// ── HTTP Server (Phase 2) ──
void ic_startHTTPServer(int port);

// ── Screen Capture (Phase 3) ──
void ic_initScreenCapture(void);
NSData *ic_captureScreen(float quality);
BOOL ic_getColorAtPoint(int x, int y, int *outR, int *outG, int *outB);

// ── Logging ──
void logMsg(const char *fmt, ...);

#ifdef __cplusplus
}
#endif

#endif
