//
//  GameRecorder.xm — CounterFlame 游戏画面录制器（standalone 注入 dylib）
//
//  版本：音频捕获试做版 · 1080p/60fps/5M 画面 + AVAudioEngine outputNode tap 截 PCM 写音频轨
//  原理：起一个 AVAudioEngine，在 outputNode 上 installTap（旁路监听，不截流，扬声器照常出声），
//        把 PCM 转 CMSampleBuffer 喂给 writer 的 AAC 音频轨。不动全局 dyld 符号（区别于 fishhook）。
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
#import <AudioToolbox/AudioToolbox.h>
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
static AVAssetWriterInput *gAudioInput;
static AVAudioEngine *gAudioEngine;
static NSURL *gOutURL;
static NSInteger gFrameCount;
static CGSize gVideoSize;
static double gStartTime;
static int gFrameSkip;
static int gInflightBlits;

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

#pragma mark - 音频 tap 回调：把 PCM 转 CMSampleBuffer 喂给 writer 音频轨

static void appendAudioBuffer(AVAudioPCMBuffer *buf, AVAudioTime *when) {
    if (!gAudioInput || !gAudioInput.readyForMoreMediaData) return;
    if (!buf || buf.frameLength == 0) return;

    double now = CACurrentMediaTime();
    CMTime pts = CMTimeMakeWithSeconds(now - gStartTime, 100000);

    AudioStreamBasicDescription asbd = *buf.format.streamDescription;
    CMFormatDescriptionRef fmt = NULL;
    CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &asbd, 0, NULL, 0, NULL, NULL, &fmt);
    if (!fmt) return;

    CMSampleTimingInfo timing;
    timing.presentationTimeStamp = pts;
    timing.duration = CMTimeMake(buf.frameLength, buf.format.sampleRate);
    timing.decodeTimeStamp = kCMTimeInvalid;

    CMSampleBufferRef sb = NULL;
    OSStatus s = CMSampleBufferCreate(kCFAllocatorDefault, NULL, YES, NULL, NULL, fmt,
                                      buf.frameLength, 1, &timing, 0, NULL, &sb);
    if (s == noErr && sb) {
        AudioBufferList *abl = buf.mutableAudioBufferList;
        CMBlockBufferRef blk = NULL;
        CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault,
                                           abl->mBuffers[0].mData,
                                           abl->mBuffers[0].mDataByteSize,
                                           kCFAllocatorNull, NULL, 0,
                                           abl->mBuffers[0].mDataByteSize,
                                           0, &blk);
        if (blk) {
            CMSampleBufferSetDataBuffer(sb, blk);
            [gAudioInput appendSampleBuffer:sb];
            CFRelease(blk);
        }
        CFRelease(sb);
    }
    CFRelease(fmt);
}

#pragma mark - 用输出尺寸初始化 writer

static BOOL initWriterWithSize(CGSize outSize) {
    if (outSize.width <= 0 || outSize.height <= 0) return NO;
    gVideoSize = outSize;
    if (!gTexCache) CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, gDevice, NULL, &gTexCache);
    if (!gScaler) gScaler = [[MPSImageLanczosScale alloc] initWithDevice:gDevice];

    NSURL *tmp = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"rec_%ld.mp4", (long)[NSDate date].timeIntervalSince1970]]];
    gOutURL = tmp;
    NSError *err = nil;
    gWriter = [AVAssetWriter assetWriterWithURL:tmp fileType:AVFileTypeMPEG4 error:&err];
    if (!gWriter) { NSLog(@"[GameRecorder] writer 创建失败 %@", err); return NO; }
    // 视频轨
    NSDictionary *os = @{
        AVVideoCodecKey: AVVideoCodecTypeHEVC,
        AVVideoWidthKey: @((int)gVideoSize.width),
        AVVideoHeightKey: @((int)gVideoSize.height),
        AVVideoCompressionPropertiesKey: @{ AVVideoAverageBitRateKey: @(5 * 1024 * 1024),
                                            AVVideoExpectedSourceFrameRateKey: @(60) }
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
    // 音频轨（AAC）
    NSDictionary *ao = @{
        AVFormatIDKey: @(kAudioFormatMPEG4AAC),
        AVSampleRateKey: @(44100),
        AVNumberOfChannelsKey: @(2),
        AVEncoderBitRateKey: @(128000)
    };
    gAudioInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:ao];
    gAudioInput.expectsMediaDataInRealTime = YES;
    [gWriter addInput:gAudioInput];

    if (![gWriter startWriting]) { NSLog(@"[GameRecorder] startWriting 失败"); return NO; }
    [gWriter startSessionAtSourceTime:kCMTimeZero];
    gFrameCount = 0;
    gStartTime = CACurrentMediaTime();
    gNeedInit = NO;
    NSLog(@"[GameRecorder] 录制 %.0fx%.0f 60fps+AAC 单文件", gVideoSize.width, gVideoSize.height);
    return YES;
}

