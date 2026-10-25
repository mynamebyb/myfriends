//
//  GameRecorderV4 (takefour) — 版本4：内存逼近阈值自动降采样
//  用 task_info 检测进程内存，接近红线就自动降帧采集，避免被系统杀掉。
//
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <mach/mach.h>

static id<MTLDevice> gDevice;
static id<MTLCommandQueue> gQueue;
static CVMetalTextureCacheRef gTexCache;
static MPSImageLanczosScale *gScaler;
static dispatch_queue_t gWriteQ;

static BOOL gRecording = NO;
static BOOL gNeedInit = NO;
static AVAssetWriter *gWriter;
static AVAssetWriterInput *gInput;
static AVAssetWriterInputPixelBufferAdaptor *gAdaptor;
static NSURL *gOutURL;
static NSInteger gFrameCount;
static CGSize gVideoSize;
static double gStartTime;
static int gFrameSkip;
static int gInflightBlits;

static int gThrottle = 0;       // 版本4：内存逼近阈值标记
static long gMemKB = 0;         // 当前进程内存 KB
static int gThrottleSkip = 0;
static const long gMemLimitKB = 400 * 1024;  // 400MB 触发降采样（LiveContainer 内存紧，可调）

static CAMetalLayer *gGameLayer;
static id prevGameDrawable;

static UIWindow *gBtnWindow;
static UIView *gBtn;
static UIButton *gBtnLabel;

static id (*orig_nextDrawable)(id, SEL);

static UIViewController *topViewController(void) {
    UIWindow *kw = [UIApplication sharedApplication].keyWindow;
    UIViewController *vc = kw.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

static CAMetalLayer *findGameLayer(void) {
    CAMetalLayer *best = nil; CGFloat bestArea = 0;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.hidden) continue;
        UIView *rv = w.rootViewController.view;
        if (!rv) continue;
        NSMutableArray *stack = [NSMutableArray arrayWithObject:rv];
        while (stack.count) {
            UIView *cur = stack.lastObject; [stack removeLastObject];
            if ([cur.layer isKindOfClass:[CAMetalLayer class]]) {
                CGRect b = cur.bounds; CGFloat a = b.size.width * b.size.height;
                if (a > bestArea) { bestArea = a; best = (CAMetalLayer *)cur.layer; }
            }
            for (UIView *sv in cur.subviews) [stack addObject:sv];
        }
    }
    return best;
}

static BOOL initWriterFromSize(CGSize texSize) {
    if (texSize.width <= 0 || texSize.height <= 0) return NO;
    gVideoSize = texSize;
    CGFloat targetW = 540;
    if (gVideoSize.width > targetW) {
        CGFloat ratio = targetW / gVideoSize.width;
        gVideoSize = CGSizeMake(targetW, (NSInteger)(gVideoSize.height * ratio / 2) * 2);
    }
    gScaler = [[MPSImageLanczosScale alloc] initWithDevice:gDevice];
    NSURL *tmp = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"recV4_%ld.mp4", (long)[NSDate date].timeIntervalSince1970]]];
    gOutURL = tmp;
    NSError *err = nil;
    gWriter = [AVAssetWriter assetWriterWithURL:tmp fileType:AVFileTypeMPEG4 error:&err];
    if (!gWriter) { NSLog(@"[GRV4] writer 失败 %@", err); return NO; }
    NSDictionary *os = @{
        AVVideoCodecKey: AVVideoCodecTypeHEVC,
        AVVideoWidthKey: @((int)gVideoSize.width),
        AVVideoHeightKey: @((int)gVideoSize.height),
        AVVideoCompressionPropertiesKey: @{ AVVideoAverageBitRateKey: @(1024*1024),
                                            AVVideoExpectedSourceFrameRateKey: @(30) }
    };
    gInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:os];
    gInput.expectsMediaDataInRealTime = YES;
    gAdaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:gInput
        sourcePixelBufferAttributes:@{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey: @((int)gVideoSize.width),
            (id)kCVPixelBufferHeightKey: @((int)gVideoSize.height)
        }];
    [gWriter addInput:gInput];
    if (![gWriter startWriting]) { NSLog(@"[GRV4] startWriting 失败"); return NO; }
    [gWriter startSessionAtSourceTime:kCMTimeZero];
    gFrameCount = 0;
    gStartTime = CACurrentMediaTime();
    gNeedInit = NO;
    NSLog(@"[GRV4] 尺寸 %.0fx%.0f", gVideoSize.width, gVideoSize.height);
    return YES;
}

