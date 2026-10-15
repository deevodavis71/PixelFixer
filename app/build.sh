#!/bin/zsh
# Builds PixelFixer.app for this Mac's architecture (needs only the Xcode command-line tools).
set -euo pipefail
cd "$(dirname "$0")"
ROOT=..
APP=build/PixelFixer.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/engine" "$APP/Contents/Resources/maps"

swiftc -O -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macos14.0" \
    -o "$APP/Contents/MacOS/PixelFixer" PixelFixerApp.swift Preview.swift Help.swift

cp Info.plist "$APP/Contents/"
[[ -f build/AppIcon.icns ]] || python3 make_icon.py build/AppIcon.icns
cp build/AppIcon.icns "$APP/Contents/Resources/"
rsync -a --exclude __pycache__ "$ROOT/pixelfixer" "$APP/Contents/Resources/engine/"
cp "$ROOT"/maps/*.json "$APP/Contents/Resources/maps/" 2>/dev/null || true

codesign --force --deep --sign - "$APP"
echo "Built $APP"
