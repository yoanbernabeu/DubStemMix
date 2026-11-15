#!/bin/sh
# Builds the MPC plugin. Fetches Akai's MPC Plugin SDK (pinned) into mpc/.sdk on first run.
# Usage: mpc/build.sh [build.py options]   e.g. mpc/build.sh --target native
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
SDK="$HERE/.sdk"
SDK_COMMIT=febd2ca5bd9eb16c4a412837196e145566bc981b

if [ ! -d "$SDK/.git" ]; then
  git clone -q https://github.com/inmusic-software/mpc-plugin-builder-sdk "$SDK"
fi
git -C "$SDK" fetch -q origin "$SDK_COMMIT" 2>/dev/null || true
git -C "$SDK" checkout -q "$SDK_COMMIT"

# The screen is generated from the parameter list of a native build (build/params.json).
python3 "$SDK/tools/build.py" "$HERE/DubStemMix" --target native --no-ui --no-validate >/dev/null
python3 "$HERE/DubStemMix/make_skin.py" >/dev/null
python3 "$SDK/tools/build.py" "$HERE/DubStemMix" "$@"
