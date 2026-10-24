// SGExtendedClip.h says what this draws. Above and below the cover, its edge rows are drawn out (Core
// Image's clamp), lightly blurred next to the cover and heavily blurred far from it, so the streaks fade
// into a wash of the cover's colors. The cover is laid over sharp, its top and bottom feathered into the
// streaks so no seam shows, and the bottom is shaded for the lock screen's controls.
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import "SGExtendedClip.h"

// The cover's center's height from the top, as a share of the clip's: where the Music app puts a still
// cover on the lock screen, under the clock.
// ponytail: measured from one screenshot of the Music app; tune on a device.
static const CGFloat kCoverY = 0.41;
// A share of the cover's side cut off each edge before it is drawn out: many covers have a thin border or
// a JPEG fringe there, which would be drawn out as a stripe.
static const CGFloat kEdgeTrim = 0.006;
// The blur next to the cover and far from it, as shares of the cover's side, and how far from the cover
// the far blur has taken over.
static const CGFloat kNearBlur = 0.012, kFarBlur = 0.09, kBlendReach = 0.45;
// How much of the cover's top and bottom fades into the streaks, as a share of its side.
static const CGFloat kFeather = 0.05;
// The far wash, a little richer and darker than the cover, as SGFluidClip.m's field is.
static const CGFloat kSaturation = 1.2, kBrightness = -0.06;
// The shade over the bottom, where the lock screen's controls are.
static const CGFloat kShadeFrom = 0.6, kShadeAlpha = 0.4;
// A still picture: a short clip of one frame repeated, enough for the lock screen to loop.
static const int32_t kSeconds = 2, kFPS = 10;

static CGContextRef newContext(CGSize size, void *data, size_t bytesPerRow) {
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(data, (size_t)size.width, (size_t)size.height, 8, bytesPerRow, space,
                                                 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(space);
    return context;
}

// The cover's square in the clip, in Core Image's and Core Graphics' coordinates, which count up from the
// bottom.
static CGRect coverRect(CGSize size, CGFloat visible) {
    CGFloat side = round(size.width * MIN(MAX(visible, 0.3), 1));
    CGFloat top = round(size.height * kCoverY - side / 2);
    return CGRectMake(round((size.width - side) / 2), size.height - top - side, side, side);
}

// The cover trimmed of its edges and scaled into `rect`.
static CIImage *placed(CGImageRef cover, CGRect rect) {
    CIImage *image = [CIImage imageWithCGImage:cover];
    CGRect extent = image.extent;
    image = [image imageByCroppingToRect:CGRectInset(extent, extent.size.width * kEdgeTrim, extent.size.height * kEdgeTrim)];
    extent = image.extent;
    CGAffineTransform move = CGAffineTransformMakeTranslation(-extent.origin.x, -extent.origin.y);
    move = CGAffineTransformConcat(move, CGAffineTransformMakeScale(rect.size.width / extent.size.width, rect.size.height / extent.size.height));
    move = CGAffineTransformConcat(move, CGAffineTransformMakeTranslation(rect.origin.x, rect.origin.y));
    return [image imageByApplyingTransform:move];
}

static CIImage *gradient(CGFloat fromY, CGFloat toY) {
    return [CIFilter filterWithName:@"CILinearGradient" withInputParameters:@{
        @"inputPoint0": [CIVector vectorWithX:0 Y:fromY], @"inputColor0": [CIColor whiteColor],
        @"inputPoint1": [CIVector vectorWithX:0 Y:toY], @"inputColor1": [CIColor blackColor],
    }].outputImage;
}

// Everything but the sharp cover: the drawn-out edges, blurred more the further they reach from it.
static CGImageRef newStreaks(CGImageRef cover, CGSize size, CGRect rect) CF_RETURNS_RETAINED {
    static CIContext *renderer;
    static dispatch_once_t once;
    // On the CPU: the lock screen asks while Spotify is in the background, where GPU work gets it killed.
    dispatch_once(&once, ^{ renderer = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @YES}]; });
    CGRect clip = (CGRect){CGPointZero, size};
    CGFloat side = rect.size.width;
    CIImage *drawn = [placed(cover, rect) imageByClampingToExtent];
    CIImage *near = [drawn imageByApplyingGaussianBlurWithSigma:side * kNearBlur];
    CIImage *far = [[drawn imageByApplyingGaussianBlurWithSigma:side * kFarBlur]
        imageByApplyingFilter:@"CIColorControls" withInputParameters:@{kCIInputSaturationKey: @(kSaturation), kCIInputBrightnessKey: @(kBrightness)}];
    // White over the cover, fading to black kBlendReach of its side above and below it.
    CGFloat reach = side * kBlendReach;
    CIImage *above = gradient(CGRectGetMaxY(rect), CGRectGetMaxY(rect) + reach);
    CIImage *below = gradient(CGRectGetMinY(rect), CGRectGetMinY(rect) - reach);
    CIImage *mask = [above imageByApplyingFilter:@"CIMultiplyCompositing" withInputParameters:@{kCIInputBackgroundImageKey: below}];
    CIImage *output = [near imageByApplyingFilter:@"CIBlendWithMask"
                              withInputParameters:@{kCIInputBackgroundImageKey: far, kCIInputMaskImageKey: mask}];
    return [renderer createCGImage:[output imageByCroppingToRect:clip] fromRect:clip];
}

