#!/bin/sh
# Builds DubStemMix for the desktop (PRD § 17) and writes a launcher: desktop/build/dubstemmix-desktop.
# Usage: desktop/build.sh            then: desktop/build/dubstemmix-desktop [songs folder | --selftest]
# Linux needs a C++ compiler, cmake, git and JUCE's headers (Ubuntu):
#   sudo apt install build-essential cmake git pkg-config libasound2-dev libfreetype-dev libfontconfig1-dev \
#     libx11-dev libxcomposite-dev libxcursor-dev libxext-dev libxinerama-dev libxrandr-dev libxrender-dev \
#     libglu1-mesa-dev mesa-common-dev libcurl4-openssl-dev
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
SDK="$HERE/../mpc/.sdk"
# The engine is written against Akai's MPC Plugin SDK headers: same pinned commit as mpc/build.sh.
SDK_COMMIT="$(sed -n 's/^SDK_COMMIT=//p' "$HERE/../mpc/build.sh")"
if [ ! -d "$SDK/.git" ]; then
  git clone -q https://github.com/inmusic-software/mpc-plugin-builder-sdk "$SDK"
fi
git -C "$SDK" fetch -q origin "$SDK_COMMIT" 2>/dev/null || true
git -C "$SDK" checkout -q "$SDK_COMMIT"

BUILD="${DUBSTEMMIX_BUILD_DIR:-$HERE/build}"
cmake -S "$HERE" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release -Wno-dev >/dev/null
cmake --build "$BUILD" --parallel

# JUCE puts the program in an app bundle on macOS, a plain file on Linux: one launcher for both.
OUT="$BUILD/dubstemmix-desktop_artefacts/Release"
if [ -d "$OUT/DubStemMix.app" ]; then BIN="$OUT/DubStemMix.app/Contents/MacOS/DubStemMix"; else BIN="$OUT/DubStemMix"; fi
printf '#!/bin/sh\nexec "%s" "$@"\n' "$BIN" > "$BUILD/dubstemmix-desktop"
chmod +x "$BUILD/dubstemmix-desktop"
echo "Built: $BUILD/dubstemmix-desktop"
