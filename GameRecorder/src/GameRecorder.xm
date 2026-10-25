//
//  GameRecorder.xm — CounterFlame 游戏画面录制器（standalone 注入 dylib）
//
//  版本：修复 pixel-buffer 引用计数泄漏 · 720p / ~30fps / 3Mbps · 每 15 秒按真实时间分段
//  关键修复：去掉 capture 里多余的 CVPixelBufferRetain，让 buffer 正确归还像素池复用
//           （消除每帧新建 IOSurface 的线性内存泄漏，录完内存可回退）
//
//  注入：LiveContainer / Sideloadly / nbtool 重签名
//  目标：com.ScarletWork.CounterFlame
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

#pragma mark - 全局状态

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
static double gSegmentStart;
static int gFrameSkip;
static int gInflightBlits;

// 分段录制状态：每 15 秒一段（按真实时间）
static int gSegIndex = 0;
static int gNeedNewSegment = 0;
static const double gSegmentDuration = 15.0;

static CAMetalLayer *gGameLayer;
static id prevGameDrawable;

static UIWindow *gBtnWindow;
static UIView *gBtn;
static UIButton *gBtnLabel;

static id (*orig_nextDrawable)(id, SEL);

#pragma mark - 顶部视图控制器

static UIViewController *topViewController(void) {
    UIWindow *kw = [UIApplication sharedApplication].keyWindow;
    UIViewController *vc = kw.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

#pragma mark - 查找游戏主 layer

static CAMetalLayer *findGameLayer(void) {
    CAMetalLayer *best = nil;
    CGFloat bestArea = 0;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.hidden) continue;
        UIView *rv = w.rootViewController.view;
        if (!rv) continue;
        NSMutableArray *stack = [NSMutableArray arrayWithObject:rv];
        while (stack.count) {
            UIView *cur = stack.lastObject;
            [stack removeLastObject];
            if ([cur.layer isKindOfClass:[CAMetalLayer class]]) {
                CGRect b = cur.bounds;
                CGFloat a = b.size.width * b.size.height;
                if (a > bestArea) { bestArea = a; best = (CAMetalLayer *)cur.layer; }
            }
            for (UIView *sv in cur.subviews) [stack addObject:sv];
        }
    }
    return best;
}

#pragma mark - 用输出尺寸初始化 writer（文件名带段号）

static BOOL initWriterWithSize(CGSize outSize) {
    if (outSize.width <= 0 || outSize.height <= 0) return NO;
    gVideoSize = outSize;
    if (!gTexCache) CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, gDevice, NULL, &gTexCache);
    if (!gScaler) gScaler = [[MPSImageLanczosScale alloc] initWithDevice:gDevice];

    NSURL *tmp = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"rec_%03d_%ld.mp4", gSegIndex, (long)[NSDate date].timeIntervalSince1970]]];
    gOutURL = tmp;
    NSError *err = nil;
    gWriter = [AVAssetWriter assetWriterWithURL:tmp fileType:AVFileTypeMPEG4 error:&err];
    if (!gWriter) { NSLog(@"[GameRecorder] writer 创建失败 %@", err); return NO; }
    NSDictionary *os = @{
        AVVideoCodecKey: AVVideoCodecTypeHEVC,
        AVVideoWidthKey: @((int)gVideoSize.width),
        AVVideoHeightKey: @((int)gVideoSize.height),
        AVVideoCompressionPropertiesKey: @{ AVVideoAverageBitRateKey: @(3 * 1024 * 1024),  // 3Mbps
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
    if (![gWriter startWriting]) { NSLog(@"[GameRecorder] startWriting 失败"); return NO; }
    [gWriter startSessionAtSourceTime:kCMTimeZero];
    gFrameCount = 0;
    gStartTime = CACurrentMediaTime();
    gSegmentStart = gStartTime;
    gNeedInit = NO;
    NSLog(@"[GameRecorder] 段 %d 尺寸 %.0fx%.0f 30fps", gSegIndex, gVideoSize.width, gVideoSize.height);
    return YES;
}

// 从源纹理尺寸算出输出尺寸（压到 720 宽）再初始化
static BOOL initWriterFromTexSize(CGSize texSize) {
    if (texSize.width <= 0 || texSize.height <= 0) return NO;
    CGSize out = texSize;
    CGFloat targetW = 1280;
    if (out.width > targetW) {
        CGFloat ratio = targetW / out.width;
        out = CGSizeMake(targetW, (NSInteger)(out.height * ratio / 2) * 2);
    }
    return initWriterWithSize(out);
}

#pragma mark - 存相册（不再弹分享页）

static void saveToPhotos(NSURL *url) {
    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
        [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:url];
    } completionHandler:^(BOOL ok, NSError *err) {
        NSLog(@"[GameRecorder] 段 %@ 存相册 %@", url.lastPathComponent,
              ok ? @"成功" : [NSString stringWithFormat:@"失败 %@", err]);
    }];
}