static void writerWritePixelBuffer(CVPixelBufferRef pb) {
    if (!gInput.isReadyForMoreMediaData) return;
    double now = CACurrentMediaTime();
    CMTime pts = CMTimeMakeWithSeconds(now - gStartTime, 600);
    gFrameCount++;
    if ((gFrameCount % 60) == 0 && gTexCache) CVMetalTextureCacheFlush(gTexCache, 0);
    // 版本4核心：每帧读进程内存，逼近阈值就开节流
    mach_task_basic_info bi; mach_msg_type_number_t cnt = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&bi, &cnt) == KERN_SUCCESS) {
        gMemKB = (long)(bi.resident_size / 1024);
        if (gMemKB > gMemLimitKB) gThrottle = 1;
    }
    [gAdaptor appendPixelBuffer:pb withPresentationTime:pts];
}

static void captureDrawable(id<CAMetalDrawable> drawable) {
    if (!drawable.texture) return;
    // 版本4：内存逼近阈值时降采样（每 4 帧才抓 1 帧 ≈ 降到 ~7fps，大幅减负载）
    if (gThrottle && (++gThrottleSkip % 4 != 0)) return;
    if (gNeedInit) {
        if (!initWriterFromSize(CGSizeMake(drawable.texture.width, drawable.texture.height))) return;
    }
    if (!gInput || !gInput.isReadyForMoreMediaData || !gAdaptor) return;
    if (!gDevice || !gTexCache) return;
    if (__sync_fetch_and_add(&gInflightBlits, 1) >= 2) {
        __sync_fetch_and_sub(&gInflightBlits, 1);
        return;
    }
    CVPixelBufferRef pb = NULL;
    NSDictionary *aux = @{ (id)CFSTR("CVPixelBufferPoolAllocationFailurePolicy"): @(2) };
    CVReturn cv = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(NULL, gAdaptor.pixelBufferPool,
                                            (__bridge CFDictionaryRef)aux, &pb);
    if (cv != kCVReturnSuccess || !pb) { __sync_fetch_and_sub(&gInflightBlits, 1); return; }
    CVMetalTextureRef mt = NULL;
    size_t w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb);
    MTLPixelFormat targetFmt = (drawable.texture.pixelFormat == MTLPixelFormatBGRA8Unorm_sRGB)
                               ? MTLPixelFormatBGRA8Unorm_sRGB : MTLPixelFormatBGRA8Unorm;
    CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, gTexCache, pb, NULL, targetFmt, w, h, 0, &mt);
    id<MTLTexture> target = mt ? CVMetalTextureGetTexture(mt) : nil;
    if (!target) { if (mt) CFRelease(mt); CVPixelBufferRelease(pb); __sync_fetch_and_sub(&gInflightBlits, 1); return; }
    CVPixelBufferRetain(pb);
    id<MTLCommandBuffer> cb = [gQueue commandBuffer];
    if (gScaler) {
        [gScaler encodeToCommandBuffer:cb sourceTexture:drawable.texture destinationTexture:target];
    } else {
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit copyFromTexture:drawable.texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
                  sourceSize:MTLSizeMake(drawable.texture.width, drawable.texture.height, 1)
                  toTexture:target destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
        [blit endEncoding];
    }
    [cb addCompletedHandler:^(id<MTLCommandBuffer> b){
        dispatch_async(gWriteQ, ^{
            writerWritePixelBuffer(pb);
            __sync_fetch_and_sub(&gInflightBlits, 1);
            CVPixelBufferRelease(pb);
        });
    }];
    [cb commit];
    if (mt) CFRelease(mt);
}

static void startRecording(void) {
    if (gRecording) return;
    if (!gGameLayer) gGameLayer = findGameLayer();
    if (!gGameLayer) {
        UIAlertController *al = [UIAlertController alertControllerWithTitle:@"GameRecorderV4" message:@"未找到游戏画面" preferredStyle:UIAlertControllerStyleAlert];
        [al addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [topViewController() presentViewController:al animated:YES completion:nil];
        return;
    }
    gRecording = YES; gNeedInit = YES; gFrameSkip = 0; gThrottle = 0; gThrottleSkip = 0;
    NSLog(@"[GRV4] 开始录制 (内存限 %.0fMB)", gMemLimitKB/1024.0);
    dispatch_async(dispatch_get_main_queue(), ^{ [gBtnLabel setTitle:@"■" forState:UIControlStateNormal]; });
}

static void showShareForURL(NSURL *url) {
    UIActivityViewController *ac = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    ac.popoverPresentationController.sourceView = gBtn;
    dispatch_async(dispatch_get_main_queue(), ^{ [topViewController() presentViewController:ac animated:YES completion:nil]; });
}

static void stopRecording(void) {
    if (!gRecording) return;
    gRecording = NO;
    if (!gAdaptor) { NSLog(@"[GRV4] 未写入即停"); return; }
    [gInput markAsFinished];
    AVAssetWriter *w = gWriter; NSURL *url = gOutURL;
    [w finishWritingWithCompletionHandler:^{
        if (w.status != AVAssetWriterStatusCompleted) { NSLog(@"[GRV4] 未完成 %ld", (long)w.status); return; }
        NSLog(@"[GRV4] 完成 %@", url.path);
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:url];
        } completionHandler:^(BOOL ok, NSError *err) { showShareForURL(url); }];
    }];
    dispatch_async(dispatch_get_main_queue(), ^{ [gBtnLabel setTitle:@"●" forState:UIControlStateNormal]; });
}

