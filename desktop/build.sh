#!/bin/sh
# Builds the desktop mock-up (PRD § 17.2) -> desktop/build/dubstemmix-desktop.
# Usage: desktop/build.sh            then: desktop/build/dubstemmix-desktop [export folder | --selftest]
# Linux needs: cmake, a C++ compiler, git, and the headers of ALSA, X11 and OpenGL
#   (Ubuntu: sudo apt install build-essential cmake git libasound2-dev xorg-dev libgl1-mesa-dev).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
SDK="$HERE/../mpc/.sdk"
# The plugin's code is written against Akai's MPC Plugin SDK headers: same pinned commit as mpc/build.sh.
SDK_COMMIT="$(sed -n 's/^SDK_COMMIT=//p' "$HERE/../mpc/build.sh")"
if [ ! -d "$SDK/.git" ]; then
  git clone -q https://github.com/inmusic-software/mpc-plugin-builder-sdk "$SDK"
fi
git -C "$SDK" fetch -q origin "$SDK_COMMIT" 2>/dev/null || true
git -C "$SDK" checkout -q "$SDK_COMMIT"

cmake -S "$HERE" -B "$HERE/build" -DCMAKE_BUILD_TYPE=Release -Wno-dev >/dev/null
cmake --build "$HERE/build" --parallel
echo "Built: $HERE/build/dubstemmix-desktop"
