// ICHTTPServer.h — Lightweight HTTP server for IOSControl daemon
// Phase 2: REST API for remote touch control

#ifndef ICHTTPSERVER_H
#define ICHTTPSERVER_H

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Start the HTTP server on the given port, integrated with CFRunLoop.
/// Call this from main() after HID symbols are loaded.
/// @param port TCP port to listen on (default: 46952)
void ic_startHTTPServer(int port);

#ifdef __cplusplus
}
#endif

#endif
