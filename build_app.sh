#!/bin/bash
# Build "Claude Usage.app" — an LSUIElement (no Dock) macOS app bundle that
# wraps the floating Swift widget + bundled Python data-fetch scripts.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Claude Usage"
APP="$ROOT/dist/$APP_NAME.app"
ICONSET="$ROOT/dist/icon.iconset"

echo "==> Cleaning $APP"
rm -rf "$APP" "$ICONSET"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

echo "==> Generating app icon (iconset → icns)"
mkdir -p "$ICONSET"
swift "$ROOT/generate_icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

echo "==> Compiling Swift binary"
# Pin the deployment target so the produced Mach-O is usable on older macOS.
# Without -target, swiftc embeds the build machine's SDK minimum (e.g. macOS 15),
# which makes Launch Services reject the app on macOS 14.x and earlier.
DEPLOYMENT_TARGET="${MACOS_DEPLOYMENT_TARGET:-11.0}"
swiftc -O -target "$(uname -m)-apple-macos${DEPLOYMENT_TARGET}" \
    -o "$APP/Contents/MacOS/claude-usage" "$ROOT/float_widget.swift"

echo "==> Bundling Python scripts"
cp "$ROOT/claude_usage.py" "$APP/Contents/Resources/"
cp "$ROOT/poc_fetch_usage.py" "$APP/Contents/Resources/"

echo "==> Writing Info.plist"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Claude Usage</string>
    <key>CFBundleDisplayName</key>     <string>Claude Usage</string>
    <key>CFBundleIdentifier</key>      <string>io.github.claude-desktop-usage</string>
    <key>CFBundleExecutable</key>      <string>claude-usage</string>
    <key>CFBundleVersion</key>         <string>2</string>
    <key>CFBundleShortVersionString</key> <string>0.2.0</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>CFBundleIconName</key>        <string>AppIcon</string>
    <key>LSUIElement</key>             <true/>
    <key>LSMinimumSystemVersion</key>  <string>11.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSHumanReadableCopyright</key> <string>Personal tool. Not an Anthropic product.</string>
</dict>
</plist>
PLIST

echo "==> Done: $APP"
ls "$APP/Contents/Resources/"
echo
echo "Run with:    open \"$APP\""
echo "Install via: cp -R \"$APP\" /Applications/"
