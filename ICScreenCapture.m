// ICScreenCapture.m — Screen capture for daemon process
// Uses UIGetScreenImage (private UIKit API, same as XXTouch)

#import "ICScreenCapture.h"
#import <CoreGraphics/CoreGraphics.h>
#import <IOSurface/IOSurfaceRef.h>
#import <ImageIO/ImageIO.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <objc/message.h>
#import <objc/runtime.h>

extern void logMsg(const char *fmt, ...);
extern double gScreenW;
extern double gScreenH;

// ═══════════════════════════════════════
// Function pointers
// ═══════════════════════════════════════

// UIGetScreenImage — returns CGImageRef of full screen (private UIKit)
static CGImageRef (*_UIGetScreenImage)(void);

// _UICreateScreenUIImageWithRotation — alternate API
static void *(*_UICreateScreenUIImageWithRotation)(BOOL);

// CARenderServer fallback
static kern_return_t (*_CARenderServerRenderDisplay)(mach_port_t, CFStringRef,
                                                     IOSurfaceRef, int, int);

// IOSurface basics (for CARenderServer fallback)
static IOSurfaceRef (*_IOSurfaceCreate)(CFDictionaryRef);
static size_t (*_IOSurfaceGetWidth)(IOSurfaceRef);
static size_t (*_IOSurfaceGetHeight)(IOSurfaceRef);
static size_t (*_IOSurfaceGetBytesPerRow)(IOSurfaceRef);
static void *(*_IOSurfaceGetBaseAddress)(IOSurfaceRef);
static int (*_IOSurfaceLock)(IOSurfaceRef, uint32_t, uint32_t *);
static int (*_IOSurfaceUnlock)(IOSurfaceRef, uint32_t, uint32_t *);

// State
static BOOL gReady = NO;

// ═══════════════════════════════════════
// Init
// ═══════════════════════════════════════

