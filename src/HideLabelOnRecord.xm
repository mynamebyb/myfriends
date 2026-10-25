//
//  HideLabelOnRecord.xm — standalone 注入 dylib（纯 ObjC Runtime + IL2CPP inline hook）
//
//  功能：
//    1. 针对 Unity IL2CPP 游戏（如贝总U3D通用工具注入的目标），hook UnityEngine.GUI.Label / GUI.Box
//    2. 当 iOS 正在录屏/被捕获 时，过滤并跳过绘制「物体类名文字」（贝总工具绘制的内容），
//       同时保留游戏本体 UI / 画面。
//    3. 本机正常游玩时，类名标签照常显示。
//
//  注入方式：LiveContainer + ElleKit / Sideloadly 重签名。
//  hook 采用运行时 dlsym("MSHookFunction")（ElleKit 提供 substrate 兼容层），不静态链接 substrate。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>

#pragma mark - IL2CPP 类型声明（只声明本工程用到的）

typedef struct Il2CppClass Il2CppClass;
typedef struct Il2CppDomain Il2CppDomain;
typedef struct Il2CppMethodInfo Il2CppMethodInfo;
typedef struct Il2CppString Il2CppString;

// Il2CppParameterInfo（用于读参数名，判断是不是 (Rect, string) 重载）
typedef struct Il2CppParameterInfo {
    const char *name;
    void *parameter_type;
    int32_t token;
    uint8_t flags;
    uint8_t type;
} Il2CppParameterInfo;

#pragma mark - 通过 dlsym 动态解析的 il2cpp API（游戏未导出时优雅降级）

static Il2CppDomain* (*IL2CPP_domain_get)(void);
static Il2CppClass*  (*IL2CPP_class_from_name)(Il2CppDomain*, const void*, const char*, const char*);
static const Il2CppMethodInfo** (*IL2CPP_class_get_methods)(Il2CppClass*, void**);
static const char*   (*IL2CPP_method_get_name)(const Il2CppMethodInfo*);
static int           (*IL2CPP_method_get_param_count)(const Il2CppMethodInfo*);
static const Il2CppParameterInfo* (*IL2CPP_method_get_param)(const Il2CppMethodInfo*, uint32_t);
static void*         (*IL2CPP_method_get_address)(const Il2CppMethodInfo*);
static int32_t       (*IL2CPP_string_length)(Il2CppString*);
static char16_t*     (*IL2CPP_string_chars)(Il2CppString*);

#pragma mark - MSHookFunction（运行时解析，ElleKit 提供）

static void (*MSHookFunction_fn)(void *symbol, void *replace, void **result);

#pragma mark - 录屏状态检测

static bool IsCapturedNow(void)
{
    // iOS 11 ~ iOS 26：isCaptured
    if ([UIScreen mainScreen].isCaptured)
        return true;

    // iOS 27+：sceneCaptureState（运行时解析，避免编译期 SDK 依赖）
    UITraitCollection *tc = [UITraitCollection currentTraitCollection];
    SEL s = NSSelectorFromString(@"sceneCaptureState");
    if (tc && [tc respondsToSelector:s]) {
        NSInteger state = (NSInteger)[tc performSelector:s];
        if (state != 0)   // != UISceneCaptureStateNone
            return true;
    }
    return false;
}

#pragma mark - 关键词过滤（只隐藏贝总工具类名文字，保留游戏 UI）

static NSArray<NSString *> *HiddenKeywords(void)
{
    static NSArray *kws;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ kws = @[@"UnityEngine.", @".dll"]; });
    return kws;
}

static BOOL ShouldHideText(NSString *text)
{
    if (text.length == 0) return NO;
    for (NSString *k in HiddenKeywords()) {
        if ([text containsString:k]) return YES;
    }
    return NO;
}

#pragma mark - 把 IL2CPP Il2CppString* 安全转成 NSString*（带 sanity 校验）

static NSString *NSStringFromIl2CppString(Il2CppString *str)
{
    if (!str || !IL2CPP_string_length || !IL2CPP_string_chars) return nil;
    int32_t len = IL2CPP_string_length(str);
    if (len <= 0 || len > 4096) return nil;
    char16_t *chars = IL2CPP_string_chars(str);
    if (!chars) return nil;
    return [[NSString alloc] initWithCharacters:(unichar *)chars length:(NSUInteger)len];
}

#pragma mark - Hook 实现

static void (*orig_GUI_Label)(void*, void*, void*, void*);
static void hook_GUI_Label(void *__this, void *position, void *textArg, void *method)
{
    if (IsCapturedNow()) {
        NSString *txt = NSStringFromIl2CppString((Il2CppString *)textArg);
        if (ShouldHideText(txt)) return;
    }
    orig_GUI_Label(__this, position, textArg, method);
}