// 在 gWriteQ 上重建新段 writer
static void startNewSegment(void) {
    dispatch_async(gWriteQ, ^{
        initWriterWithSize(gVideoSize);
        gNeedNewSegment = 0;
    });
}

// 结束当前段并存相册，延迟 0.8s 等编码器释放后再开新段
static void cutSegment(void) {
    if (!gInput) { gNeedNewSegment = 0; return; }
    gNeedNewSegment = 1;
    [gInput markAsFinished];
    AVAssetWriter *oldW = gWriter;
    NSURL *oldURL = gOutURL;
    gWriter = nil; gInput = nil; gAdaptor = nil;
    gSegIndex++;
    [oldW finishWritingWithCompletionHandler:^{
        if (oldW.status == AVAssetWriterStatusCompleted) {
            NSLog(@"[GameRecorder] 段 %ld 完成 %@", (long)(gSegIndex-1), oldURL.path);
            saveToPhotos(oldURL);
        } else {
            NSLog(@"[GameRecorder] 段 %ld 未完成 %ld", (long)(gSegIndex-1), (long)oldW.status);
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            startNewSegment();
        });
    }];
}

#pragma mark - 编码

static void writerWritePixelBuffer(CVPixelBufferRef pb) {
    if (!gInput || !gInput.isReadyForMoreMediaData) return;
    double now = CACurrentMediaTime();
    CMTime pts = CMTimeMakeWithSeconds(now - gStartTime, 600);
    [gAdaptor appendPixelBuffer:pb withPresentationTime:pts];
    gFrameCount++;
    // 按真实时间每满 15 秒切段（不依赖帧数）
    if (!gNeedNewSegment && (now - gSegmentStart) >= gSegmentDuration) {
        cutSegment();
    }
}

static void captureDrawable(id<CAMetalDrawable> drawable) {
    if (!drawable.texture) return;
    if (gNeedNewSegment) return;
    if (gNeedInit) {
        if (!initWriterFromTexSize(CGSizeMake(drawable.texture.width, drawable.texture.height))) return;
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

    // 不再额外 Retain pb：完成回调里 release 掉池返回的这个引用即可，buffer 归还池复用
    id<MTLCommandBuffer> cb = [gQueue commandBuffer];
    if (gScaler) {
        [gScaler encodeToCommandBuffer:cb sourceTexture:drawable.texture destinationTexture:target];
    } else {
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit copyFromTexture:drawable.texture
                  sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
                  sourceSize:MTLSizeMake(drawable.texture.width, drawable.texture.height, 1)
                  toTexture:target destinationSlice:0 destinationLevel:0
                  destinationOrigin:MTLOriginMake(0,0,0)];
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

#pragma mark - 开始 / 停止

static void startRecording(void) {
    if (gRecording) return;
    if (!gGameLayer) gGameLayer = findGameLayer();
    if (!gGameLayer) {
        UIAlertController *al = [UIAlertController alertControllerWithTitle:@"GameRecorder"
            message:@"未找到游戏画面" preferredStyle:UIAlertControllerStyleAlert];
        [al addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [topViewController() presentViewController:al animated:YES completion:nil];
        return;
    }
    gRecording = YES;
    gNeedInit = YES;
    gFrameSkip = 0;
    gSegIndex = 0;
    gNeedNewSegment = 0;
    NSLog(@"[GameRecorder] 开始录制（720p/30fps/3M/15s分段）");
    dispatch_async(dispatch_get_main_queue(), ^{ [gBtnLabel setTitle:@"■" forState:UIControlStateNormal]; });
}

static void stopRecording(void) {
    if (!gRecording) return;
    gRecording = NO;
    prevGameDrawable = nil;
    if (!gInput) { NSLog(@"[GameRecorder] 未开始写入即停止"); return; }
    [gInput markAsFinished];
    AVAssetWriter *w = gWriter;
    NSURL *url = gOutURL;
    gWriter = nil; gInput = nil; gAdaptor = nil;
    [w finishWritingWithCompletionHandler:^{
        if (w.status != AVAssetWriterStatusCompleted) {
            NSLog(@"[GameRecorder] 最后段未完成 %ld", (long)w.status);
            return;
        }
        NSLog(@"[GameRecorder] 最后段完成 %@", url.path);
        saveToPhotos(url);
    }];
    // 彻底清理录制资源，确保停止后内存回退
    if (gTexCache) { CFRelease(gTexCache); gTexCache = NULL; }
    gScaler = nil;
    dispatch_async(dispatch_get_main_queue(), ^{ [gBtnLabel setTitle:@"●" forState:UIControlStateNormal]; });
}

#pragma mark - Hook：捕获游戏画面（每 2 帧抓 1，~30fps）

static id hook_nextDrawable(id self, SEL sel) {
    id d = orig_nextDrawable(self, sel);
    if (gRecording && self == gGameLayer) {
        if (gFrameSkip++ % 2 == 0 && prevGameDrawable) {
            captureDrawable(prevGameDrawable);
        }
        prevGameDrawable = d;
    }
    return d;
}

#pragma mark - 悬浮按钮

@interface GameRecorderController : NSObject
- (void)btnTapped;
- (void)btnPanned:(UIPanGestureRecognizer *)gr;
@end
@implementation GameRecorderController
- (void)btnTapped {
    if (gRecording) stopRecording(); else startRecording();
}
- (void)btnPanned:(UIPanGestureRecognizer *)gr {
    UIView *b = gr.view;
    const CGFloat half = 28;
    if (gr.state == UIGestureRecognizerStateBegan || gr.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [gr translationInView:b.superview];
        b.center = CGPointMake(b.center.x + t.x, b.center.y + t.y);
        [gr setTranslation:CGPointZero inView:b.superview];
        CGRect sv = b.superview.bounds;
        CGPoint c = b.center;
        if (sv.size.width > 0) c.x = MAX(half, MIN(sv.size.width - half, c.x));
        if (sv.size.height > 0) c.y = MAX(half, MIN(sv.size.height - half, c.y));
        b.center = c;
    } else if (gr.state == UIGestureRecognizerStateEnded) {
        CGRect f = gBtnWindow.frame;
        f.origin.x = b.center.x - half;
        f.origin.y = b.center.y - half;
        gBtnWindow.frame = f;
    }
}
@end

static GameRecorderController *gCtrl;

static void setupButton(void) {
    CGFloat x = 40, y = 300;
    gBtnWindow = [[UIWindow alloc] initWithFrame:CGRectMake(x, y, 56, 56)];
    gBtnWindow.windowLevel = UIWindowLevelStatusBar + 400;
    gBtnWindow.backgroundColor = [UIColor clearColor];
    gBtnWindow.userInteractionEnabled = YES;

    gBtn = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 56, 56)];
    gBtn.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
    gBtn.layer.cornerRadius = 28;
    gBtn.layer.borderColor = [UIColor whiteColor].CGColor;
    gBtn.layer.borderWidth = 1;
    gBtn.userInteractionEnabled = YES;

    gBtnLabel = [UIButton buttonWithType:UIButtonTypeSystem];
    gBtnLabel.frame = gBtn.bounds;
    [gBtnLabel setTitle:@"●" forState:UIControlStateNormal];
    gBtnLabel.titleLabel.font = [UIFont systemFontOfSize:26];
    gBtnLabel.tintColor = [UIColor redColor];

    gCtrl = [GameRecorderController new];
    [gBtnLabel addTarget:gCtrl action:@selector(btnTapped) forControlEvents:UIControlEventTouchUpInside];
    [gBtn addSubview:gBtnLabel];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:gCtrl action:@selector(btnPanned:)];
    [gBtn addGestureRecognizer:pan];

    UIViewController *vc = [UIViewController new];
    vc.view = gBtn;
    gBtnWindow.rootViewController = vc;
    gBtnWindow.hidden = NO;
    [gBtnWindow makeKeyAndVisible];
}

