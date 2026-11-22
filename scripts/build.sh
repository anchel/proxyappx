#!/bin/zsh
# 构建 ProxyAppX（日常使用请通过 Makefile：make install / make build / make check）。
#
#   scripts/build.sh [install]   签名构建并安装到 /Applications，然后打开（系统扩展只能从 /Applications 激活）
#   scripts/build.sh build       只签名构建，不安装
#   scripts/build.sh check       不签名，只检查能否编译，并运行核心库测试
#
# 环境变量 CONFIG=Debug|Release 选择构建配置（默认 Debug）。
# 签名配置见 Config/Signing.xcconfig（参考 Config/Signing.example.xcconfig）。
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

MODE="${1:-install}"
CONFIG="${CONFIG:-Debug}"
DERIVED="$ROOT/build/DerivedData"

case "$MODE" in
  install|build|check) ;;
  *) echo "用法：scripts/build.sh [install|build|check]"; exit 2 ;;
esac

command -v xcodegen >/dev/null || { echo "需要先安装 XcodeGen：brew install xcodegen"; exit 1; }
xcodegen generate --quiet

if [[ "$MODE" == "check" ]]; then
  xcodebuild -project ProxyAppX.xcodeproj -scheme ProxyAppX -configuration "$CONFIG" \
    -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" build -quiet
  (cd Packages/ProxyAppXCore && swift test)
  echo "✅ 编译检查与测试通过"
  exit 0
fi

if [[ ! -f Config/Signing.xcconfig ]]; then
  echo "缺少 Config/Signing.xcconfig，请先复制 Config/Signing.example.xcconfig 并填写 Team ID。"
  exit 1
fi

# 每次构建使用递增的构建号：系统扩展版本号不变时，系统不会替换已安装的旧扩展。
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
xcodebuild -project ProxyAppX.xcodeproj -scheme ProxyAppX -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" build -quiet

APP="$DERIVED/Build/Products/$CONFIG/ProxyAppX.app"
codesign --verify --deep --strict "$APP"
echo "✅ 已构建 $APP（$CONFIG，构建号 $BUILD_NUMBER）"
[[ "$MODE" == "build" ]] && exit 0

# 安装到 /Applications（先退出正在运行的旧版本）
osascript -e 'tell application id "'"$(defaults read "$APP/Contents/Info" CFBundleIdentifier)"'" to quit' 2>/dev/null || true
rm -rf /Applications/ProxyAppX.app
ditto "$APP" /Applications/ProxyAppX.app
echo "✅ 已安装到 /Applications/ProxyAppX.app"
open /Applications/ProxyAppX.app
