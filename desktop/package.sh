#!/bin/sh
# Packs the Linux build of DubStemMix (PRD § 17.5, milestone L8) into one archive to unpack and run:
#   desktop/package.sh [version]   ->   desktop/dist/Linux-DubStemMix-<version>-<arch>.tar.gz
# The archive holds the program, the ONNX Runtime library it loads to split songs, the licenses, a notice
# and a small installer for the applications menu. No model file is ever packed (see NOTICE).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
VERSION="${1:-0.0.0}"
ARCH="$(uname -m)"
BUILD="${DUBSTEMMIX_BUILD_DIR:-$HERE/build}"
DUBSTEMMIX_VERSION="$VERSION" "$HERE/build.sh"

OUT="$BUILD/dubstemmix-desktop_artefacts/Release"
[ -f "$OUT/DubStemMix" ] || { echo "package.sh packs the Linux build only" >&2; exit 1; }
NAME="DubStemMix-$VERSION-linux-$ARCH"
DIST="${DUBSTEMMIX_DIST_DIR:-$HERE/dist}"
STAGE="$DIST/$NAME"
rm -rf "$STAGE"
mkdir -p "$STAGE/licenses"
cp "$OUT/DubStemMix" "$OUT/libonnxruntime.so" "$STAGE/"
strip "$STAGE/DubStemMix" 2>/dev/null || true
cp "$HERE/linux/README.txt" "$HERE/linux/install.sh" "$STAGE/"
cp "$HERE/../Design/AppIcon.iconset/icon_256x256.png" "$STAGE/dubstemmix.png"
cp "$HERE/LICENSE" "$STAGE/licenses/LICENSE-AGPL-3.0.txt"
cp "$HERE/../NOTICE" "$STAGE/licenses/NOTICE.txt"
cp "$HERE/../Sources/LAME/COPYING" "$STAGE/licenses/LAME-COPYING.txt"
cp "$OUT/onnxruntime-ThirdPartyNotices.txt" "$STAGE/licenses/"
sed -i "s/@VERSION@/$VERSION/g" "$STAGE/README.txt"
chmod +x "$STAGE/DubStemMix" "$STAGE/install.sh"
tar -C "$DIST" -czf "$DIST/Linux-$NAME.tar.gz" "$NAME"
echo "Packed: $DIST/Linux-$NAME.tar.gz"
