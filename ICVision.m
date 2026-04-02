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

// ════════════════════════════════════════════════════════════
// ic_findText — OCR-based text search
// Uses Apple Vision to find text on screen, returns center of bounding box.
// ════════════════════════════════════════════════════════════

BOOL ic_findText(NSString *text, int *outX, int *outY) {
  if (!text.length || !outX || !outY)
    return NO;

  // Capture at high quality for best OCR accuracy
  NSData *jpeg = ic_captureScreen(0.9f);
  if (!jpeg || jpeg.length == 0) {
    logMsg("❌ [findText] Screen capture failed");
    return NO;
  }

  // Build CGImage from JPEG for Vision
  CGDataProviderRef provider =
      CGDataProviderCreateWithCFData((__bridge CFDataRef)jpeg);
  if (!provider)
    return NO;

  CGImageRef cgImg = CGImageCreateWithJPEGDataProvider(
      provider, NULL, true, kCGRenderingIntentDefault);
  CGDataProviderRelease(provider);
  if (!cgImg) {
    logMsg("❌ [findText] Failed to decode JPEG");
    return NO;
  }

  size_t imgW = CGImageGetWidth(cgImg);
  size_t imgH = CGImageGetHeight(cgImg);

  __block BOOL found = NO;
  __block CGRect matchBox = CGRectZero;

  VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc]
      initWithCompletionHandler:^(VNRequest *req, NSError *error) {
        if (error)
          return;
        NSString *lowTarget = [text lowercaseString];
        for (VNRecognizedTextObservation *obs in req.results) {
          VNRecognizedText *top = [obs topCandidates:1].firstObject;
          if (!top || top.string.length == 0)
            continue;
          if ([[top.string lowercaseString] containsString:lowTarget]) {
            // boundingBox is normalized (0..1), origin=bottom-left
            matchBox = obs.boundingBox;
            found = YES;
            break;
          }
        }
      }];

  request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
  request.usesLanguageCorrection = YES;

  VNImageRequestHandler *handler =
      [[VNImageRequestHandler alloc] initWithCGImage:cgImg options:@{}];
  CGImageRelease(cgImg);

  NSError *handlerError = nil;
  [handler performRequests:@[ request ] error:&handlerError];

  if (handlerError || !found) {
    if (handlerError) {
      logMsg("❌ [findText] Vision error: %s",
             handlerError.localizedDescription.UTF8String);
    } else {
      logMsg("⚠️  [findText] \"%s\" not found on screen", text.UTF8String);
    }
    return NO;
  }

  // Convert normalized boundingBox to screen coordinates
  // Vision: origin=bottom-left, normalized 0..1
  // Screen: origin=top-left, in points
  double centerNormX = CGRectGetMidX(matchBox);
  double centerNormY = 1.0 - CGRectGetMidY(matchBox); // flip Y

  *outX = (int)(centerNormX * gScreenW);
  *outY = (int)(centerNormY * gScreenH);

  logMsg("✅ [findText] \"%s\" found at (%d, %d)", text.UTF8String, *outX,
         *outY);
  return YES;
}

// ════════════════════════════════════════════════════════════
// ic_findImage — Template matching (SAD - Sum of Absolute Differences)
// ════════════════════════════════════════════════════════════

