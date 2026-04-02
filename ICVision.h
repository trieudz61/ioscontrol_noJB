// ICVision.h — OCR + Image Processing for IOSControl daemon
// Uses Apple Vision framework (VNRecognizeTextRequest) for OCR.
// Uses CoreGraphics pixel scanning for color search.

#import <Foundation/Foundation.h>

// ─── OCR ─────────────────────────────────────────────────────────────────────
// Capture current screen and run OCR on it.
// Returns NSArray<NSString*> of recognized text strings (top candidates).
// Returns nil and logs error on failure.
NSArray<NSString *> *ic_ocrScreen(void);

// ─── Color Search
// ───────────────────────────────────────────────────────────── Find the FIRST
// pixel matching (r,g,b) within `tolerance` (Chebyshev dist). Pixel coords are
// in screen-point space (matching gScreenW/gScreenH). Returns YES and sets
// *outX, *outY on match; returns NO on failure.
BOOL ic_findColor(int r, int g, int b, int tolerance, int *outX, int *outY);

// Find ALL pixels matching (r,g,b) within `tolerance`, up to `maxCount`.
// Returns NSArray<NSDictionary*> each @{@"x": @(int), @"y": @(int)}.
NSArray<NSDictionary *> *ic_findMultiColor(int r, int g, int b, int tolerance,
                                           int maxCount);
