#!/bin/zsh
# 生成可分发的安装包：Release 归档 → Developer ID 导出并提交 Apple 公证 → 等待公证 → 打包 DMG。
#
#   make release        （等同于 scripts/release.sh）
#
# 前提：Xcode › Settings › Accounts 已登录开发者账号（导出时自动生成 Developer ID 描述文件，
# 并用该账号提交公证）；Config/Signing.xcconfig 已填写 DEVELOPMENT_TEAM。
# 产物：build/release/ProxyAppX-<版本>.dmg（内含已公证并装订票据的 ProxyAppX.app）及其 SHA-256；
# build/release/COMMIT 记录构建所用的提交，make publish 会核对它。
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

VERSION="$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([^"]+)"?.*/\1/p' project.yml | head -1)"
TEAM="$(sed -nE 's/^DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*([A-Z0-9]+).*/\1/p' Config/Signing.xcconfig 2>/dev/null | head -1)"
[[ -n "$TEAM" ]] || { echo "Config/Signing.xcconfig 中缺少 DEVELOPMENT_TEAM"; exit 1; }
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
OUT="$ROOT/build/release"
ARCHIVE="$OUT/ProxyAppX.xcarchive"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "⚠️  工作区有未提交的改动，安装包将包含这些改动；正式发布前请先提交。"
fi

rm -rf "$OUT"
mkdir -p "$OUT"
git rev-parse HEAD > "$OUT/COMMIT"
[[ -z "$(git status --porcelain)" ]] || echo "dirty" >> "$OUT/COMMIT"
xcodegen generate --quiet

echo "==> 归档 $VERSION ($BUILD_NUMBER)"
xcodebuild archive -project ProxyAppX.xcodeproj -scheme ProxyAppX -configuration Release \
  -archivePath "$ARCHIVE" -derivedDataPath "$ROOT/build/DerivedData" \
  -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$BUILD_NUMBER" -quiet

cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>developer-id</string>
	<key>signingStyle</key><string>automatic</string>
	<key>teamID</key><string>$TEAM</string>
	<key>destination</key><string>upload</string>
</dict>
</plist>
EOF

echo "==> Developer ID 导出并提交公证"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -exportPath "$OUT/upload" -allowProvisioningUpdates -quiet

echo "==> 等待公证（通常几分钟）"
for i in {1..60}; do
  rm -rf "$OUT/notarized"
  if result="$(xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$OUT/notarized" 2>&1)"; then
    break
  fi
  if print -r -- "$result" | grep -qiE "invalid|rejected"; then
    print -r -- "$result" | tail -20
    echo "公证被拒绝"; exit 1
  fi
  (( i == 60 )) && { echo "等待公证超时"; exit 1; }
  sleep 30
done

APP="$OUT/notarized/ProxyAppX.app"
echo "==> 校验"
xcrun stapler validate "$APP"
spctl --assess --type execute -vv "$APP"
ENTITLEMENTS="$(codesign -d --entitlements - "$APP/Contents/Library/SystemExtensions/"*.systemextension 2>/dev/null)"
[[ "$ENTITLEMENTS" == *app-proxy-provider-systemextension* ]] || { echo "扩展缺少 Developer ID 版本的 NE entitlement"; exit 1; }

"$ROOT/scripts/make-dmg.sh" "$APP" "$VERSION" "$OUT"
