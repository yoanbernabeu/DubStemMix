#!/bin/sh
# Tests the plugin on this Mac: the SDK's host simulator, then the transport test
# (STOP / PLAY / PLAY START, end of song, MIDImix faders and mutes).
# Uses a native build made with -DDSM_OFFLINE=1; run mpc/build.sh again before copying to the MPC.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
"$HERE/build.sh" --target native --define DSM_OFFLINE=1 >/dev/null
LIB="$HERE/DubStemMix/build/native/dubstemmix.dylib"
"$HERE/.sdk/.sdk-tools/host_sim" "$LIB" test --playing --seconds 4 | grep -E "FAIL|Result"
OUT="$(mktemp -d)"
c++ -std=c++17 -O1 -I"$HERE/.sdk/framework" -o "$OUT/transport_test" "$HERE/tests/transport_test.cpp"
"$OUT/transport_test" "$LIB" "$OUT/plugin"
rm -rf "$OUT"
