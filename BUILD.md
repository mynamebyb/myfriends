# HideLabelOnRecord 构建与注入（standalone）

1. 编译：`make`（需 Theos，见 references/build_environment.md）
   产物：`.theos/obj/debug/libHideLabelOnRecord.dylib`（library.mk 自带 lib 前缀，注入时可重命名）
2. 注入方式二选一：
   - Sideloadly：Advanced setup → Inject dylib → 选该 dylib
   - 手动：`scripts/inject.sh in.ipa out.ipa HideLabelOnRecord.dylib`
3. LiveContainer：把 dylib 放入 LC 的 Tweaks 目录，确保 ElleKit 开启
4. 注意：架构需 arm64（真机）；日志用 macOS Console.app 按 `hidelabelonrecord` 过滤