static id hook_nextDrawable(id self, SEL sel) {
    id d = orig_nextDrawable(self, sel);
    if (gRecording && self == gGameLayer) {
        if (++gFrameSkip % 2 == 0 && prevGameDrawable) captureDrawable(prevGameDrawable);
        prevGameDrawable = d;
    }
    return d;
}

@interface GameRecorderController : NSObject
- (void)btnTapped;
- (void)btnPanned:(UIPanGestureRecognizer *)gr;
@end
@implementation GameRecorderController
- (void)btnTapped { if (gRecording) stopRecording(); else startRecording(); }
- (void)btnPanned:(UIPanGestureRecognizer *)gr {
    UIView *b = gr.view; const CGFloat half = 28;
    if (gr.state == UIGestureRecognizerStateBegan || gr.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [gr translationInView:b.superview];
        b.center = CGPointMake(b.center.x + t.x, b.center.y + t.y);
        [gr setTranslation:CGPointZero inView:b.superview];
        CGRect sv = b.superview.bounds; CGPoint c = b.center;
        if (sv.size.width > 0) c.x = MAX(half, MIN(sv.size.width - half, c.x));
        if (sv.size.height > 0) c.y = MAX(half, MIN(sv.size.height - half, c.y));
        b.center = c;
    } else if (gr.state == UIGestureRecognizerStateEnded) {
        CGRect f = gBtnWindow.frame; f.origin.x = b.center.x - half; f.origin.y = b.center.y - half; gBtnWindow.frame = f;
    }
}
@end
static GameRecorderController *gCtrl;

static void setupButton(void) {
    CGFloat x = 40, y = 300;
    gBtnWindow = [[UIWindow alloc] initWithFrame:CGRectMake(x, y, 56, 56)];
    gBtnWindow.windowLevel = UIWindowLevelStatusBar + 400;
    gBtnWindow.backgroundColor = [UIColor clearColor]; gBtnWindow.userInteractionEnabled = YES;
    gBtn = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 56, 56)];
    gBtn.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
    gBtn.layer.cornerRadius = 28; gBtn.layer.borderColor = [UIColor whiteColor].CGColor; gBtn.layer.borderWidth = 1;
    gBtn.userInteractionEnabled = YES;
    gBtnLabel = [UIButton buttonWithType:UIButtonTypeSystem]; gBtnLabel.frame = gBtn.bounds;
    [gBtnLabel setTitle:@"●" forState:UIControlStateNormal]; gBtnLabel.titleLabel.font = [UIFont systemFontOfSize:26]; gBtnLabel.tintColor = [UIColor redColor];
    gCtrl = [GameRecorderController new];
    [gBtnLabel addTarget:gCtrl action:@selector(btnTapped) forControlEvents:UIControlEventTouchUpInside];
    [gBtn addSubview:gBtnLabel];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:gCtrl action:@selector(btnPanned:)];
    [gBtn addGestureRecognizer:pan];
    UIViewController *vc = [UIViewController new]; vc.view = gBtn;
    gBtnWindow.rootViewController = vc; gBtnWindow.hidden = NO; [gBtnWindow makeKeyAndVisible];
}

__attribute__((constructor)) static void ctor(void) {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (![bid isEqualToString:@"com.ScarletWork.CounterFlame"]) { NSLog(@"[GRV4] 非目标 %@", bid); return; }
        NSLog(@"[GRV4] ✅ 注入 %@", bid);
        gDevice = MTLCreateSystemDefaultDevice();
        gQueue = [gDevice newCommandQueue];
        CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, gDevice, NULL, &gTexCache);
        gWriteQ = dispatch_queue_create("GameRecorderV4Write", DISPATCH_QUEUE_SERIAL);
        Method m1 = class_getInstanceMethod([CAMetalLayer class], @selector(nextDrawable));
        if (m1) orig_nextDrawable = (id(*)(id,SEL))method_getImplementation(m1);
        if (m1) method_setImplementation(m1, (IMP)hook_nextDrawable);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            gGameLayer = findGameLayer();
            NSLog(@"[GRV4] layer %@", gGameLayer);
            setupButton();
        });
    }
}