#pragma mark - 轮询等 UI 就绪后再建悬浮按钮（静态函数，避免 block 递归 retain cycle）

static void trySetupUI(void) {
    if (gBtnWindow) return;
    if (!gGameLayer) gGameLayer = findGameLayer();
    if (!gGameLayer) return;
    UIApplication *app = [UIApplication sharedApplication];
    if (!app || (app.keyWindow == nil && app.windows.count == 0)) return;
    setupButton();
    if (gBtnWindow && !gBtnWindow.hidden) {
        NSLog(@"[GameRecorder] 悬浮按钮已创建，开始捕获");
    }
}

static void GameRecorder_poll(void) {
    static int tries = 0;
    tries++;
    trySetupUI();
    if (!gBtnWindow && tries < 60) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            GameRecorder_poll();
        });
    } else if (!gBtnWindow) {
        NSLog(@"[GameRecorder] 30s 内未建按钮（未找到游戏画面）");
    }
}

#pragma mark - 加载入口

__attribute__((constructor)) static void GameRecorder_ctor(void) {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (![bid isEqualToString:@"com.ScarletWork.CounterFlame"]) {
            NSLog(@"[GameRecorder] 非目标游戏 %@，跳过", bid);
            return;
        }
        NSLog(@"[GameRecorder] ✅ 已注入 %@（720p/30fps/3M/15s分段，修复pb泄漏）", bid);

        gDevice = MTLCreateSystemDefaultDevice();
        gQueue = [gDevice newCommandQueue];
        CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, gDevice, NULL, &gTexCache);
        gWriteQ = dispatch_queue_create("GameRecorderWrite", DISPATCH_QUEUE_SERIAL);

        Method m1 = class_getInstanceMethod([CAMetalLayer class], @selector(nextDrawable));
        if (m1) orig_nextDrawable = (id(*)(id,SEL))method_getImplementation(m1);
        if (m1) method_setImplementation(m1, (IMP)hook_nextDrawable);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            GameRecorder_poll();
        });
    }
}
