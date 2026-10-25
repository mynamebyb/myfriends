//
//  HideLabelOnRecord.xm — standalone 注入 dylib
//
//  功能：隐藏「贝总 U3D 工具」叠加在 Unity 游戏上的界面（物体名、方框等）。
//
//  【诊断版】不依赖任何 hook 引擎，纯 UIKit：
//  贝总悬浮窗是独立 UIWindow，游戏主画面在 keyWindow。
//  永久隐藏除 keyWindow 外的所有 window → 行为可判定贝总窗口是否就是非主窗口。
//  若生效，下一步改回「仅录屏时隐藏」。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

__attribute__((constructor)) static void HideLabelOnRecord_ctor(void)
{
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSLog(@"[hideonrecord] 诊断版已加载（永久隐藏非主窗口）");
            NSTimer *t = [NSTimer scheduledTimerWithTimeInterval:0.3
                                                          repeats:YES
                                                            block:^(NSTimer *timer) {
                // 枚举所有 window，隐藏非 keyWindow（贝总悬浮窗 / 伪装计算器窗）
                UIApplication *app = [UIApplication sharedApplication];
                UIWindow *key = app.keyWindow;
                for (UIWindow *w in app.windows) {
                    if (w != key && !w.hidden) {
                        NSLog(@"[hideonrecord] 隐藏非主窗口: %@", w);
                        w.hidden = YES;
                    }
                }
            }];
            (void)t;
        });
    }
}
