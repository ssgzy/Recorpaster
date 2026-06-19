#!/bin/bash
# tools/release.sh — Recorpaster macOS 发布流水线
# Release 构建 → 内嵌框架由内向外逐个签 → 主 app 签(Developer ID + hardened runtime + timestamp + entitlements)
# → 公证(notarytool) → 钉票 → DMG(拖进 Applications) → 公证+钉 DMG → 验证 → dist/Recorpaster.dmg
#
# 先决条件（一次性）：
#   1) Developer ID Application 证书在登录钥匙串： security find-identity -v -p codesigning  应能看到
#   2) 存公证凭据 profile：
#        xcrun notarytool store-credentials Recorpaster \
#          --apple-id 你的AppleID --team-id 你的TeamID --password app专用密码
#      （app 专用密码在 appleid.apple.com 生成）
#   3) brew install create-dmg
#   4) 内置标点模型：把 PunctZh.mlpackage 放在 Recorpaster/（已 .gitignore，不进库但会打进 app）
#
# 用法： bash tools/release.sh      （可用环境变量覆盖 DEV_ID / NOTARY_PROFILE）
set -euo pipefail
cd "$(dirname "$0")/.."

SCHEME="Recorpaster"; APP_NAME="Recorpaster"; CONFIG="Release"
DEV_ID="${DEV_ID:-Developer ID Application}"        # 身份名前缀或 SHA-1
NOTARY_PROFILE="${NOTARY_PROFILE:-Recorpaster}"     # notarytool 凭据 profile 名
ENTITLEMENTS="tools/Recorpaster.entitlements"
DERIVED="build/release-dd"; DIST="dist"

log(){ printf "\n\033[1;36m▶ %s\033[0m\n" "$*"; }
die(){ printf "\033[1;31m✗ %s\033[0m\n" "$*"; exit 1; }

# ── 0) 前置检查 ──
log "前置检查"
command -v create-dmg >/dev/null || die "缺 create-dmg：brew install create-dmg"
security find-identity -v -p codesigning | grep -q "$DEV_ID" \
  || die "找不到签名身份「$DEV_ID」——security find-identity -v -p codesigning 看实际名/哈希，用 DEV_ID= 覆盖"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || die "公证凭据 profile「$NOTARY_PROFILE」不可用——先 xcrun notarytool store-credentials（见脚本头注）"
[ -d "Recorpaster/PunctZh.mlpackage" ] \
  || echo "⚠️  Recorpaster/PunctZh.mlpackage 不在 → 发布版不含内置标点模型（运行时下载/App Support 兜底）"
rm -rf "$DERIVED" "$DIST"; mkdir -p "$DIST"

# ── 1) Release 构建（不让 xcodebuild 签；签名事后手动逐个做）──
log "Release 构建"
xcodebuild -scheme "$SCHEME" -configuration "$CONFIG" -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" build CODE_SIGNING_ALLOWED=NO 2>&1 \
  | grep -E "error:|warning: .*deprecated|BUILD SUCCEEDED|BUILD FAILED" | grep -v AppIntents || true
APP="$DERIVED/Build/Products/$CONFIG/$APP_NAME.app"
[ -d "$APP" ] || die "未找到构建产物 $APP"

# ── 2) 签名：内嵌 dylib/framework 由内向外逐个签（深的先），再主 app（带 entitlements）。不用 --deep ──
log "签名（inside-out + hardened runtime + --timestamp）"
# 先签所有嵌入的可执行代码（dylib / framework）——按路径深度倒序，确保由内向外。
find "$APP/Contents" \( -name "*.dylib" -o -name "*.framework" -o -name "*.bundle" \) -print0 2>/dev/null \
  | xargs -0 -I{} echo {} | awk '{ print gsub(/\//,"/"), $0 }' | sort -rn | cut -d' ' -f2- \
  | while IFS= read -r item; do
      # 仅对带可执行代码的包/库签名（资源 .bundle 无 MachO 时 codesign 也能签，无害）
      codesign --force --options runtime --timestamp -s "$DEV_ID" "$item" 2>&1 | sed 's/^/    /' || die "签名失败：$item"
    done
# 主 app（hardened runtime + timestamp + entitlements）
codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" -s "$DEV_ID" "$APP" \
  || die "主 app 签名失败"
codesign --verify --strict --verbose=2 "$APP" || die "codesign --verify --strict 未过"

# ── 3) 公证 app ──
log "公证 app（notarytool submit --wait，约几分钟）"
ZIP="$DIST/$APP_NAME-notarize.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait || die "公证失败（看上面 log，或 notarytool log <id>）"
rm -f "$ZIP"

# ── 4) 钉票到 app ──
log "stapler staple app"
xcrun stapler staple "$APP" || die "钉票失败"

# ── 5) DMG（拖进 Applications 样式）──
log "create-dmg"
STAGE="$DIST/.stage"; rm -rf "$STAGE"; mkdir -p "$STAGE"; cp -R "$APP" "$STAGE/"
DMG="$DIST/$APP_NAME.dmg"; rm -f "$DMG"
create-dmg \
  --volname "$APP_NAME" \
  --window-size 540 380 --icon-size 110 \
  --icon "$APP_NAME.app" 150 185 \
  --app-drop-link 390 185 \
  --no-internet-enable \
  "$DMG" "$STAGE" || true            # create-dmg 偶发非零退出但 DMG 已生成
rm -rf "$STAGE"
[ -f "$DMG" ] || die "DMG 未生成"

# ── 6) 公证 + 钉 DMG ──
log "公证 DMG + staple"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait || die "DMG 公证失败"
xcrun stapler staple "$DMG" || die "DMG 钉票失败"

# ── 7) 验证 ──
log "验证"
echo "—— spctl app ——";  spctl -a -vvv -t install "$APP" 2>&1 || true
echo "—— spctl dmg ——";  spctl -a -vvv -t install "$DMG" 2>&1 || true
echo "—— codesign --verify --strict ——"; codesign --verify --strict --verbose=2 "$APP" 2>&1 || true
echo "—— stapler validate dmg ——"; xcrun stapler validate "$DMG" 2>&1 || true

log "完成 ✅  →  $DMG"
ls -lh "$DMG"
