#!/bin/sh
# Installs or updates DubStemMix from the latest GitHub release, in one line:
#
#   curl -fsSL https://raw.githubusercontent.com/yoanbernabeu/dubstemmix/main/install.sh | sh
#
# What it does: downloads DubStemMix-<version>.zip from the latest release, replaces
# /Applications/DubStemMix.app (or ~/Applications if /Applications is not writable), removes the
# quarantine flag that Gatekeeper puts on downloads (the app is signed ad hoc, not notarized: no Apple
# Developer account), and opens it. Set DUBSTEMMIX_VERSION=v0.1.0 to pin a version.
set -eu

REPO="yoanbernabeu/dubstemmix"
API="https://api.github.com/repos/$REPO/releases"
if [ -n "${DUBSTEMMIX_VERSION:-}" ]; then
    RELEASE_URL="$API/tags/$DUBSTEMMIX_VERSION"
else
    RELEASE_URL="$API/latest"
fi

echo "DubStemMix — looking up the release…"
ASSET_URL="$(curl -fsSL "$RELEASE_URL" | grep -o '"browser_download_url": *"[^"]*DubStemMix-[^"]*\.zip"' | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')"
if [ -z "$ASSET_URL" ]; then
    echo "No DubStemMix zip found in the release ($RELEASE_URL)." >&2
    exit 1
fi
VERSION="$(echo "$ASSET_URL" | sed 's/.*DubStemMix-\(.*\)\.zip/\1/')"

DEST="/Applications"
if [ ! -w "$DEST" ]; then
    DEST="$HOME/Applications"
    mkdir -p "$DEST"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "Downloading DubStemMix $VERSION…"
curl -fL --progress-bar "$ASSET_URL" -o "$TMP/DubStemMix.zip"
ditto -x -k "$TMP/DubStemMix.zip" "$TMP/unzipped"

if [ ! -d "$TMP/unzipped/DubStemMix.app" ]; then
    echo "The archive does not contain DubStemMix.app." >&2
    exit 1
fi

if pgrep -x DubStemMix >/dev/null 2>&1; then
    echo "Quitting the running DubStemMix…"
    osascript -e 'tell application "DubStemMix" to quit' >/dev/null 2>&1 || true
    sleep 1
fi

rm -rf "$DEST/DubStemMix.app"
ditto "$TMP/unzipped/DubStemMix.app" "$DEST/DubStemMix.app"
# Gatekeeper: the app is not notarized. Removing the quarantine flag is what "Open anyway" would do.
xattr -dr com.apple.quarantine "$DEST/DubStemMix.app" 2>/dev/null || true

echo "Installed DubStemMix $VERSION in $DEST."
echo "The stem separation model (663 MB) is downloaded on first use, after asking you."
open "$DEST/DubStemMix.app"
