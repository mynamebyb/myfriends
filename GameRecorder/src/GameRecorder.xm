//
//  GameRecorder.xm — CounterFlame 游戏画面录制器（standalone 注入 dylib）
//
//  版本：inline hook 版 · dlsym 拿 ElleKit 的 MSHookFunction，改 AudioUnitSetProperty 开头指令
//  不碰 GOT（fishhook 在 LC 下必崩），旁路包 render callback 拷 PCM，游戏内仍正常出声
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
#import <dlfcn.h>

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
static NSURL *gOutURL;
static NSInteger gFrameCount;
static CGSize gVideoSize;
static double gStartTime;
static int gFrameSkip;
static int gInflightBlits;

static AURenderCallback gOrigRenderCallback = NULL;
static void *gOrigRenderUserData = NULL;
static AudioStreamBasicDescription gAudioASBD;
static BOOL gAudioHookInstalled = NO;

static CAMetalLayer *gGameLayer;
static id prevGameDrawable;

static UIWindow *gBtnWindow;
static UIView *gBtn;
static UIButton *gBtnLabel;

static id (*orig_nextDrawable)(id, SEL);
static OSStatus (*orig_AudioUnitSetProperty)(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, const void *, UInt32);

#pragma mark - 顶部视图控制器

static UIViewController *topViewController(void) {
    UIWindow *kw = [UIApplication sharedApplication].keyWindow;
    UIViewController *vc = kw.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

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

#pragma mark - 音频 tap

static void enqueueAudioPCM(const AudioBufferList *abl, UInt32 inNumberFrames) {
    if (!gRecording || !gAudioInput || !gAudioInput.readyForMoreMediaData) return;
    if (!abl || abl->mNumberBuffers == 0) return;

    double now = CACurrentMediaTime();
    CMTime pts = CMTimeMakeWithSeconds(now - gStartTime, 100000);

    AudioStreamBasicDescription asbd = gAudioASBD;
    CMFormatDescriptionRef fmt = NULL;
    CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &asbd, 0, NULL, 0, NULL, NULL, &fmt);
    if (!fmt) return;

    CMSampleTimingInfo timing;
    timing.presentationTimeStamp = pts;
    timing.duration = CMTimeMake(inNumberFrames, asbd.mSampleRate);
    timing.decodeTimeStamp = kCMTimeInvalid;

    CMSampleBufferRef sb = NULL;
    size_t bytes = abl->mBuffers[0].mDataByteSize;
    OSStatus s = CMSampleBufferCreate(kCFAllocatorDefault, NULL, YES, NULL, NULL, fmt,
                                      inNumberFrames, 1, &timing, 0, NULL, &sb);
    if (s == noErr && sb) {
        CMBlockBufferRef blk = NULL;
        CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault,
                                           abl->mBuffers[0].mData,
                                           bytes, kCFAllocatorNull, NULL, 0, bytes, 0, &blk);
        if (blk) {
            CMSampleBufferSetDataBuffer(sb, blk);
            [gAudioInput appendSampleBuffer:sb];
            CFRelease(blk);
        }
        CFRelease(sb);
    }
    CFRelease(fmt);
}

static OSStatus tapRenderCallback(void *inRefCon,
                                   AudioUnitRenderActionFlags *ioActionFlags,
                                   const AudioTimeStamp *inTimeStamp,
                                   UInt32 inBusNumber,
                                   UInt32 inNumberFrames,
                                   AudioBufferList *ioData) {
    OSStatus st = gOrigRenderCallback(gOrigRenderUserData, ioActionFlags, inTimeStamp,
                                      inBusNumber, inNumberFrames, ioData);
    if (st == noErr && gRecording) {
        enqueueAudioPCM(ioData, inNumberFrames);
    }
    return st;
}

static OSStatus hook_AudioUnitSetProperty(AudioUnit inUnit,
                                          AudioUnitPropertyID inID,
                                          AudioUnitScope inScope,
                                          AudioUnitElement inElement,
                                          const void *inData,
                                          UInt32 inDataSize) {
    if (inID == kAudioUnitProperty_StreamFormat && inScope == kAudioUnitScope_Input &&
        inDataSize == sizeof(AudioStreamBasicDescription)) {
        memcpy(&gAudioASBD, inData, sizeof(AudioStreamBasicDescription));
        NSLog(@"[GameRecorder] 记录音频格式 %uHz %uch",
              (unsigned)gAudioASBD.mSampleRate, (unsigned)gAudioASBD.mChannelsPerFrame);
    }
    if (inID == kAudioUnitProperty_SetRenderCallback && inScope == kAudioUnitScope_Input &&
        inDataSize == sizeof(AURenderCallbackStruct) && !gAudioHookInstalled) {
        const AURenderCallbackStruct *cb = (const AURenderCallbackStruct *)inData;
        if (cb && cb->inputProc && cb->inputProc != tapRenderCallback) {
            gOrigRenderCallback = cb->inputProc;
            gOrigRenderUserData = cb->inputProcRefCon;
            gAudioHookInstalled = YES;

            AURenderCallbackStruct wrapped;
            wrapped.inputProc = tapRenderCallback;
            wrapped.inputProcRefCon = gOrigRenderUserData;

            NSLog(@"[GameRecorder] 已 hook 游戏 render callback: %p", cb->inputProc);
            return orig_AudioUnitSetProperty(inUnit, inID, inScope, inElement, &wrapped, sizeof(wrapped));
        }
    }
    return orig_AudioUnitSetProperty(inUnit, inID, inScope, inElement, inData, inDataSize);
}

