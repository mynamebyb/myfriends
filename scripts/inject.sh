#!/bin/bash
# 把 standalone dylib 注入 IPA（需要 optool 或 insert_dylib）
# 用法: ./inject.sh xxx.ipa out.ipa payload/name.dylib
set -e
IPA_IN="$1"; IPA_OUT="$2"; DYLIB="$3"
[ -z "$IPA_OUT" ] && { echo "用法: $0 in.ipa out.ipa Tweak.dylib"; exit 1; }

WORK=$(mktemp -d)
cp "$IPA_IN" "$WORK/in.ipa"
cd "$WORK"
unzip -q in.ipa
APP=$(ls -d Payload/*.app | head -1)
cp "$DYLIB" "$APP/Frameworks/" 2>/dev/null || { mkdir -p "$APP/Frameworks"; cp "$DYLIB" "$APP/Frameworks/"; }
DYLIB_NAME=$(basename "$DYLIB")
# 优先 optool；没有就用 insert_dylib
if command -v optool >/dev/null; then
    optool install -c load -p "@executable_path/Frameworks/$DYLIB_NAME" -t "$APP/$(basename "$APP" .app)"
else
    BIN="$APP/$(basename "$APP" .app)"
    install_name_tool -add_rpath @executable_path/Frameworks "$BIN" 2>/dev/null || true
    insert_dylib --insecure @executable_path/Frameworks/$DYLIB_NAME "$BIN"
fi
# 签名（udid-signed 证书环境下用 Sideloadly 重签；此处仅打包）
zip -qr "$OLDPWD/$IPA_OUT" Payload
cd "$OLDPWD"
rm -rf "$WORK"
echo "✅ 已生成 $IPA_OUT（注入后还需用 Sideloadly/证书重签名）"
