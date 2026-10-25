//
//  GameRecorder.xm — CounterFlame 游戏画面录制器（standalone 注入 dylib）
//
//  功能：
//   - 只录制游戏主画面（CAMetalLayer 的 drawable），贝总等独立 overlay 不在录制范围
//   - AVAssetWriter 硬编码 H.264，录完弹系统分享半屏（可存相册/文件），并默认存相册
//   - 悬浮按钮触发
//
//  注入：LiveContainer + ElleKit / Sideloadly 重签名。
//  目标：com.ScarletWork.CounterFlame
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
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
static dispatch_queue_t gWriteQ;  // 串行写队列，避免 AVAssetWriter 并发崩溃

static BOOL gRecording = NO;
static BOOL gNeedInit = NO;      // 等待第一帧 drawable 初始化 writer
static AVAssetWriter *gWriter;
static AVAssetWriterInput *gInput;
static AVAssetWriterInputPixelBufferAdaptor *gAdaptor;
static NSURL *gOutURL;
static NSInteger gFrameCount;
static CGSize gVideoSize;
static double gStartTime;  // 录制开始时间（真实时间戳，避免慢动作）
static int gFrameSkip;     // 限帧计数器（15fps）

static CAMetalLayer *gGameLayer;
static id prevGameDrawable;  // 上一帧游戏 drawable（已渲染完成，强引用保留待拷贝）

static UIWindow *gBtnWindow;
static UIView *gBtn;
static UIButton *gBtnLabel;

#pragma mark - hook 原 IMP

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
    UIWindow *kw = [UIApplication sharedApplication].keyWindow;
    UIView *v = kw.rootViewController.view;
    if (v && [v.layer isKindOfClass:[CAMetalLayer class]]) return (CAMetalLayer *)v.layer;
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

#pragma mark - 初始化录制（用 drawable.texture 真实尺寸，保证全屏）

static BOOL initWriterFromSize(CGSize texSize) {
    if (texSize.width <= 0 || texSize.height <= 0) return NO;
    gVideoSize = texSize;  // 输出尺寸 = 游戏真实渲染像素，blit 全屏对齐

    NSURL *tmp = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"rec_%ld.mp4", (long)[NSDate date].timeIntervalSince1970]]];
    gOutURL = tmp;
    NSError *err = nil;
    gWriter = [AVAssetWriter assetWriterWithURL:tmp fileType:AVFileTypeMPEG4 error:&err];
    if (!gWriter) { NSLog(@"[GameRecorder] writer 创建失败 %@", err); return NO; }
    NSDictionary *os = @{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @((int)gVideoSize.width),
        AVVideoHeightKey: @((int)gVideoSize.height),
        AVVideoCompressionPropertiesKey: @{ AVVideoAverageBitRateKey: @(4 * 1024 * 1024),
                                            AVVideoExpectedSourceFrameRateKey: @(15) }
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
    gNeedInit = NO;
    NSLog(@"[GameRecorder] 已用尺寸 %.0fx%.0f 初始化", gVideoSize.width, gVideoSize.height);
    return YES;
}

#pragma mark - 编码

static void writerWritePixelBuffer(CVPixelBufferRef pb) {
    if (!gInput.isReadyForMoreMediaData) return;
    double now = CACurrentMediaTime();
    CMTime pts = CMTimeMakeWithSeconds(now - gStartTime, 600);  // 真实时间戳，正常速度
    gFrameCount++;
    [gAdaptor appendPixelBuffer:pb withPresentationTime:pts];
}

