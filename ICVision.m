// ICVision.m — OCR + Image Processing for IOSControl daemon
// Phase 6: Apple Vision (VNRecognizeTextRequest) + CoreGraphics pixel scan.

#import "ICVision.h"
#import "ICScreenCapture.h"

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <Vision/Vision.h>

extern void logMsg(const char *fmt, ...);
extern double gScreenW;
extern double gScreenH;

// ════════════════════════════════════════════════════════════
// Internal helper: decode JPEG NSData → RGBA CGBitmapContext
// Caller must CGContextRelease() the returned context.
// ════════════════════════════════════════════════════════════

static CGContextRef createRGBAContextFromJPEG(NSData *jpeg, size_t *outWidth,
                                              size_t *outHeight) {
  if (!jpeg || jpeg.length == 0)
    return NULL;

  CGDataProviderRef provider =
      CGDataProviderCreateWithCFData((__bridge CFDataRef)jpeg);
  if (!provider)
    return NULL;

  CGImageRef img = CGImageCreateWithJPEGDataProvider(provider, NULL, true,
                                                     kCGRenderingIntentDefault);
  CGDataProviderRelease(provider);
  if (!img)
    return NULL;

  size_t w = CGImageGetWidth(img);
  size_t h = CGImageGetHeight(img);
  if (outWidth)
    *outWidth = w;
  if (outHeight)
    *outHeight = h;

  size_t bpr = w * 4;
  void *buf = calloc(h, bpr);
  if (!buf) {
    CGImageRelease(img);
    return NULL;
  }

  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  CGContextRef ctx = CGBitmapContextCreate(buf, w, h, 8, bpr, cs,
                                           kCGBitmapByteOrder32Big |
                                               kCGImageAlphaNoneSkipLast);
  CGColorSpaceRelease(cs);

  if (!ctx) {
    free(buf);
    CGImageRelease(img);
    return NULL;
  }

  CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img);
  CGImageRelease(img);

  // Note: buf is owned by ctx; freed when ctx is released via CGContextRelease
  // Actually CGBitmapContext does NOT free the data — we must track it.
  // Store buf pointer in context's user info via a side-channel isn't possible.
  // Solution: always call CGContextRelease + free(CGBitmapContextGetData(ctx)).
  return ctx;
}

// ════════════════════════════════════════════════════════════
// ic_ocrScreen — Apple Vision OCR
// ════════════════════════════════════════════════════════════

NSArray<NSString *> *ic_ocrScreen(void) {
  // Capture at high quality for best OCR accuracy
  NSData *jpeg = ic_captureScreen(0.9f);
  if (!jpeg || jpeg.length == 0) {
    logMsg("❌ [OCR] Screen capture failed");
    return nil;
  }

  // Build CGImage from JPEG for Vision
  CGDataProviderRef provider =
      CGDataProviderCreateWithCFData((__bridge CFDataRef)jpeg);
  if (!provider)
    return nil;

  CGImageRef cgImg = CGImageCreateWithJPEGDataProvider(
      provider, NULL, true, kCGRenderingIntentDefault);
  CGDataProviderRelease(provider);
  if (!cgImg) {
    logMsg("❌ [OCR] Failed to decode JPEG for Vision");
    return nil;
  }

  __block NSArray<NSString *> *results = nil;
  __block NSError *ocrError = nil;

  // VNRecognizeTextRequest
  VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc]
      initWithCompletionHandler:^(VNRequest *req, NSError *error) {
        if (error) {
          ocrError = error;
          return;
        }
        NSMutableArray<NSString *> *texts = [NSMutableArray array];
        for (VNRecognizedTextObservation *obs in req.results) {
          VNRecognizedText *top = [obs topCandidates:1].firstObject;
          if (top && top.string.length > 0) {
            [texts addObject:top.string];
          }
        }
        results = [texts copy];
      }];

  // Accurate mode: slower but higher quality
  request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
  request.usesLanguageCorrection = YES;

  VNImageRequestHandler *handler =
      [[VNImageRequestHandler alloc] initWithCGImage:cgImg options:@{}];
  CGImageRelease(cgImg);

  NSError *handlerError = nil;
  [handler performRequests:@[ request ] error:&handlerError];

  if (handlerError) {
    logMsg("❌ [OCR] Vision handler error: %s",
           handlerError.localizedDescription.UTF8String);
    return nil;
  }
  if (ocrError) {
    logMsg("❌ [OCR] Recognition error: %s",
           ocrError.localizedDescription.UTF8String);
    return nil;
  }

  logMsg("✅ [OCR] Recognized %d text region(s)", (int)(results.count));
  return results;
}