BOOL ic_findImage(NSString *imagePath, double threshold,
                  int *outX, int *outY) {
  if (!imagePath.length || !outX || !outY)
    return NO;

  if (threshold <= 0.0 || threshold > 1.0)
    threshold = 0.8;

  CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();

  // ── Load template image ──
  NSData *templateData = [NSData dataWithContentsOfFile:imagePath];
  if (!templateData || templateData.length == 0) {
    logMsg("❌ [findImage] Cannot read template: %s", imagePath.UTF8String);
    return NO;
  }

  CGImageRef templateImg = NULL;
  CGDataProviderRef tProv =
      CGDataProviderCreateWithCFData((__bridge CFDataRef)templateData);
  if (!tProv)
    return NO;

  templateImg = CGImageCreateWithPNGDataProvider(tProv, NULL, true,
                                                  kCGRenderingIntentDefault);
  if (!templateImg) {
    templateImg = CGImageCreateWithJPEGDataProvider(tProv, NULL, true,
                                                    kCGRenderingIntentDefault);
  }
  CGDataProviderRelease(tProv);

  if (!templateImg) {
    logMsg("❌ [findImage] Failed to decode template image");
    return NO;
  }

  size_t tW = CGImageGetWidth(templateImg);
  size_t tH = CGImageGetHeight(templateImg);

  // Render template to RGBA
  size_t tBpr = tW * 4;
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  void *tBuf = calloc(tH, tBpr);
  CGContextRef tCtx = CGBitmapContextCreate(
      tBuf, tW, tH, 8, tBpr, cs,
      kCGBitmapByteOrder32Big | kCGImageAlphaNoneSkipLast);
  CGContextDrawImage(tCtx, CGRectMake(0, 0, tW, tH), templateImg);
  CGImageRelease(templateImg);
  const uint8_t *tPixels = (const uint8_t *)tBuf;

  // ── Capture screen ──
  NSData *jpeg = ic_captureScreen(1.0f);
  if (!jpeg || jpeg.length == 0) {
    CGContextRelease(tCtx);
    free(tBuf);
    CGColorSpaceRelease(cs);
    logMsg("❌ [findImage] Screen capture failed");
    return NO;
  }

  size_t sW = 0, sH = 0;
  CGContextRef sCtx = createRGBAContextFromJPEG(jpeg, &sW, &sH);
  if (!sCtx) {
    CGContextRelease(tCtx);
    free(tBuf);
    CGColorSpaceRelease(cs);
    logMsg("❌ [findImage] Failed to decode screen");
    return NO;
  }

  const uint8_t *sPixels = (const uint8_t *)CGBitmapContextGetData(sCtx);
  size_t sBpr = CGBitmapContextGetBytesPerRow(sCtx);

  if (tW > sW || tH > sH) {
    logMsg("❌ [findImage] Template (%zux%zu) larger than screen (%zux%zu)",
           tW, tH, sW, sH);
    CGContextRelease(tCtx);
    free(tBuf);
    void *sData = CGBitmapContextGetData(sCtx);
    CGContextRelease(sCtx);
    free(sData);
    CGColorSpaceRelease(cs);
    return NO;
  }

  // ════════════════════════════════════════════════════════════
  // Optimized 2-phase template matching:
  // Phase 1: Coarse scan at stride=4, sampling every 4th pixel → ~16x faster
  // Phase 2: Refine top candidate at stride=1 in ±8px neighborhood
  // ════════════════════════════════════════════════════════════

  double bestScore = 1e18;
  int bestX = -1, bestY = -1;

  // ── Phase 1: Coarse scan (stride=4 position, sample every 4th pixel) ──
  int coarseStride = 4;
  int sampleStep = 4;  // sample every 4th pixel in template

  for (int sy = 0; sy <= (int)(sH - tH); sy += coarseStride) {
    for (int sx = 0; sx <= (int)(sW - tW); sx += coarseStride) {
      double sad = 0;
      BOOL earlyExit = NO;

      for (int ty = 0; ty < (int)tH && !earlyExit; ty += sampleStep) {
        const uint8_t *sRow = sPixels + (sy + ty) * sBpr + sx * 4;
        const uint8_t *tRow = tPixels + ty * tBpr;
        for (int tx = 0; tx < (int)tW; tx += sampleStep) {
          int idx = tx * 4;
          sad += abs(sRow[idx] - tRow[idx]) +
                 abs(sRow[idx+1] - tRow[idx+1]) +
                 abs(sRow[idx+2] - tRow[idx+2]);
          if (sad > bestScore) { earlyExit = YES; break; }
        }
      }

      if (!earlyExit && sad < bestScore) {
        bestScore = sad;
        bestX = sx;
        bestY = sy;
      }
    }
  }

  // ── Phase 2: Refine around best candidate (±8px, stride=1, full pixel) ──
  if (bestX >= 0) {
    int refineR = 8;  // ±8 pixel refinement radius
    int rxMin = (bestX - refineR < 0) ? 0 : bestX - refineR;
    int ryMin = (bestY - refineR < 0) ? 0 : bestY - refineR;
    int rxMax = (bestX + refineR > (int)(sW - tW)) ? (int)(sW - tW) : bestX + refineR;
    int ryMax = (bestY + refineR > (int)(sH - tH)) ? (int)(sH - tH) : bestY + refineR;

    // Reset bestScore for full-pixel comparison
    bestScore = 1e18;

    for (int sy = ryMin; sy <= ryMax; sy++) {
      for (int sx = rxMin; sx <= rxMax; sx++) {
        double sad = 0;
        BOOL earlyExit = NO;

        for (int ty = 0; ty < (int)tH && !earlyExit; ty++) {
          const uint8_t *sRow = sPixels + (sy + ty) * sBpr + sx * 4;
          const uint8_t *tRow = tPixels + ty * tBpr;
          for (int tx = 0; tx < (int)tW; tx++) {
            int idx = tx * 4;
            sad += abs(sRow[idx] - tRow[idx]) +
                   abs(sRow[idx+1] - tRow[idx+1]) +
                   abs(sRow[idx+2] - tRow[idx+2]);
            if (sad > bestScore) { earlyExit = YES; break; }
          }
        }

        if (!earlyExit && sad < bestScore) {
          bestScore = sad;
          bestX = sx;
          bestY = sy;
        }
      }
    }
  }

  // Cleanup
  CGContextRelease(tCtx);
  free(tBuf);
  void *sData = CGBitmapContextGetData(sCtx);
  CGContextRelease(sCtx);
  free(sData);
  CGColorSpaceRelease(cs);

  if (bestX < 0) {
    logMsg("⚠️  [findImage] No match found");
    return NO;
  }

  // Calculate similarity
  double maxSAD = (double)(tW * tH) * 765.0;
  double similarity = 1.0 - (bestScore / maxSAD);

  CFAbsoluteTime elapsed = CFAbsoluteTimeGetCurrent() - t0;

  if (similarity < threshold) {
    logMsg("⚠️  [findImage] Best match %.1f%% below threshold %.1f%% (%.0fms)",
           similarity * 100.0, threshold * 100.0, elapsed * 1000);
    return NO;
  }

  // Map image coords → screen point coords
  *outX = (int)(((double)bestX + tW / 2.0) * gScreenW / (double)sW);
  *outY = (int)(((double)bestY + tH / 2.0) * gScreenH / (double)sH);

  logMsg("✅ [findImage] Match %.1f%% at (%d, %d) in %.0fms",
         similarity * 100.0, *outX, *outY, elapsed * 1000);
  return YES;
}
