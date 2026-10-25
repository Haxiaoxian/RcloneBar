#!/bin/bash
# 构建 RcloneBar.app（Apple Silicon，macOS 14+）
#
#   scripts/build-app.sh            # release 构建，输出 build/RcloneBar.app 与 build/RcloneBar.zip
#   SIGN_IDENTITY="Developer ID Application: ..." scripts/build-app.sh   # 使用自己的证书签名（默认 ad-hoc）
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
ARCH="${ARCH:-arm64}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

echo "==> swift build ($CONFIG, $ARCH)"
swift build -c "$CONFIG" --arch "$ARCH" --product RcloneBar
swift build -c "$CONFIG" --arch "$ARCH" --product rclonebar-agent
BIN="$(swift build -c "$CONFIG" --arch "$ARCH" --show-bin-path)"

APP="build/RcloneBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/RcloneBar" "$APP/Contents/MacOS/RcloneBar"
cp "$BIN/rclonebar-agent" "$APP/Contents/MacOS/rclonebar-agent"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> codesign ($SIGN_IDENTITY)"
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP/Contents/MacOS/rclonebar-agent"
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"

echo "==> 架构检查"
lipo -archs "$APP/Contents/MacOS/RcloneBar"
lipo -archs "$APP/Contents/MacOS/rclonebar-agent"

rm -f build/RcloneBar.zip
ditto -c -k --keepParent "$APP" build/RcloneBar.zip
echo "完成：$APP"
echo "      build/RcloneBar.zip"
