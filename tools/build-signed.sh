#!/bin/bash
# 构建并用「稳定自签名证书」签名 Recorpaster.app —— 让 macOS TCC 授权（辅助功能/输入监控/麦克风）
# 跨重编持久，不必每次重编都重新授权。
#
# 背景：xcodebuild 默认产 ad-hoc/无签名二进制，签名身份每次随内容哈希变 → TCC 留不住授权。
# 这里编完用一张固定的本地 code-signing 证书（Recorpaster Dev）盖签：designated requirement =
# `identifier "io.sam.Recorpaster" and certificate leaf = H"<固定哈希>"`，跨重编不变 → 授权持久。
#
# 用法：bash tools/build-signed.sh   → 末尾打印签好名的 .app 路径，open 它去授权/测试热键与上屏。
set -euo pipefail
CERT="Recorpaster Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# 1) 确保稳定签名证书存在。**仅缺失时创建**——重建会换证书哈希、令已有 TCC 授权失效（需重新授权）。
if ! security find-identity "$KEYCHAIN" 2>/dev/null | grep -q "$CERT"; then
  echo "⚠️  未找到「$CERT」证书，创建一张（之后授权都基于它持久）…"
  TMP="$(mktemp -d)"
  cat > "$TMP/c.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $CERT
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
  # 必须用系统 LibreSSL 出 p12（homebrew OpenSSL 3.x 的 p12 macSecurity 读不了）。
  /usr/bin/openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$TMP/k.pem" -out "$TMP/c.pem" -config "$TMP/c.cnf" >/dev/null 2>&1
  /usr/bin/openssl pkcs12 -export -inkey "$TMP/k.pem" -in "$TMP/c.pem" \
    -out "$TMP/c.p12" -name "$CERT" -passout pass:recor >/dev/null 2>&1
  security import "$TMP/c.p12" -k "$KEYCHAIN" -P recor -A -T /usr/bin/codesign
  rm -rf "$TMP"
fi

# 2) 构建（不让 xcodebuild 校验签名身份；签名我们事后手动盖，自签名证书 codesign 直接可用）
echo "→ 构建中…"
xcodebuild -scheme Recorpaster -configuration Debug \
  -destination 'platform=macOS,arch=arm64' build CODE_SIGNING_ALLOWED=NO 2>&1 \
  | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | grep -v AppIntents

# 3) 定位 .app 并盖稳定签名（--deep 一并签嵌入框架，保证整包签名一致可启动）
APP="$(xcodebuild -scheme Recorpaster -configuration Debug \
  -showBuildSettings 2>/dev/null | awk -F' = ' '/ CODESIGNING_FOLDER_PATH/{print $2; exit}')"
codesign --force --deep -s "$CERT" --timestamp=none "$APP"
echo "→ 签名身份："
codesign -d -r- "$APP" 2>&1 | grep -i designated
# 4) 拷一份到桌面，方便直接双击运行（签名身份相同，TCC 授权通用、跨重编持久）
DESK="$HOME/Desktop/Recorpaster.app"
rm -rf "$DESK"
cp -R "$APP" "$DESK"
codesign --verify --deep "$DESK" 2>/dev/null && echo "→ 桌面版签名校验通过"

echo ""
echo "✅ 桌面版已就绪（双击即可运行）: $DESK"
echo "   首次授权辅助功能/输入监控/麦克风后，之后重跑本脚本再双击，授权都还在。"
