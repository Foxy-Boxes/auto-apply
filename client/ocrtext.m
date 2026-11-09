/* ocrtext -- OCR a PNG with the Vision framework.
 * usage: ocrtext <image.png> [x y w h]
 *   Prints JSON: [{"text","conf","x","y","w","h"}, ...] in pixel coords,
 *   top-left origin, matching ScreenCaptureKit output. Optional x y w h
 *   (pixels, top-left origin) restricts OCR to a crop so we can verify
 *   one field region. No LLM; pure on-device recognition.
 */
#import <Foundation/Foundation.h>
#import <Vision/Vision.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>

static CGImageRef loadPNG(const char *path) {
    CFStringRef p = CFStringCreateWithCString(NULL, path, kCFStringEncodingUTF8);
    CFURLRef url = CFURLCreateWithFileSystemPath(NULL, p, kCFURLPOSIXPathStyle, false);
    CFRelease(p);
    CGImageSourceRef src = CGImageSourceCreateWithURL(url, NULL);
    CFRelease(url);
    if (!src) return NULL;
    CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CFRelease(src);
    return img;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: ocrtext <image.png> [x y w h]\n"); return 2; }
        CGImageRef full = loadPNG(argv[1]);
        if (!full) { fprintf(stderr, "cannot load %s\n", argv[1]); return 1; }
        size_t W = CGImageGetWidth(full), H = CGImageGetHeight(full);

        CGImageRef img = full; CGFloat offx = 0, offy = 0;
        if (argc >= 6) {                         /* crop to a region (pixels, top-left) */
            CGRect r = CGRectMake(atof(argv[2]), atof(argv[3]), atof(argv[4]), atof(argv[5]));
            CGImageRef c = CGImageCreateWithImageInRect(full, r);
            if (c) { img = c; offx = r.origin.x; offy = r.origin.y; W = CGImageGetWidth(c); H = CGImageGetHeight(c); }
        }

        VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc] init];
        req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
        req.usesLanguageCorrection = YES;

        VNImageRequestHandler *h = [[VNImageRequestHandler alloc] initWithCGImage:img options:@{}];
        NSError *err = nil;
        [h performRequests:@[req] error:&err];
        if (err) { fprintf(stderr, "vision error: %s\n", err.localizedDescription.UTF8String); return 1; }

        NSMutableArray *out = [NSMutableArray array];
        for (VNRecognizedTextObservation *o in req.results) {
            VNRecognizedText *top = [[o topCandidates:1] firstObject];
            if (!top) continue;
            CGRect bb = o.boundingBox;           /* normalized, origin bottom-left */
            CGFloat px = offx + bb.origin.x * W;
            CGFloat py = offy + (1.0 - bb.origin.y - bb.size.height) * H;
            [out addObject:@{ @"text": top.string,
                              @"conf": @(top.confidence),
                              @"x": @((int)round(px)), @"y": @((int)round(py)),
                              @"w": @((int)round(bb.size.width * W)),
                              @"h": @((int)round(bb.size.height * H)) }];
        }
        NSData *j = [NSJSONSerialization dataWithJSONObject:out
                       options:NSJSONWritingPrettyPrinted error:nil];
        fwrite(j.bytes, 1, j.length, stdout); printf("\n");
        return 0;
    }
}
