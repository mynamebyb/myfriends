//
//  HideLabelOnRecord.xm — standalone 注入 dylib
//
//  【加载验证版】在游戏窗口上加一个红色圆点，行为可判定 dylib 是否加载执行。
//  同时保留「隐藏非 keyWindow」逻辑。
//  - 看到红点 → dylib 已加载，问题在窗口识别
//  - 看不到红点 → dylib 没加载，排查注入
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

__attribute__((constructor)) static void HideLabelOnRecord_ctor(void)
{
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIApplication *app = [UIApplication sharedApplication];
            NSArray *ws = app.windows;
            if (!ws.count) {
                NSLog(@"[hideonrecord] 无 window");
                return;
            }
            // 加载验证：在第一个 window 左上角加红点
            UIWindow *w0 = ws[0];
            UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(20, 80, 30, 30)];
            dot.backgroundColor = [UIColor redColor];
            dot.layer.cornerRadius = 15;
            dot.clipsToBounds = YES;
            [w0 addSubview:dot];
            NSLog(@"[hideonrecord] 红点已添加，dylib 加载成功");

            // 隐藏非 keyWindow（诊断用）
            NSTimer *t = [NSTimer scheduledTimerWithTimeInterval:0.3
                                                          repeats:YES
                                                            block:^(NSTimer *timer) {
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
