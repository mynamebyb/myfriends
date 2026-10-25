//
//  HideLabelOnRecord.xm — standalone 注入 dylib
//
//  功能：隐藏「贝总 U3D 工具 / U3D通杀工具」用 Dear ImGui 绘制的界面（物体名、方框、射线等）。
//  原理：hook 它导出符号 ImGui_ImplMetal_RenderDrawData —— 把 ImGui draw data 提交到屏幕（Metal 后端）的最后一步。
//
//  注入：LiveContainer + ElleKit / Sideloadly 重签名。
//  hook 复用贝总工具自带的 Dobby 引擎（dlsym "DobbyHook"）。
//
//  隐藏方式：录屏时清空 ImDrawData（CmdListsCount/TotalVtxCount/TotalIdxCount）后仍调用原函数，
//  而非直接 return —— 避免 Metal 提交异常崩溃，同时使 ImGui 界面不渲染、游戏画面保留。
//
//  录屏状态：主线程每 0.5s 轮询写入全局 gCaptured（RenderDrawData 可能在渲染线程调用，读不到捕获状态）。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/message.h>

#pragma mark - Dobby hook（运行时解析，复用贝总工具自带 Dobby 引擎）

// Dobby 签名：int DobbyHook(void *address, void *replacement, void **origin);
typedef int (*DobbyHookFn)(void *, void *, void **);
static DobbyHookFn DobbyHook_fn;

#pragma mark - 录屏状态检测（主线程轮询）

static volatile bool gCaptured = false;

static bool IsCapturedNow(void)
{
    // iOS 11 ~ iOS 26：isCaptured
    if ([UIScreen mainScreen].isCaptured)
        return true;

    // iOS 27+：sceneCaptureState（运行时解析）
    UITraitCollection *tc = [UITraitCollection currentTraitCollection];
    SEL s = NSSelectorFromString(@"sceneCaptureState");
    if (tc && [tc respondsToSelector:s]) {
        NSInteger (*send)(id, SEL) = (NSInteger (*)(id, SEL))objc_msgSend;
        NSInteger state = send(tc, s);
        if (state != 0)   // != UISceneCaptureStateNone
            return true;
    }
    return false;
}

// 在主线程每 0.5s 轮询一次录屏状态，写入全局 gCaptured；hook（可能跑在渲染线程）读它
static void StartCapturedPoll(void)
{
    __block void (^poll)(void);
    poll = ^{
        gCaptured = IsCapturedNow();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), poll);
    };
    dispatch_async(dispatch_get_main_queue(), poll);
}

#pragma mark - Hook：ImGui_ImplMetal_RenderDrawData

// C++ 签名：void ImGui_ImplMetal_RenderDrawData(ImDrawData*, id<MTLCommandBuffer>, id<MTLRenderCommandEncoder>)
// 用 void* 泛化，避免依赖 Metal 头文件
typedef void (*RenderDrawDataFn)(void *, void *, void *);
static RenderDrawDataFn orig_RenderDrawData;

static void hook_RenderDrawData(void *drawData, void *cmdBuffer, void *cmdEncoder)
{
    if (gCaptured && drawData) {
        // 正在录屏：把 ImDrawData 清空后仍调用原函数（不直接 return，避免 Metal 提交空 command buffer 崩溃）。
        // ImDrawData 64 位布局：CmdListsCount@16, TotalVtxCount@20, TotalIdxCount@24。
        *(int *)((char *)drawData + 16) = 0;  // CmdListsCount
        *(int *)((char *)drawData + 20) = 0;  // TotalVtxCount
        *(int *)((char *)drawData + 24) = 0;  // TotalIdxCount
    }
    orig_RenderDrawData(drawData, cmdBuffer, cmdEncoder);
}

#pragma mark - 加载入口

__attribute__((constructor)) static void HideLabelOnRecord_ctor(void)
{
    @autoreleasepool {
        DobbyHook_fn = (DobbyHookFn)dlsym(RTLD_DEFAULT, "DobbyHook");
        if (!DobbyHook_fn) {
            NSLog(@"[hideonrecord] 未找到 DobbyHook（贝总工具未携带 Dobby？）");
            return;
        }

        const char *sym = "_Z30ImGui_ImplMetal_RenderDrawDataP10ImDrawDataPU27objcproto16MTLCommandBuffer11objc_objectPU34objcproto23MTLRenderCommandEncoder11objc_object";

        // 主线程轮询录屏状态（解决渲染线程读不到捕获状态的问题）
        StartCapturedPoll();

        // 延迟 5 秒再 hook，等贝总悬浮窗稳定运行后再打补丁。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            void *target = dlsym(RTLD_DEFAULT, sym);
            if (!target) {
                NSLog(@"[hideonrecord] 延迟 hook 失败：未找到 ImGui_ImplMetal_RenderDrawData 符号");
                return;
            }
            int rc = DobbyHook_fn(target, (void *)&hook_RenderDrawData, (void **)&orig_RenderDrawData);
            NSLog(@"[hideonrecord] ✅ Dobby hook ImGui_ImplMetal_RenderDrawData rc=%d（录屏时隐藏）", rc);
        });
    }
}
