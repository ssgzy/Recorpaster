#!/usr/bin/env bash
# 一键打 macOS DMG：PyInstaller → ad-hoc 签名 → hdiutil 制作「拖进 Applications」DMG。
# 仅 macOS arm64（mlx 只在 Apple Silicon）。用法：./build_mac.sh
set -euo pipefail

APP="Recorpaster"
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

# 在 /tmp 构建，避免 Google Drive 同步上百 MB 中间产物
WORK="/tmp/recorpaster_build"
DIST="/tmp/recorpaster_dist"
APPBUNDLE="$DIST/$APP.app"
DMG="$HERE/$APP.dmg"

echo "==> [1/4] PyInstaller 打包（无 torch · mlx + onnxruntime）…"
rm -rf "$WORK" "$DIST"
python3 -m PyInstaller --noconfirm --clean --workpath "$WORK" --distpath "$DIST" "$APP.spec"
[ -d "$APPBUNDLE" ] || { echo "❌ 未生成 $APPBUNDLE"; exit 1; }

echo "==> [2/4] ad-hoc 签名（Apple Silicon 上未签名可能直接不让跑）…"
codesign --force --deep --sign - "$APPBUNDLE"
codesign --verify --deep --strict "$APPBUNDLE" && echo "   ✅ 签名校验通过"
# 公证钩子（公开发布才需要；本轮不做）：
#   需 Apple 开发者账号 + Developer ID 证书 + hardened runtime + 麦克风 entitlements
#   codesign --options runtime --entitlements entitlements.plist --sign "Developer ID Application: …" "$APPBUNDLE"
#   xcrun notarytool submit "$DMG" --apple-id <id> --team-id <team> --password <app-pw> --wait
#   xcrun stapler staple "$DMG"

echo "==> [3/4] 制作 DMG（含 /Applications 拖拽别名）…"
STAGE="$(mktemp -d)"
cp -R "$APPBUNDLE" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "==> [4/4] 完成"
echo "   .app : $APPBUNDLE  ($(du -sh "$APPBUNDLE" | cut -f1))"
echo "   .dmg : $DMG  ($(du -sh "$DMG" | cut -f1))"
echo
echo "安装：打开 $APP.dmg，把 $APP 拖进 Applications。"
echo "首次打开（未签名/ad-hoc）：右键 → 打开，或  xattr -dr com.apple.quarantine /Applications/$APP.app"