static BOOL initWriterFromTexSize(CGSize texSize) {
    if (texSize.width <= 0 || texSize.height <= 0) return NO;
    CGSize out = texSize;
    CGFloat targetH = 1080;
    if (out.height > targetH) {
        CGFloat ratio = targetH / out.height;
        out = CGSizeMake((NSInteger)(out.width * ratio / 2) * 2, targetH);
    }
    return initWriterWithSize(out);
}

#pragma mark - 存相册

static void saveToPhotos(NSURL *url) {
    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
        [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:url];
    } completionHandler:^(BOOL ok, NSError *err) {
        NSLog(@"[GameRecorder] %@ 存相册 %@", url.lastPathComponent,
              ok ? @"成功" : [NSString stringWithFormat:@"失败 %@", err]);
    }];
}

#pragma mark - 视频编码

static void writerWritePixelBuffer(CVPixelBufferRef pb) {
    if (!gInput || !gInput.isReadyForMoreMediaData) return;
    double now = CACurrentMediaTime();
    CMTime pts = CMTimeMakeWithSeconds(now - gStartTime, 600);
    [gAdaptor appendPixelBuffer:pb withPresentationTime:pts];
    gFrameCount++;
}

static void captureDrawable(id<CAMetalDrawable> drawable) {
    if (!drawable.texture) return;
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

#pragma mark - 音频引擎

static void startAudioTap(void) {
    NSError *e = nil;
    AVAudioSession *sess = [AVAudioSession sharedInstance];
    [sess setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:&e];
    if (e) NSLog(@"[GameRecorder] audio session category err %@", e);
    [sess setActive:YES error:&e];
    if (e) NSLog(@"[GameRecorder] audio session active err %@", e);

    gAudioEngine = [[AVAudioEngine alloc] init];
    AVAudioOutputNode *out = gAudioEngine.outputNode;
    AVAudioFormat *fmt = [out outputFormatForBus:0];
    [out removeTapOnBus:0];
    [out installTapOnBus:0 bufferSize:1024 format:fmt block:^(AVAudioPCMBuffer *buf, AVAudioTime *when) {
        appendAudioBuffer(buf, when);
    }];
    [gAudioEngine startAndReturnError:&e];
    if (e) NSLog(@"[GameRecorder] audio engine start err %@", e);
    else NSLog(@"[GameRecorder] 音频 tap 已挂 outputNode");
}

static void stopAudioTap(void) {
    @try {
        [gAudioEngine.outputNode removeTapOnBus:0];
        [gAudioEngine stop];
    } @catch (NSException *e) {
        NSLog(@"[GameRecorder] stopAudioTap %@", e);
    }
    gAudioEngine = nil;
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
    startAudioTap();
    NSLog(@"[GameRecorder] 开始录制（1080p/60fps/5M+AAC）");
    dispatch_async(dispatch_get_main_queue(), ^{ [gBtnLabel setTitle:@"■" forState:UIControlStateNormal]; });
}

static void stopRecording(void) {
    if (!gRecording) return;
    gRecording = NO;
    prevGameDrawable = nil;
    stopAudioTap();
    if (!gInput) { NSLog(@"[GameRecorder] 未开始写入即停止"); return; }
    [gInput markAsFinished];
    if (gAudioInput) [gAudioInput markAsFinished];
    AVAssetWriter *w = gWriter;
    NSURL *url = gOutURL;
    gWriter = nil; gInput = nil; gAdaptor = nil; gAudioInput = nil;
    [w finishWritingWithCompletionHandler:^{
        if (w.status != AVAssetWriterStatusCompleted) {
            NSLog(@"[GameRecorder] 录制未完成 %ld", (long)w.status);
            return;
        }
        NSLog(@"[GameRecorder] 录制完成 %@", url.path);
        saveToPhotos(url);
    }];
    if (gTexCache) { CFRelease(gTexCache); gTexCache = NULL; }
    gScaler = nil;
    dispatch_async(dispatch_get_main_queue(), ^{ [gBtnLabel setTitle:@"●" forState:UIControlStateNormal]; });
}

#pragma mark - Hook

static id hook_nextDrawable(id self, SEL sel) {
    id d = orig_nextDrawable(self, sel);
    if (gRecording && self == gGameLayer) {
        if (gFrameSkip++ % 1 == 0 && prevGameDrawable) {
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

#pragma mark - 轮询建按钮

static void trySetupUI(void) {
    if (gBtnWindow) return;
    if (!gGameLayer) gGameLayer = findGameLayer();
    if (!gGameLayer) return;
    UIApplication *app = [UIApplication sharedApplication];
    if (!app || (app.keyWindow == nil && app.windows.count == 0)) return;
    setupButton();
    if (gBtnWindow && !gBtnWindow.hidden) {
        NSLog(@"[GameRecorder] 悬浮按钮已创建");
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
        NSLog(@"[GameRecorder] 30s 内未建按钮");
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
        NSLog(@"[GameRecorder] ✅ 已注入 %@（1080p/60fps/5M+AAC tap 版）", bid);

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
