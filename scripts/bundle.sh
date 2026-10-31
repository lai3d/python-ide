#!/usr/bin/env bash
# Builds a release PyIDE.app into ./build (ad-hoc signed, for local use).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/PyIDE"
APP=build/PyIDE.app

VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed "s/^v//" || true)}"
VERSION="${VERSION:-0.1.0}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/PyIDE"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>PyIDE</string>
    <key>CFBundleDisplayName</key><string>PyIDE</string>
    <key>CFBundleIdentifier</key><string>io.github.lai3d.pyide</string>
    <key>CFBundleExecutable</key><string>PyIDE</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP ($VERSION build $BUILD)"