static void (*orig_GUI_Box)(void*, void*, void*, void*);
static void hook_GUI_Box(void *__this, void *position, void *textArg, void *method)
{
    if (IsCapturedNow()) {
        NSString *txt = NSStringFromIl2CppString((Il2CppString *)textArg);
        if (ShouldHideText(txt)) return;
    }
    orig_GUI_Box(__this, position, textArg, method);
}

#pragma mark - 遍历 UnityEngine.GUI，hook 名为 Label/Box 且签名为 (Rect, string) 的方法

static void HookGUIMethod(const char *methodName, void *hookFn, void **origOut)
{
    if (!IL2CPP_domain_get || !IL2CPP_class_from_name || !IL2CPP_class_get_methods ||
        !IL2CPP_method_get_name || !IL2CPP_method_get_param_count || !IL2CPP_method_get_param ||
        !IL2CPP_method_get_address || !MSHookFunction_fn)
        return;

    Il2CppDomain *dom = IL2CPP_domain_get();
    if (!dom) return;

    Il2CppClass *guiCls = IL2CPP_class_from_name(dom, NULL, "UnityEngine", "GUI");
    if (!guiCls) {
        NSLog(@"[hideonrecord] 未找到 UnityEngine.GUI");
        return;
    }

    void *iter = NULL;
    const Il2CppMethodInfo *m;
    while ((m = IL2CPP_class_get_methods(guiCls, &iter)) != NULL) {
        const char *mn = IL2CPP_method_get_name(m);
        if (!mn || strcmp(mn, methodName) != 0) continue;

        int argc = IL2CPP_method_get_param_count(m);
        if (argc != 2) continue; // (Rect, text)

        const Il2CppParameterInfo *p1 = IL2CPP_method_get_param(m, 1);
        if (!p1 || !p1->name) continue;
        if (strstr(p1->name, "text") == NULL && strstr(p1->name, "content") == NULL)
            continue;

        void *addr = IL2CPP_method_get_address(m);
        if (!addr) continue;

        MSHookFunction_fn(addr, hookFn, origOut);
        NSLog(@"[hideonrecord] ✅ hook 成功 UnityEngine.GUI.%s", mn);
        break;
    }
}

#pragma mark - 加载入口

__attribute__((constructor)) static void HideLabelOnRecord_ctor(void)
{
    @autoreleasepool {
        MSHookFunction_fn = (void(*)(void*, void*, void**))dlsym(RTLD_DEFAULT, "MSHookFunction");

        IL2CPP_domain_get             = (Il2CppDomain* (*)(void))dlsym(RTLD_DEFAULT, "il2cpp_domain_get");
        IL2CPP_class_from_name        = (Il2CppClass* (*)(Il2CppDomain*, const void*, const char*, const char*))dlsym(RTLD_DEFAULT, "il2cpp_class_from_name");
        IL2CPP_class_get_methods      = (const Il2CppMethodInfo** (*)(Il2CppClass*, void**))dlsym(RTLD_DEFAULT, "il2cpp_class_get_methods");
        IL2CPP_method_get_name        = (const char* (*)(const Il2CppMethodInfo*))dlsym(RTLD_DEFAULT, "il2cpp_method_get_name");
        IL2CPP_method_get_param_count = (int (*)(const Il2CppMethodInfo*))dlsym(RTLD_DEFAULT, "il2cpp_method_get_param_count");
        IL2CPP_method_get_param       = (const Il2CppParameterInfo* (*)(const Il2CppMethodInfo*, uint32_t))dlsym(RTLD_DEFAULT, "il2cpp_method_get_param");
        IL2CPP_method_get_address     = (void* (*)(const Il2CppMethodInfo*))dlsym(RTLD_DEFAULT, "il2cpp_method_get_address");
        IL2CPP_string_length          = (int32_t (*)(Il2CppString*))dlsym(RTLD_DEFAULT, "il2cpp_string_length");
        IL2CPP_string_chars           = (char16_t* (*)(Il2CppString*))dlsym(RTLD_DEFAULT, "il2cpp_string_chars");

        if (!MSHookFunction_fn || !IL2CPP_domain_get) {
            NSLog(@"[hideonrecord] 初始化跳过：MSHookFunction 或 il2cpp 符号不可用（游戏未导出 / ElleKit 未开）");
            return;
        }

        HookGUIMethod("Label", (void*)&hook_GUI_Label, (void**)&orig_GUI_Label);
        HookGUIMethod("Box",   (void*)&hook_GUI_Box,   (void**)&orig_GUI_Box);

        NSLog(@"[hideonrecord] ✅ HideLabelOnRecord 已加载");
    }
}
