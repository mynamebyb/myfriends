//
//  HideLabelOnRecord.xm — standalone 注入 dylib
//
//  【录屏检测验证版】
//  - 右下角绿点：永远显示，证明 dylib 加载成功
//  - 左上角红点：只在系统录屏时出现，验证录屏检测（isCaptured / sceneCaptureState）是否生效
//  - 若开录屏红点出现 → 检测生效；不出现 → iOS27 检测失效，需换检测方法
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>

static BOOL IsCapturedNow(void)
{
    // iOS 11 ~ iOS 26
    if ([UIScreen mainScreen].isCaptured)
        return YES;
    // iOS 27+：sceneCaptureState
    UITraitCollection *tc = [UITraitCollection currentTraitCollection];
    SEL s = NSSelectorFromString(@"sceneCaptureState");
    if (tc && [tc respondsToSelector:s]) {
        NSInteger (*send)(id, SEL) = (NSInteger (*)(id, SEL))objc_msgSend;
        if (send(tc, s) != 0)
            return YES;
    }
    return NO;
}

__attribute__((constructor)) static void HideLabelOnRecord_ctor(void)
{
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIApplication *app = [UIApplication sharedApplication];
            NSArray *ws = app.windows;
            if (!ws.count) return;
            UIWindow *w0 = ws[0];
            CGRect b = w0.bounds;

            // 右下绿点：加载证明，常显
            UIView *green = [[UIView alloc] initWithFrame:CGRectMake(CGRectGetMaxX(b)-50, CGRectGetMaxY(b)-100, 30, 30)];
            green.backgroundColor = [UIColor greenColor];
            green.layer.cornerRadius = 15; green.clipsToBounds = YES;
            [w0 addSubview:green];

            // 左上红点：仅录屏时显示
            UIView *red = [[UIView alloc] initWithFrame:CGRectMake(20, 80, 30, 30)];
            red.backgroundColor = [UIColor redColor];
            red.layer.cornerRadius = 15; red.clipsToBounds = YES;
            red.hidden = YES;
            [w0 addSubview:red];

            NSLog(@"[hideonrecord] 绿点常显=已加载；红点仅录屏时显示=检测生效验证");

            NSTimer *t = [NSTimer scheduledTimerWithTimeInterval:0.3
                                                          repeats:YES
                                                            block:^(NSTimer *timer) {
                BOOL cap = IsCapturedNow();
                red.hidden = !cap;
                if (cap) NSLog(@"[hideonrecord] 检测到录屏");
            }];
            (void)t;
        });
    }
}
