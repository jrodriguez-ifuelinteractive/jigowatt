#!/usr/bin/env bash
# Assembles build/Jigowatt.app from the SwiftPM release build.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

swift build -c release --product Jigowatt
swift build -c release --product jigowatt-mcp
BIN=$(swift build -c release --show-bin-path)

APP="build/Jigowatt.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Jigowatt" "$APP/Contents/MacOS/Jigowatt"
cp "$BIN/jigowatt-mcp" "$APP/Contents/MacOS/jigowatt-mcp"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# libghostty locates themes/shell-integration via Contents/Resources/{terminfo,ghostty}.
cp -R vendor/ghostty/zig-out/share/terminfo "$APP/Contents/Resources/terminfo"
cp -R vendor/ghostty/zig-out/share/ghostty "$APP/Contents/Resources/ghostty"

# Ad-hoc sign: helper first, then the app.
codesign --force --sign - "$APP/Contents/MacOS/jigowatt-mcp"
codesign --force --sign - "$APP"
echo "Built $APP"
