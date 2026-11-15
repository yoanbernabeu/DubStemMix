#!/bin/sh
# Copies a song's stems into the plugin's Content/Songs/<name>/ as 16-bit WAV at 44.1 kHz
# (the MPC's only rate). Up to 6 stems, in the order given: strip 1, strip 2, ...
# Usage: mpc/prepare-song.sh "<song name>" stem1.wav stem2.wav ...
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
[ $# -ge 2 ] || { echo "usage: $0 <song name> <stem>..." >&2; exit 1; }
NAME="$1"; shift
OUT="$HERE/DubStemMix/Content/Songs/$NAME"
mkdir -p "$OUT"
i=1
for stem in "$@"; do
  [ $i -le 6 ] || { echo "only the first 6 stems are used" >&2; break; }
  base="$(basename "$stem")"
  afconvert -f WAVE -d LEI16@44100 "$stem" "$OUT/$i - ${base%.*}.wav"
  echo "strip $i: $base"
  i=$((i + 1))
done
echo "-> $OUT"