void ic_initScreenCapture(void) {
  // UIKit — primary screenshot APIs
  void *uikit =
      dlopen("/System/Library/Frameworks/UIKit.framework/UIKit", RTLD_NOW);
  if (uikit) {
    _UIGetScreenImage = dlsym(uikit, "UIGetScreenImage");
    _UICreateScreenUIImageWithRotation =
        dlsym(uikit, "_UICreateScreenUIImageWithRotation");
    logMsg("📸 UIGetScreenImage=%p", (void *)_UIGetScreenImage);
    logMsg("📸 _UICreateScreenUIImageWithRotation=%p",
           (void *)_UICreateScreenUIImageWithRotation);
  }

  // IOSurface — for CARenderServer fallback
  void *iosurf = dlopen(
      "/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_NOW);
  if (iosurf) {
    _IOSurfaceCreate = dlsym(iosurf, "IOSurfaceCreate");
    _IOSurfaceGetWidth = dlsym(iosurf, "IOSurfaceGetWidth");
    _IOSurfaceGetHeight = dlsym(iosurf, "IOSurfaceGetHeight");
    _IOSurfaceGetBytesPerRow = dlsym(iosurf, "IOSurfaceGetBytesPerRow");
    _IOSurfaceGetBaseAddress = dlsym(iosurf, "IOSurfaceGetBaseAddress");
    _IOSurfaceLock = dlsym(iosurf, "IOSurfaceLock");
    _IOSurfaceUnlock = dlsym(iosurf, "IOSurfaceUnlock");
  }

  // QuartzCore — fallback
  void *qc = dlopen(
      "/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_NOW);
  if (qc) {
    _CARenderServerRenderDisplay = dlsym(qc, "CARenderServerRenderDisplay");
  }

  if (_UIGetScreenImage || _UICreateScreenUIImageWithRotation) {
    gReady = YES;
    logMsg("✅ ScreenCapture: UIGetScreenImage available");
  } else if (_CARenderServerRenderDisplay && _IOSurfaceCreate) {
    gReady = YES;
    logMsg("✅ ScreenCapture: CARenderServer fallback");
  } else {
    logMsg("❌ ScreenCapture: No method available");
  }
}

// ═══════════════════════════════════════
// Method A: UIGetScreenImage (best)
// Returns CGImageRef of full screen at native resolution
// ═══════════════════════════════════════

static CGImageRef captureViaUIGetScreenImage(void) {
  if (_UIGetScreenImage) {
    CGImageRef img = _UIGetScreenImage();
    if (img)
      return img;
    logMsg("⚠️ UIGetScreenImage returned NULL");
  }
  return NULL;
}

// ═══════════════════════════════════════
// Method B: _UICreateScreenUIImageWithRotation
// Returns a UIImage* → extract CGImage
// ═══════════════════════════════════════

static CGImageRef captureViaUICreateScreen(void) {
  if (!_UICreateScreenUIImageWithRotation)
    return NULL;

  // CFBridgingRelease = __bridge_transfer: ARC owns & releases UIImage (~10MB)
  // Previously: __bridge id (no ownership) → UIImage leaked every capture!
  id uiImage = CFBridgingRelease(_UICreateScreenUIImageWithRotation(NO));
  if (!uiImage) {
    logMsg("⚠️ _UICreateScreenUIImageWithRotation returned NULL");
    return NULL;
  }

  CGImageRef cgImg = ((CGImageRef(*)(id, SEL))objc_msgSend)(
      uiImage, sel_registerName("CGImage"));
  if (cgImg)
    CGImageRetain(cgImg); // caller owns, releases via CGImageRelease
  return cgImg;           // uiImage released by ARC here (scope exit)
}

// ═══════════════════════════════════════
// Method C: CARenderServer fallback (1080x1920 safe)
// ═══════════════════════════════════════

static CGImageRef captureViaCARenderServer(void) {
  if (!_CARenderServerRenderDisplay || !_IOSurfaceCreate)
    return NULL;

  @autoreleasepool {
    size_t w = 1080, h = 1920;
    size_t bpr = w * 4;

    NSDictionary *props = @{
      (__bridge NSString *)kIOSurfaceWidth : @(w),
      (__bridge NSString *)kIOSurfaceHeight : @(h),
      (__bridge NSString *)kIOSurfaceBytesPerRow : @(bpr),
      (__bridge NSString *)kIOSurfaceBytesPerElement : @(4),
      (__bridge NSString *)kIOSurfacePixelFormat : @(0x42475241),
      (__bridge NSString *)kIOSurfaceAllocSize : @(bpr * h),
      (__bridge NSString *)kIOSurfaceIsGlobal : @(YES),
    };

    IOSurfaceRef surface = _IOSurfaceCreate((__bridge CFDictionaryRef)props);
    if (!surface)
      return NULL;

    _CARenderServerRenderDisplay(0, CFSTR("LCD"), surface, 0, 0);
    _IOSurfaceLock(surface, 1, NULL);

    void *base = _IOSurfaceGetBaseAddress(surface);
    CGImageRef img = NULL;
    if (base) {
      CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
      CGContextRef ctx = CGBitmapContextCreate(
          base, w, h, 8, bpr, cs,
          kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
      if (ctx) {
        img = CGBitmapContextCreateImage(ctx);
        CGContextRelease(ctx);
      }
      CGColorSpaceRelease(cs);
    }

    _IOSurfaceUnlock(surface, 1, NULL);
    CFRelease(surface);

    if (img) {
      logMsg("📸 CARender fallback: %zux%zu", CGImageGetWidth(img),
             CGImageGetHeight(img));
    }
    return img;
  }
}

// ═══════════════════════════════════════
// JPEG encode
// ═══════════════════════════════════════

static NSData *encodeJPEG(CGImageRef img, float q) {
  if (!img)
    return nil;
  NSMutableData *data = [NSMutableData data];
  CGImageDestinationRef dest = CGImageDestinationCreateWithData(
      (__bridge CFMutableDataRef)data, CFSTR("public.jpeg"), 1, NULL);
  if (!dest)
    return nil;
  NSDictionary *opts =
      @{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality : @(q)};
  CGImageDestinationAddImage(dest, img, (__bridge CFDictionaryRef)opts);
  BOOL ok = CGImageDestinationFinalize(dest);
  CFRelease(dest);
  return ok ? data : nil;
}

// ═══════════════════════════════════════
// Public API
// ═══════════════════════════════════════

NSData *ic_captureScreen(float quality) {
  if (!gReady)
    return nil;
  if (quality <= 0 || quality > 1)
    quality = 0.8f;

  CGImageRef img = NULL;

  // Priority: UIGetScreenImage > UICreateScreen > CARenderServer
  img = captureViaUIGetScreenImage();
  if (!img)
    img = captureViaUICreateScreen();
  if (!img)
    img = captureViaCARenderServer();

  if (!img) {
    logMsg("❌ ScreenCapture: all methods failed");
    return nil;
  }

  NSData *jpeg = encodeJPEG(img, quality);
  // Verbose log removed — called 12fps, too noisy
  CGImageRelease(img);
  return jpeg;
}

BOOL ic_getColorAtPoint(int x, int y, int *outR, int *outG, int *outB) {
  if (!gReady)
    return NO;

  CGImageRef img = captureViaUIGetScreenImage();
  if (!img)
    img = captureViaUICreateScreen();
  if (!img)
    img = captureViaCARenderServer();
  if (!img)
    return NO;

  size_t imgW = CGImageGetWidth(img);
  size_t imgH = CGImageGetHeight(img);
  int px = (int)(x * (double)imgW / gScreenW);
  int py = (int)(y * (double)imgH / gScreenH);

  if (px < 0 || px >= (int)imgW || py < 0 || py >= (int)imgH) {
    CGImageRelease(img);
    return NO;
  }

  uint8_t pixel[4] = {0};
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  CGContextRef ctx = CGBitmapContextCreate(pixel, 1, 1, 8, 4, cs,
                                           kCGBitmapByteOrder32Big |
                                               kCGImageAlphaPremultipliedLast);
  CGContextDrawImage(ctx, CGRectMake(-px, -py, imgW, imgH), img);
  CGContextRelease(ctx);
  CGColorSpaceRelease(cs);
  CGImageRelease(img);

  *outR = pixel[0];
  *outG = pixel[1];
  *outB = pixel[2];
  return YES;
}