#pragma mark - inline hook（ElleKit MSHookFunction，不静态依赖）

typedef void (*MSHookFunction_t)(void *symbol, void *replace, void **result);

static void installAudioInlineHook(void) {
    MSHookFunction_t msHook = (MSHookFunction_t)dlsym(RTLD_DEFAULT, "MSHookFunction");
    if (!msHook) msHook = (MSHookFunction_t)dlsym(RTLD_DEFAULT, "_MSHookFunction");
    if (!msHook) {
        NSLog(@"[GameRecorder] ✗ 进程内未找到 MSHookFunction（ElleKit 未加载？），音频 hook 跳过");
        return;
    }
    void *target = dlsym(RTLD_DEFAULT, "AudioUnitSetProperty");
    if (!target) { NSLog(@"[GameRecorder] ✗ dlsym AudioUnitSetProperty 失败"); return; }
    msHook(target, (void *)hook_AudioUnitSetProperty, (void **)&orig_AudioUnitSetProperty);
    NSLog(@"[GameRecorder] ✓ inline hook AudioUnitSetProperty 已装 (MSHookFunction=%p)", msHook);
}

#pragma mark - writer

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

    if (gAudioHookInstalled) {
        UInt32 sr = gAudioASBD.mSampleRate > 0 ? gAudioASBD.mSampleRate : 44100;
        UInt32 ch = gAudioASBD.mChannelsPerFrame > 0 ? gAudioASBD.mChannelsPerFrame : 2;
        NSDictionary *ao = @{
            AVFormatIDKey: @(kAudioFormatMPEG4AAC),
            AVSampleRateKey: @(sr),
            AVNumberOfChannelsKey: @(ch),
            AVEncoderBitRateKey: @(128000)
        };
        gAudioInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:ao];
        gAudioInput.expectsMediaDataInRealTime = YES;
        [gWriter addInput:gAudioInput];
        NSLog(@"[GameRecorder] 音频轨已挂 %uHz %uch", (unsigned)sr, (unsigned)ch);
    }

    if (![gWriter startWriting]) { NSLog(@"[GameRecorder] startWriting 失败"); return NO; }
    [gWriter startSessionAtSourceTime:kCMTimeZero];
    gFrameCount = 0;
    gStartTime = CACurrentMediaTime();
    gNeedInit = NO;
    NSLog(@"[GameRecorder] 录制 %.0fx%.0f 60fps%@", gVideoSize.width, gVideoSize.height,
          gAudioInput ? @"+AAC" : @"(无音频轨)");
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

static void saveToPhotos(NSURL *url) {
    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
        [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:url];
    } completionHandler:^(BOOL ok, NSError *err) {
        NSLog(@"[GameRecorder] %@ 存相册 %@", url.lastPathComponent,
              ok ? @"成功" : [NSString stringWithFormat:@"失败 %@", err]);
    }];
}

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
    NSLog(@"[GameRecorder] 开始录制（inline hook，音频hook=%d）", gAudioHookInstalled);
    dispatch_async(dispatch_get_main_queue(), ^{ [gBtnLabel setTitle:@"■" forState:UIControlStateNormal]; });
}

static void stopRecording(void) {
    if (!gRecording) return;
    gRecording = NO;
    prevGameDrawable = nil;
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

static void trySetupUI(void) {
    if (gBtnWindow) return;
    if (!gGameLayer) gGameLayer = findGameLayer();
    if (!gGameLayer) return;
    UIApplication *app = [UIApplication sharedApplication];
    if (!app || (app.keyWindow == nil && app.windows.count == 0)) return;
    setupButton();
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
        NSLog(@"[GameRecorder] ✅ 已注入 %@（inline hook 版）", bid);

        gDevice = MTLCreateSystemDefaultDevice();
        gQueue = [gDevice newCommandQueue];
        CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, gDevice, NULL, &gTexCache);
        gWriteQ = dispatch_queue_create("GameRecorderWrite", DISPATCH_QUEUE_SERIAL);

        // 音频 inline hook（改指令，不碰 GOT，可在启动早期安全执行）
        installAudioInlineHook();

        Method m1 = class_getInstanceMethod([CAMetalLayer class], @selector(nextDrawable));
        if (m1) orig_nextDrawable = (id(*)(id,SEL))method_getImplementation(m1);
        if (m1) method_setImplementation(m1, (IMP)hook_nextDrawable);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            GameRecorder_poll();
        });
    }
}
