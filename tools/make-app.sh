#!/bin/zsh
# Builds DubStemMix.app from the Swift package (release), signs it ad hoc and zips it.
#
#   tools/make-app.sh [version] [output-dir]      → <output-dir>/DubStemMix.app and DubStemMix-<version>.zip
#
# No Apple Developer account: the signature is ad hoc, so Gatekeeper asks on first launch (see README).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-0.0.0}"
OUT="${2:-dist}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

swift build -c release --product DubStemMix
BIN=".build/release"

APP="$OUT/DubStemMix.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/DubStemMix" "$APP/Contents/MacOS/DubStemMix"
# Bundle.module looks for the package's resource bundle next to the executable or in Resources.
cp -R "$BIN/DubStemMix_DubStemMix.bundle" "$APP/Contents/Resources/"
cp Design/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Packaging/Info.plist > "$APP/Contents/Info.plist"
echo -n "APPL????" > "$APP/Contents/PkgInfo"

codesign --force --deep --sign - "$APP"
codesign --verify --verbose=1 "$APP"

ZIP="$OUT/DubStemMix-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Built $APP → $ZIP ($(du -h "$ZIP" | cut -f1))"
