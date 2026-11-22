#!/bin/zsh
# 把已公证的 ProxyAppX.app 打包成 DMG（make dmg / make release 会调用）。
#
#   scripts/make-dmg.sh <ProxyAppX.app> <版本号> [输出目录]
#
# DMG 内含 ProxyAppX.app 和指向 /Applications 的快捷方式，打开后拖进去即可安装。
# App 本身已签名、公证并装订票据，DMG 默认不签名：Gatekeeper 会在打开 App 时检查它。
# 如果设置了 NOTARY_PROFILE（`xcrun notarytool store-credentials` 保存的钥匙串配置名），
# 还会对 DMG 签名、公证并装订票据。
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

APP="${1:?用法：scripts/make-dmg.sh <ProxyAppX.app> <版本号> [输出目录]}"
VERSION="${2:?缺少版本号}"
OUT="${3:-$ROOT/build/release}"
DMG="$OUT/ProxyAppX-$VERSION.dmg"
STAGE="$OUT/dmg-staging"

[[ -d "$APP" ]] || { echo "找不到 $APP，请先运行 make release"; exit 1; }
xcrun stapler validate -q "$APP" || { echo "$APP 没有装订公证票据"; exit 1; }

echo "==> 打包 DMG"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/ProxyAppX.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "ProxyAppX $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$STAGE"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  echo "==> 签名并公证 DMG（$NOTARY_PROFILE）"
  codesign --sign "${DMG_SIGN_IDENTITY:-Developer ID Application}" --timestamp "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

echo "==> 校验 DMG"
hdiutil verify -quiet "$DMG"
MOUNT="$(mktemp -d /tmp/proxyappx-dmg.XXXXXX)"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MOUNT" "$DMG"
trap 'hdiutil detach -quiet "$MOUNT" 2>/dev/null || true; rmdir "$MOUNT" 2>/dev/null || true' EXIT
[[ -L "$MOUNT/Applications" ]] || { echo "DMG 中缺少 Applications 快捷方式"; exit 1; }
xcrun stapler validate -q "$MOUNT/ProxyAppX.app"
spctl --assess --type execute "$MOUNT/ProxyAppX.app"
DMG_VERSION="$(defaults read "$MOUNT/ProxyAppX.app/Contents/Info" CFBundleShortVersionString)"
[[ "$DMG_VERSION" == "$VERSION" ]] || { echo "DMG 里的 App 版本是 $DMG_VERSION，不是 $VERSION"; exit 1; }

(cd "$OUT" && shasum -a 256 "${DMG:t}" > "${DMG:t}.sha256")
echo "✅ $DMG"
cat "$DMG.sha256"
