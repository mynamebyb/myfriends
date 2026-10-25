//
//  HideLabelOnRecord.xm — standalone 注入 dylib
//
//  功能：隐藏「贝总 U3D 工具 / U3D通杀工具」用 Dear ImGui 绘制的界面（物体名、方框、射线等）。
//  原理：hook 它导出符号 ImGui_ImplMetal_RenderDrawData —— 这是把 ImGui draw data 提交到
//       屏幕（Metal 后端）的最后一步。录屏时跳过该函数，则整个 ImGui 界面不渲染，
//       游戏本体画面（不经 ImGui）完全保留。
//
//  注入：LiveContainer + ElleKit / Sideloadly 重签名。
//  hook 用 dlsym("MSHookFunction")（ElleKit substrate 兼容层），不静态链接 substrate。
//
//  【当前为测试版】FORCE_BLOCK_ALL=1，永久拦截（不判断录屏），验证路线。
//  验证通过后把 FORCE_BLOCK_ALL 改回 0，即恢复「录屏时隐藏、正常游玩显示」。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/message.h>

#pragma mark - 测试开关

// =1：永久拦截（验证贝总工具是否真走 ImGui Metal）；=0：仅录屏时拦截
#define FORCE_BLOCK_ALL 1

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
#if FORCE_BLOCK_ALL
    // 【测试版】永久跳过 ImGui 渲染，验证贝总工具是否走这条路
    return;
#endif
    if (IsCapturedNow()) {
        // 正在录屏 → 跳过 ImGui 提交，贝总界面消失，游戏画面保留
        return;
    }
    orig_RenderDrawData(drawData, cmdBuffer, cmdEncoder);
}

#pragma mark - 加载入口

__attribute__((constructor)) static void HideLabelOnRecord_ctor(void)
{
    @autoreleasepool {
        MSHookFunction_fn = (void(*)(void*, void*, void**))dlsym(RTLD_DEFAULT, "MSHookFunction");
        if (!MSHookFunction_fn) {
            NSLog(@"[hideonrecord] MSHookFunction 不可用（ElleKit 未开）");
            return;
        }

        // U3D通杀工具 导出的 ImGui Metal 渲染提交函数（mangled 名）
        const char *sym = "_Z30ImGui_ImplMetal_RenderDrawDataP10ImDrawDataPU27objcproto16MTLCommandBuffer11objc_objectPU34objcproto23MTLRenderCommandEncoder11objc_object";
        void *target = dlsym(RTLD_DEFAULT, sym);
        if (!target) {
            NSLog(@"[hideonrecord] 未找到 ImGui_ImplMetal_RenderDrawData 符号");
            return;
        }

        MSHookFunction_fn(target, (void *)&hook_RenderDrawData, (void **)&orig_RenderDrawData);
        NSLog(@"[hideonrecord] ✅ 已 hook ImGui_ImplMetal_RenderDrawData（%@）",
              FORCE_BLOCK_ALL ? @"测试版·永久拦截" : @"录屏时隐藏");
    }
}
