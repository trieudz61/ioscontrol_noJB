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

// ─── Text Search (OCR-based)
// ─────────────────────────────────────────────────────────
// Capture screen, run OCR, search for target text.
// Returns YES and sets *outX, *outY to the center of the matching text region.
// Case-insensitive partial match (containsString).
BOOL ic_findText(NSString *text, int *outX, int *outY);

// ─── Image Search (template matching)
// ─────────────────────────────────────────────────
// Load a template image from file, capture screen, find best match.
// threshold: 0.0-1.0 (higher = stricter, default 0.8).
// Returns YES and sets *outX, *outY to center of match.
BOOL ic_findImage(NSString *imagePath, double threshold,
                  int *outX, int *outY);
