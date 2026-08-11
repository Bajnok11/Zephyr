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

echo "==> Fordítás (release)"
swift build \
    --package-path "$PROJECT_DIR" \
    --scratch-path "$BUILD_DIR/scratch" \
    -c release \
    --arch arm64

BIN_DIR="$(swift build --package-path "$PROJECT_DIR" --scratch-path "$BUILD_DIR/scratch" -c release --arch arm64 --show-bin-path)"

echo "==> Csomag összeállítása"
rm -rf "$STAGE"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Library"

cp "$BIN_DIR/Zephyr" "$APP/Contents/MacOS/Zephyr"
cp "$BIN_DIR/ZephyrHelper" "$APP/Contents/Library/zephyr-helper"
cp "$PROJECT_DIR/Scripts/install-helper.sh" "$APP/Contents/Resources/install-helper.sh"
cp "$PROJECT_DIR/Scripts/uninstall-helper.sh" "$APP/Contents/Resources/uninstall-helper.sh"
chmod +x "$APP/Contents/Resources/"*.sh

cat > "$APP/Contents/Info.plist" <<'PLIST'
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
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Zephyr — ventilátorvezérlés Apple Silicon és Intel Macekhez.</string>
</dict>
</plist>
PLIST

echo "==> Ikon"
if swift "$PROJECT_DIR/Scripts/make-icon.swift" "$BUILD_DIR/AppIcon.iconset" >/dev/null 2>&1; then
    iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
else
    echo "    (ikon generálás kihagyva)"
fi

echo "==> Aláírás (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP/Contents/Library/zephyr-helper"
codesign --force --sign - --timestamp=none "$APP"

echo "==> Telepítés: $INSTALL_DIR/Zephyr.app"
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_DIR/Zephyr.app"
cp -R "$APP" "$INSTALL_DIR/Zephyr.app"

echo "==> Kész: $INSTALL_DIR/Zephyr.app"
