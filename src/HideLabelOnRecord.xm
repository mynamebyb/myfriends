//
//  HideLabelOnRecord.xm — standalone 注入 dylib
//
//  功能：隐藏「贝总 U3D 工具 / U3D通杀工具」用 Dear ImGui 绘制的界面（物体名、方框、射线等）。
//  原理：hook 它导出符号 ImGui_ImplMetal_RenderDrawData —— 这是把 ImGui draw data 提交到
//       屏幕（Metal 后端）的最后一步。
//
//  注入：LiveContainer + ElleKit / Sideloadly 重签名。
//  hook 用 dlsym("MSHookFunction")（ElleKit substrate 兼容层），不静态链接 substrate。
//
//  隐藏方式：录屏时清空 ImDrawData（CmdListsCount/TotalVtxCount/TotalIdxCount）后仍调用原函数，
//  而非直接 return —— 避免 Metal 提交异常崩溃，同时使 ImGui 界面不渲染、游戏画面保留。
//
//  时机：延迟 20 秒 hook，避开启动画面与贝总悬浮窗首次渲染的临界点。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/message.h>

#pragma mark - MSHookFunction（运行时解析，ElleKit 提供）

static void (*MSHookFunction_fn)(void *symbol, void *replace, void **result);

#pragma mark - 录屏状态检测

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

#pragma mark - Hook：ImGui_ImplMetal_RenderDrawData

// C++ 签名：void ImGui_ImplMetal_RenderDrawData(ImDrawData*, id<MTLCommandBuffer>, id<MTLRenderCommandEncoder>)
// 用 void* 泛化，避免依赖 Metal 头文件
typedef void (*RenderDrawDataFn)(void *, void *, void *);
static RenderDrawDataFn orig_RenderDrawData;

static void hook_RenderDrawData(void *drawData, void *cmdBuffer, void *cmdEncoder)
{
    if (IsCapturedNow() && drawData) {
        // 正在录屏：把 ImDrawData 清空后仍调用原函数（不直接 return，避免 Metal 提交空 command buffer 崩溃）。
        // ImDrawData 64 位布局：CmdListsCount@16, TotalVtxCount@20, TotalIdxCount@24。
        *(int *)((char *)drawData + 16) = 0;  // CmdListsCount
        *(int *)((char *)drawData + 20) = 0;  // TotalVtxCount
        *(int *)((char *)drawData + 24) = 0;  // TotalIdxCount
    }
    orig_RenderDrawData(drawData, cmdBuffer, cmdEncoder);
}

#pragma mark - 加载入口（延迟 hook，避开启动期与贝总工具 Dobby 初始化冲突）

__attribute__((constructor)) static void HideLabelOnRecord_ctor(void)
{
    @autoreleasepool {
        MSHookFunction_fn = (void(*)(void*, void*, void**))dlsym(RTLD_DEFAULT, "MSHookFunction");
        if (!MSHookFunction_fn) {
            NSLog(@"[hideonrecord] MSHookFunction 不可用（ElleKit 未开）");
            return;
        }

        const char *sym = "_Z30ImGui_ImplMetal_RenderDrawDataP10ImDrawDataPU27objcproto16MTLCommandBuffer11objc_objectPU34objcproto23MTLRenderCommandEncoder11objc_object";

        // 延迟 20 秒再 hook：避开启动画面 + 贝总悬浮窗首次渲染的临界点；
        // 等贝总工具完全稳定运行后再打补丁，避免闪退。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            void *target = dlsym(RTLD_DEFAULT, sym);
            if (!target) {
                NSLog(@"[hideonrecord] 延迟 hook 失败：未找到 ImGui_ImplMetal_RenderDrawData 符号");
                return;
            }
            MSHookFunction_fn(target, (void *)&hook_RenderDrawData, (void **)&orig_RenderDrawData);
            NSLog(@"[hideonrecord] ✅ 已延迟 hook ImGui_ImplMetal_RenderDrawData（录屏时隐藏）");
        });
    }
}