// ════════════════════════════════════════════════════════════
// ic_findColor — find first pixel matching (r,g,b) ± tolerance
// ════════════════════════════════════════════════════════════

BOOL ic_findColor(int r, int g, int b, int tolerance, int *outX, int *outY) {
  if (!outX || !outY)
    return NO;

  NSData *jpeg = ic_captureScreen(1.0f);
  if (!jpeg || jpeg.length == 0) {
    logMsg("❌ [findColor] Screen capture failed");
    return NO;
  }

  size_t imgW = 0, imgH = 0;
  CGContextRef ctx = createRGBAContextFromJPEG(jpeg, &imgW, &imgH);
  if (!ctx) {
    logMsg("❌ [findColor] Failed to decode JPEG");
    return NO;
  }

  const uint8_t *pixels = (const uint8_t *)CGBitmapContextGetData(ctx);
  size_t bpr = CGBitmapContextGetBytesPerRow(ctx);
  int tol = tolerance < 0 ? 0 : tolerance;
  BOOL found = NO;

  for (size_t py = 0; py < imgH && !found; py++) {
    const uint8_t *row = pixels + py * bpr;
    for (size_t px = 0; px < imgW && !found; px++) {
      int pr = row[px * 4 + 0];
      int pg = row[px * 4 + 1];
      int pb = row[px * 4 + 2];
      // Chebyshev distance (max channel diff)
      int dist = MAX(MAX(abs(pr - r), abs(pg - g)), abs(pb - b));
      if (dist <= tol) {
        // Map image pixel coords → screen point coords
        *outX = (int)((double)px * gScreenW / (double)imgW);
        *outY = (int)((double)py * gScreenH / (double)imgH);
        found = YES;
      }
    }
  }

  void *data = CGBitmapContextGetData(ctx);
  CGContextRelease(ctx);
  free(data);

  if (found) {
    logMsg("✅ [findColor] (%d,%d,%d) tol=%d found at (%d,%d)", r, g, b, tol,
           *outX, *outY);
  } else {
    logMsg("⚠️  [findColor] (%d,%d,%d) tol=%d — not found", r, g, b, tol);
  }
  return found;
}

// ════════════════════════════════════════════════════════════
// ic_findMultiColor — find all matching pixels (up to maxCount)
// ════════════════════════════════════════════════════════════

NSArray<NSDictionary *> *ic_findMultiColor(int r, int g, int b, int tolerance,
                                           int maxCount) {
  NSData *jpeg = ic_captureScreen(1.0f);
  if (!jpeg || jpeg.length == 0) {
    logMsg("❌ [findMultiColor] Screen capture failed");
    return @[];
  }

  size_t imgW = 0, imgH = 0;
  CGContextRef ctx = createRGBAContextFromJPEG(jpeg, &imgW, &imgH);
  if (!ctx) {
    logMsg("❌ [findMultiColor] Failed to decode JPEG");
    return @[];
  }

  const uint8_t *pixels = (const uint8_t *)CGBitmapContextGetData(ctx);
  size_t bpr = CGBitmapContextGetBytesPerRow(ctx);
  int tol = tolerance < 0 ? 0 : tolerance;
  int limit = (maxCount <= 0) ? 100 : maxCount;

  NSMutableArray<NSDictionary *> *results = [NSMutableArray array];

  for (size_t py = 0; py < imgH && (int)results.count < limit; py++) {
    const uint8_t *row = pixels + py * bpr;
    for (size_t px = 0; px < imgW && (int)results.count < limit; px++) {
      int pr = row[px * 4 + 0];
      int pg = row[px * 4 + 1];
      int pb = row[px * 4 + 2];
      int dist = MAX(MAX(abs(pr - r), abs(pg - g)), abs(pb - b));
      if (dist <= tol) {
        int sx = (int)((double)px * gScreenW / (double)imgW);
        int sy = (int)((double)py * gScreenH / (double)imgH);
        [results addObject:@{@"x" : @(sx), @"y" : @(sy)}];
      }
    }
  }

  void *data = CGBitmapContextGetData(ctx);
  CGContextRelease(ctx);
  free(data);

  logMsg("✅ [findMultiColor] (%d,%d,%d) tol=%d → %d result(s)", r, g, b, tol,
         (int)results.count);
  return [results copy];
}