static void captureDrawable(id<CAMetalDrawable> drawable) {
    if (!drawable.texture) return;
    // 第一帧用真实 texture 尺寸初始化
    if (gNeedInit) {
        if (!initWriterFromSize(CGSizeMake(drawable.texture.width, drawable.texture.height))) return;
    }
    if (!gInput || !gInput.isReadyForMoreMediaData || !gAdaptor) return;
    if (!gDevice || !gTexCache) return;

    CVPixelBufferRef pb = NULL;
    // 非阻塞取帧：pool 满时跳过该帧，绝不阻塞游戏渲染线程（否则卡顿/占用暴涨/闪退）
    // 私有 API 用字面量：key="CVPixelBufferPoolAllocationFailurePolicy"，值 2=Discard
    NSDictionary *aux = @{ (id)CFSTR("CVPixelBufferPoolAllocationFailurePolicy"): @(2) };
    CVReturn cv = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(NULL,
                                            gAdaptor.pixelBufferPool,
                                            (__bridge CFDictionaryRef)aux, &pb);
    if (cv != kCVReturnSuccess || !pb) return;

    CVMetalTextureRef mt = NULL;
    size_t w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb);
    CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, gTexCache, pb, NULL,
                                              MTLPixelFormatBGRA8Unorm, w, h, 0, &mt);
    id<MTLTexture> target = mt ? CVMetalTextureGetTexture(mt) : nil;
    if (!target) {
        if (mt) CFRelease(mt);
        CVPixelBufferRelease(pb);
        return;
    }
    CVPixelBufferRetain(pb);
    id<MTLCommandBuffer> cb = [gQueue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:drawable.texture
              sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
              sourceSize:MTLSizeMake(drawable.texture.width, drawable.texture.height, 1)
              toTexture:target destinationSlice:0 destinationLevel:0
              destinationOrigin:MTLOriginMake(0,0,0)];
    [blit endEncoding];
    [cb addCompletedHandler:^(id<MTLCommandBuffer> b){
        // 串行写，避免并发崩溃
        dispatch_async(gWriteQ, ^{
            writerWritePixelBuffer(pb);
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
        UIAlertController *al = [UIAlertController alertControllerWithTitle:@"GameRecorder"
            message:@"未找到游戏画面" preferredStyle:UIAlertControllerStyleAlert];
        [al addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [topViewController() presentViewController:al animated:YES completion:nil];
        return;
    }
    gRecording = YES;
    gNeedInit = YES;   // 等第一帧 drawable 拿到真实尺寸再建 writer
    gFrameSkip = 0;
    NSLog(@"[GameRecorder] 开始录制（等待第一帧初始化）");
    dispatch_async(dispatch_get_main_queue(), ^{ [gBtnLabel setTitle:@"■" forState:UIControlStateNormal]; });
}

static void showShareForURL(NSURL *url) {
    UIActivityViewController *ac = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    ac.popoverPresentationController.sourceView = gBtn;
    dispatch_async(dispatch_get_main_queue(), ^{
        [topViewController() presentViewController:ac animated:YES completion:nil];
    });
}

static void stopRecording(void) {
    if (!gRecording) return;
    gRecording = NO;
    if (!gAdaptor) {  // 还没开始写帧就停止
        NSLog(@"[GameRecorder] 未开始写入即停止");
        return;
    }
    [gInput markAsFinished];
    AVAssetWriter *w = gWriter;
    NSURL *url = gOutURL;
    [w finishWritingWithCompletionHandler:^{
        if (w.status != AVAssetWriterStatusCompleted) {
            NSLog(@"[GameRecorder] 录制未完成 status=%ld", (long)w.status);
            return;
        }
        NSLog(@"[GameRecorder] 录制完成 %@", url.path);
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:url];
        } completionHandler:^(BOOL ok, NSError *err) {
            NSLog(@"[GameRecorder] 存相册 %@", ok ? @"成功" : [NSString stringWithFormat:@"失败 %@", err]);
            showShareForURL(url);
        }];
    }];
    dispatch_async(dispatch_get_main_queue(), ^{ [gBtnLabel setTitle:@"●" forState:UIControlStateNormal]; });
}

#pragma mark - Hook：捕获游戏画面

static id hook_nextDrawable(id self, SEL sel) {
    id d = orig_nextDrawable(self, sel);
    if (gRecording && self == gGameLayer) {
        // 限帧：每 4 帧捕获一次（约 15fps），避免编码压力过大
        if (prevGameDrawable && (++gFrameSkip % 4 == 0)) {
            captureDrawable(prevGameDrawable);
        }
        prevGameDrawable = d;  // 强引用保留本帧，供下一帧拷贝
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
        // clamp 在屏幕内，防止滑出屏外找不到
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

static GameRecorderController *gCtrl;  // 强引用保住按钮回调 target（类型定义后声明）

static void setupButton(void) {
    // 固定初始位置（不保存拖动位置，避免按钮跑到屏幕外找不到）
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

#pragma mark - 加载入口

__attribute__((constructor)) static void GameRecorder_ctor(void) {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (![bid isEqualToString:@"com.ScarletWork.CounterFlame"]) {
            NSLog(@"[GameRecorder] 非目标游戏 %@，跳过", bid);
            return;
        }
        NSLog(@"[GameRecorder] ✅ 已注入 %@", bid);

        gDevice = MTLCreateSystemDefaultDevice();
        gQueue = [gDevice newCommandQueue];
        CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, gDevice, NULL, &gTexCache);
        gWriteQ = dispatch_queue_create("GameRecorderWrite", DISPATCH_QUEUE_SERIAL);

        // 保存原 IMP 后 swizzle（只 hook nextDrawable，延迟一帧拷贝）
        Method m1 = class_getInstanceMethod([CAMetalLayer class], @selector(nextDrawable));
        if (m1) orig_nextDrawable = (id(*)(id,SEL))method_getImplementation(m1);
        if (m1) method_setImplementation(m1, (IMP)hook_nextDrawable);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            gGameLayer = findGameLayer();
            NSLog(@"[GameRecorder] 游戏 layer %@", gGameLayer);
            setupButton();
        });
    }
}
