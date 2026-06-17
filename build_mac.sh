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

echo "==> [2/4] 完整内聚签名（自内向外：先嵌套 dylib/so/framework，再封外层）…"
# TCC 按「bundle id + 代码签名」记授权。PyInstaller 包内有成百上千个嵌套 Mach-O
# （mlx / onnxruntime / numpy / scipy 的 .so/.dylib + Python 框架），`codesign --deep`
# 对这种复杂包不可靠、常留下残缺签名——这正是「辅助功能里已勾选、AXIsProcessTrusted()
# 仍 false / 反复弹授权」的常见根因。故改为自内向外逐个签名，最后封外层 bundle。
BUNDLE_ID="com.ssgzy.recorpaster"

# —— 选择签名身份 ——
# 优先用真证书「Apple Development」（Xcode→Settings→Accounts 用 Apple ID 免费申请，无需 $99）。
# 真证书身份稳定：其默认 designated requirement 绑定 bundle id + 证书，TCC 跨重建能记住授权，
# 根治「重打包后授权反复失效」。无真证书时回退 ad-hoc（身份不稳，每次重建可能要重新授权）。
DEV_HASH="$(security find-identity -v -p codesigning 2>/dev/null \
  | awk '/Apple Development/ {print $2; exit}')"
if [ -n "${DEV_HASH:-}" ]; then
  SIGN_ID="$DEV_HASH"
  echo "   签名身份：Apple Development 真证书（${DEV_HASH:0:10}…） · TCC 跨重建可记住授权 ✅"
else
  SIGN_ID="-"
  echo "   签名身份：ad-hoc（未找到 Apple Development 证书 → 每次重打可能需重新授权）"
  echo "   建议：Xcode → Settings → Accounts 用 Apple ID 免费申请 Apple Development 证书后重打。"
fi
SIGN=(codesign --force --timestamp=none --sign "$SIGN_ID")

# 1) 先签所有嵌套 Mach-O（.so / .dylib），自内向外（叶子之间互不依赖，可并行）
find "$APPBUNDLE" -type f \( -name '*.so' -o -name '*.dylib' \) -print0 \
  | xargs -0 -P 4 -I {} "${SIGN[@]}" {}

# 2) 再签嵌套 .framework 包（重新封装其已签名的二进制，如 Python.framework）
find "$APPBUNDLE" -type d -name '*.framework' -print0 \
  | xargs -0 -I {} "${SIGN[@]}" {}

# 3) 最后封外层 bundle（不加 --deep；显式钉死 identifier=bundle id，确保与 TCC 记录一致）
"${SIGN[@]}" --identifier "$BUNDLE_ID" "$APPBUNDLE"

# 4) 严格校验（任何残缺都会在此报错，set -e 中止构建）；打印实际签名身份备查
codesign --verify --deep --strict --verbose=2 "$APPBUNDLE"
codesign -dvv "$APPBUNDLE" 2>&1 | grep -E 'Identifier|Authority|Signature|Sealed' || true
echo "   ✅ 完整签名校验通过"
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
echo
echo "授权：系统设置 → 隐私与安全性 → 辅助功能 + 输入监控，勾选 ${APP}，然后重启 ${APP}。"
echo "若装过旧版、授权记录损坏导致仍反复要权限，先清一次陈旧授权再重授："
echo "  tccutil reset Accessibility $BUNDLE_ID ; tccutil reset ListenEvent $BUNDLE_ID"
