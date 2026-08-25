#!/bin/bash
# Builds Zephyr.app and installs it into ~/Applications.
#
# The build directory lives under ~/Library/Caches on purpose: this project sits
# on the Desktop, which is iCloud-synced, and iCloud mangles code signatures.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$HOME/Library/Caches/ZephyrBuild"
STAGE="$BUILD_DIR/stage"
APP="$STAGE/Zephyr.app"
INSTALL_DIR="$HOME/Applications"

# Build for the machine we are on. Hardcoding arm64 here would break every
# Intel Mac, which this app otherwise supports.
ARCH="$(uname -m)"

echo "==> Building (release, $ARCH)"
swift build \
    --package-path "$PROJECT_DIR" \
    --scratch-path "$BUILD_DIR/scratch" \
    -c release \
    --arch "$ARCH"

BIN_DIR="$(swift build --package-path "$PROJECT_DIR" --scratch-path "$BUILD_DIR/scratch" -c release --arch "$ARCH" --show-bin-path)"

echo "==> Assembling the bundle"
rm -rf "$STAGE"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Library"

cp "$BIN_DIR/Zephyr" "$APP/Contents/MacOS/Zephyr"
cp "$BIN_DIR/ZephyrHelper" "$APP/Contents/Library/zephyr-helper"
cp "$PROJECT_DIR/Scripts/install-helper.sh" "$APP/Contents/Resources/install-helper.sh"
cp "$PROJECT_DIR/Scripts/uninstall-helper.sh" "$APP/Contents/Resources/uninstall-helper.sh"
chmod +x "$APP/Contents/Resources/"*.sh

SDK_VERSION="$(xcrun --show-sdk-version)"
SDK_BUILD="$(xcrun --show-sdk-build-version)"
OS_BUILD="$(sw_vers -buildVersion)"

# The DT* keys are not decoration. Without them macOS treats the bundle as a
# legacy app and hands it the pre-Big-Sur 22pt menu bar geometry, which on a
# notched Mac lands the status item outside the real 33pt menu bar strip — the
# icon then never appears, with the app running and reporting itself visible.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Zephyr</string>
    <key>CFBundleDisplayName</key>
    <string>Zephyr</string>
    <key>CFBundleIdentifier</key>
    <string>com.bence.zephyr</string>
    <key>CFBundleExecutable</key>
    <string>Zephyr</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.2</string>
    <key>CFBundleVersion</key>
    <string>3</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>DTPlatformName</key>
    <string>macosx</string>
    <key>DTPlatformVersion</key>
    <string>${SDK_VERSION}</string>
    <key>DTSDKName</key>
    <string>macosx${SDK_VERSION}</string>
    <key>DTSDKBuild</key>
    <string>${SDK_BUILD}</string>
    <key>DTCompiler</key>
    <string>com.apple.compilers.llvm.clang.1_0</string>
    <key>BuildMachineOSBuild</key>
    <string>${OS_BUILD}</string>
    <key>NSHumanReadableCopyright</key>
    <string>Zephyr — fan control for Apple Silicon and Intel Macs.</string>
</dict>
</plist>
PLIST

echo "==> Icon"
if swift "$PROJECT_DIR/Scripts/make-icon.swift" "$BUILD_DIR/AppIcon.iconset" >/dev/null 2>&1; then
    iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
else
    echo "    (icon generation skipped)"
fi

echo "==> Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP/Contents/Library/zephyr-helper"
codesign --force --sign - --timestamp=none "$APP"

echo "==> Installing to $INSTALL_DIR/Zephyr.app"
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_DIR/Zephyr.app"
cp -R "$APP" "$INSTALL_DIR/Zephyr.app"

echo "==> Done: $INSTALL_DIR/Zephyr.app"
