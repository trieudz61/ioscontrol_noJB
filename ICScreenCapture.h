// ICScreenCapture.h — Screen capture via IOSurface private APIs
// Phase 3: System display capture from daemon process

#ifndef ICSCREENCAPTURE_H
#define ICSCREENCAPTURE_H

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Initialize screen capture subsystem (load private framework symbols).
/// Call once at daemon startup.
void ic_initScreenCapture(void);

/// Capture the current system display as JPEG data.
/// @param quality JPEG compression quality 0.0-1.0 (default 0.8)
/// @return NSData containing JPEG image, or nil on failure.
NSData *ic_captureScreen(float quality);

/// Get pixel color at a specific point on screen.
/// @param x X coordinate (logical points)
/// @param y Y coordinate (logical points)
/// @param outR pointer to receive red component (0-255)
/// @param outG pointer to receive green component (0-255)
/// @param outB pointer to receive blue component (0-255)
/// @return YES if successful
BOOL ic_getColorAtPoint(int x, int y, int *outR, int *outG, int *outB);

#ifdef __cplusplus
}
#endif

#endif
