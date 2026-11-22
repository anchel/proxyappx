#!/bin/zsh
# 把已公证的 ProxyAppX.app 打包成 DMG，并对 DMG 签名、公证、装订票据（make dmg / make release 会调用）。
#
#   scripts/make-dmg.sh <ProxyAppX.app> <版本号> [输出目录]
#
# DMG 内含 ProxyAppX.app 和指向 /Applications 的快捷方式，打开后拖进去即可安装。
#
# 公证 DMG 需要 notarytool 的钥匙串配置（只需保存一次）：
#   xcrun notarytool store-credentials <配置名> --team-id <Team ID>
# 配置名取自环境变量 NOTARY_PROFILE，未设置时读取 Config/Signing.xcconfig 中的 NOTARY_PROFILE。
# 两处都没有时只生成未签名的 DMG（里面的 App 仍是公证过的）；NOTARY_PROFILE=none 可显式跳过。
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

APP="${1:?用法：scripts/make-dmg.sh <ProxyAppX.app> <版本号> [输出目录]}"
VERSION="${2:?缺少版本号}"
OUT="${3:-$ROOT/build/release}"
DMG="$OUT/ProxyAppX-$VERSION.dmg"
STAGE="$OUT/dmg-staging"
SIGN_IDENTITY="${DMG_SIGN_IDENTITY:-Developer ID Application}"

if [[ -z "${NOTARY_PROFILE:-}" && -f Config/Signing.xcconfig ]]; then
  NOTARY_PROFILE="$(sed -nE 's/^NOTARY_PROFILE[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' Config/Signing.xcconfig | head -1)"
fi
[[ "${NOTARY_PROFILE:-}" == "none" ]] && NOTARY_PROFILE=""

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
  echo "==> 签名 DMG（$SIGN_IDENTITY）"
  codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"
  codesign --verify --strict "$DMG"

  echo "==> 公证 DMG（钥匙串配置 $NOTARY_PROFILE，通常几分钟）"
  RESULT="$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)"
  STATUS="$(print -r -- "$RESULT" | /usr/bin/plutil -extract status raw -o - - 2>/dev/null || true)"
  SUBMISSION="$(print -r -- "$RESULT" | /usr/bin/plutil -extract id raw -o - - 2>/dev/null || true)"
  if [[ "$STATUS" != "Accepted" ]]; then
    echo "公证未通过（状态：${STATUS:-未知}）"
    [[ -n "$SUBMISSION" ]] && xcrun notarytool log "$SUBMISSION" --keychain-profile "$NOTARY_PROFILE" || print -r -- "$RESULT"
    exit 1
  fi
  echo "公证通过（$SUBMISSION）"
  xcrun stapler staple -q "$DMG"
else
  echo "⚠️  没有配置 NOTARY_PROFILE，DMG 不签名也不公证（里面的 App 已公证）。"
fi

echo "==> 校验 DMG"
hdiutil verify -quiet "$DMG"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun stapler validate -q "$DMG"
  spctl --assess --type open --context context:primary-signature -vv "$DMG"
fi
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