// A gray mask the size of the cover: clear at its top and bottom edges, solid kFeather of its side in.
static CGImageRef newFeather(CGFloat side) CF_RETURNS_RETAINED {
    size_t pixels = (size_t)side;
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGContextRef context = CGBitmapContextCreate(NULL, pixels, pixels, 8, 0, gray, (CGBitmapInfo)kCGImageAlphaNone);
    CGFloat colors[] = {0, 1, 1, 1, 1, 1, 0, 1}, feather = kFeather;
    CGFloat locations[] = {0, feather, 1 - feather, 1};
    CGGradientRef ramp = CGGradientCreateWithColorComponents(gray, colors, locations, 4);
    CGContextDrawLinearGradient(context, ramp, CGPointZero, CGPointMake(0, side), 0);
    CGImageRef mask = CGBitmapContextCreateImage(context);
    CGGradientRelease(ramp);
    CGContextRelease(context);
    CGColorSpaceRelease(gray);
    return mask;
}

// The frame into `context`, which is `size`. NO when the streaks could not be made.
static BOOL drawFrame(CGContextRef context, CGImageRef cover, CGSize size, CGFloat visible) {
    CGRect rect = coverRect(size, visible);
    CGImageRef streaks = newStreaks(cover, size, rect);
    if (!streaks) return NO;
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextDrawImage(context, (CGRect){CGPointZero, size}, streaks);
    CGImageRelease(streaks);
    // The cover sharp, trimmed as the streaks were so the two meet on the same rows.
    CGFloat width = CGImageGetWidth(cover), height = CGImageGetHeight(cover);
    CGImageRef trimmed = CGImageCreateWithImageInRect(cover, CGRectInset(CGRectMake(0, 0, width, height), width * kEdgeTrim, height * kEdgeTrim));
    CGImageRef feather = newFeather(rect.size.width);
    CGContextSaveGState(context);
    CGContextClipToMask(context, rect, feather);
    CGContextDrawImage(context, rect, trimmed ?: cover);
    CGContextRestoreGState(context);
    CGImageRelease(feather);
    CGImageRelease(trimmed);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGFloat colors[] = {0, 0, 0, 0, 0, 0, 0, kShadeAlpha}, locations[] = {0, 1};
    CGGradientRef shade = CGGradientCreateWithColorComponents(space, colors, locations, 2);
    CGContextDrawLinearGradient(context, shade, CGPointMake(0, size.height * (1 - kShadeFrom)), CGPointZero, kCGGradientDrawsAfterEndLocation);
    CGGradientRelease(shade);
    CGColorSpaceRelease(space);
    return YES;
}

CGImageRef SGExtendedClipFrame(CGImageRef cover, CGSize size, CGFloat visible) {
    if (!cover) return NULL;
    CGContextRef context = newContext(size, NULL, 0);
    CGImageRef frame = drawFrame(context, cover, size, visible) ? CGBitmapContextCreateImage(context) : NULL;
    CGContextRelease(context);
    return frame;
}

// The frame is drawn once into one buffer, which every frame of the clip repeats.
BOOL SGExtendedClipWrite(NSURL *file, CGImageRef cover, CGSize size, CGFloat visible) {
    if (!cover) return NO;
    // Written beside the file and moved over it once whole, so a clip cut off halfway is never found.
    NSURL *partial = [file URLByAppendingPathExtension:@"partial"];
    [NSFileManager.defaultManager removeItemAtURL:partial error:nil];
    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:partial fileType:AVFileTypeMPEG4 error:nil];
    if (!writer) return NO;
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:@{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @(size.width),
        AVVideoHeightKey: @(size.height),
        AVVideoCompressionPropertiesKey: @{AVVideoAverageBitRateKey: @(2000000), AVVideoMaxKeyFrameIntervalKey: @(kFPS)},
    }];
    AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input
        sourcePixelBufferAttributes:@{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey: @(size.width),
            (id)kCVPixelBufferHeightKey: @(size.height),
        }];
    if (![writer canAddInput:input]) return NO;
    [writer addInput:input];
    if (![writer startWriting]) return NO;
    [writer startSessionAtSourceTime:kCMTimeZero];
    CVPixelBufferRef buffer = NULL;
    BOOL ok = adaptor.pixelBufferPool && CVPixelBufferPoolCreatePixelBuffer(NULL, adaptor.pixelBufferPool, &buffer) == kCVReturnSuccess;
    if (ok) {
        CVPixelBufferLockBaseAddress(buffer, 0);
        CGContextRef context = newContext(size, CVPixelBufferGetBaseAddress(buffer), CVPixelBufferGetBytesPerRow(buffer));
        ok = drawFrame(context, cover, size, visible);
        CGContextRelease(context);
        CVPixelBufferUnlockBaseAddress(buffer, 0);
    }
    int32_t frames = kSeconds * kFPS;
    for (int32_t i = 0; i < frames && ok; i++) {
        while (!input.readyForMoreMediaData && writer.status == AVAssetWriterStatusWriting) [NSThread sleepForTimeInterval:0.002];
        ok = writer.status == AVAssetWriterStatusWriting && [adaptor appendPixelBuffer:buffer withPresentationTime:CMTimeMake(i, kFPS)];
    }
    CVPixelBufferRelease(buffer);
    if (!ok) {
        [writer cancelWriting];
        return NO;
    }
    [input markAsFinished];
    [writer endSessionAtSourceTime:CMTimeMake(kSeconds, 1)];
    dispatch_semaphore_t written = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(written); }];
    dispatch_semaphore_wait(written, DISPATCH_TIME_FOREVER);
    if (writer.status != AVAssetWriterStatusCompleted) return NO;
    [NSFileManager.defaultManager removeItemAtURL:file error:nil];
    return [NSFileManager.defaultManager moveItemAtURL:partial toURL:file error:nil];
}
