# HideLabelOnRecord

一个用于 **Unity IL2CPP 游戏** 的 standalone iOS 注入 dylib：**iOS 录屏时自动隐藏贝总 U3D 工具绘制的「物体类名文字」，本机正常游玩时照常显示**。

> 逻辑：检测到系统正在录屏/被捕获 → 命中关键词的 GUI 文字跳过绘制（类名消失）；游戏本体 UI 和画面保留。正常游玩时，类名标签完整显示。

## 原理

- hook `UnityEngine.GUI.Label` / `UnityEngine.GUI.Box`（IL2CPP 方法地址，inline hook）
- 录屏判断：`UIScreen.isCaptured`（iOS11~26）+ `sceneCaptureState`（iOS27，运行时解析）
- 关键词过滤：只隐藏形如 `UnityEngine.Rigidbox`/`BoxCollider`/`.dll` 的类名文字，游戏 UI 不受影响
- hook 用 `dlsym("MSHookFunction")`（ElleKit substrate 兼容层），不静态链接 substrate

## 云编译（GitHub Actions）

- workflow：`.github/workflows/build.yml`
- 推送 `main`/`master` 或手动 `workflow_dispatch` 触发
- macOS runner + Theos 交叉编译 arm64/arm64e
- 产物：`Actions → 本次运行 → Artifacts → HideLabelOnRecord.dylib`

## 本地编译（可选）

```bash
# 需 Theos + iPhoneOS SDK
export THEOS=~/theos
make
# 产物: .theos/obj/debug/libHideLabelOnRecord.dylib
```

## 注入（LiveContainer）

1. 把 `libHideLabelOnRecord.dylib`（可改名 `.dylib`）放进 LiveContainer 的 Tweaks 目录
2. 在目标 Unity 游戏的设置里启用该 dylib
3. 确保 LiveContainer 的 **ElleKit** 已开启（`MSHookFunction` 依赖它）
4. 启动游戏，控制中心录屏测试：类名应消失，游戏画面保留

## 过滤关键词（可自行修改）

在 `src/HideLabelOnRecord.xm` 的 `HiddenKeywords()` 里增删，例如追加 `@"贝总"`、`@"U3D"` 或具体类名 `@"Rigidbody"`。

## 已知局限

- 打开录屏瞬间会有 **1 帧左右** 标签闪现（系统状态回调延迟，LC 环境通病）
- **HDMI 硬件采集卡**抓屏绕开 API，无法拦截
- 只隐藏本 dylib 能 hook 到的 GUI 文字；若贝总工具用 UGUI/Canvas 而非 GUI.Label 绘制，则本方案不生效（需换 hook 目标）

## 合规提醒

仅用于自己本地调试/录制素材。若用于联机对战，存在被游戏反作弊检测与封号的风险，请自担。
