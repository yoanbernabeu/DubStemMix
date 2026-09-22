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
# The package's resource bundle (fonts). Depending on the toolchain it comes flat or as
# Contents/Resources: normalize to the latter, with an Info.plist, so it is a proper bundle.
RES="$APP/Contents/Resources/DubStemMix_DubStemMix.bundle"
cp -R "$BIN/DubStemMix_DubStemMix.bundle" "$RES"
if [ ! -d "$RES/Contents" ]; then
    mkdir -p "$RES/Contents/Resources"
    find "$RES" -maxdepth 1 -type f -exec mv {} "$RES/Contents/Resources/" \;
    cat > "$RES/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>com.yoanbernabeu.DubStemMix.resources</string>
    <key>CFBundleName</key><string>DubStemMix_DubStemMix</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
</dict></plist>
PLIST
fi
cp Design/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Packaging/Info.plist > "$APP/Contents/Info.plist"
echo -n "APPL????" > "$APP/Contents/PkgInfo"

codesign --force --deep --sign - "$APP"
codesign --verify --verbose=1 "$APP"

ZIP="$OUT/DubStemMix-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Built $APP → $ZIP ($(du -h "$ZIP" | cut -f1))"
