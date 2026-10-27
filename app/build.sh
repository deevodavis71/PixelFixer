#!/bin/zsh
# Builds PixelFixer.app (needs only the Xcode command-line tools).
#
#   ARCHS="arm64 x86_64" app/build.sh   # universal app (default: this Mac's architecture)
#   BUILD_NUMBER=42 app/build.sh        # sets CFBundleVersion (default 1)
#
# The app's version (CFBundleShortVersionString) comes from pyproject.toml.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=..
APP=build/PixelFixer.app
ARCHS=${ARCHS:-$(uname -m)}
VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' "$ROOT/pyproject.toml")

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/engine" "$APP/Contents/Resources/maps"

slices=()
for arch in ${=ARCHS}; do
    swiftc -O -swift-version 5 -parse-as-library -target "$arch-apple-macos14.0" \
        -o "build/PixelFixer-$arch" PixelFixerApp.swift Preview.swift Help.swift
    slices+=("build/PixelFixer-$arch")
done
lipo -create "${slices[@]}" -output "$APP/Contents/MacOS/PixelFixer"
rm -f "${slices[@]}"

cp Info.plist "$APP/Contents/"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "${BUILD_NUMBER:-1}" "$APP/Contents/Info.plist"

[[ -f build/AppIcon.icns ]] || python3 make_icon.py build/AppIcon.icns
cp build/AppIcon.icns "$APP/Contents/Resources/"
rsync -a --exclude __pycache__ "$ROOT/pixelfixer" "$APP/Contents/Resources/engine/"
cp "$ROOT"/maps/*.json "$APP/Contents/Resources/maps/" 2>/dev/null || true

codesign --force --deep --sign - "$APP"
echo "Built $APP $VERSION (${BUILD_NUMBER:-1}) for $ARCHS"
