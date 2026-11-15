#!/bin/sh
# Packages the MPC plugin for a release (PRD § 16.2 quater):
#   <out>/mpc/YoanDev - VST - DubStemMix/     the plugin, no songs (shipped inside the Mac app)
#   <out>/MPC-DubStemMix-<version>.zip         the same folder and INSTALL.txt (attached to the GitHub release)
#   <out>/MPC-DubStemMix.zip                   the same zip under a fixed name, for the website's download link
#                                              (github.com/<repo>/releases/latest/download/MPC-DubStemMix.zip)
# Usage: mpc/package.sh <version> [out]
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
VERSION="${1:?usage: mpc/package.sh <version> [out]}"
OUT="$(mkdir -p "${2:-dist}" && cd "${2:-dist}" && pwd)"
NAME="YoanDev - VST - DubStemMix"
PROJECT="$HERE/DubStemMix"

# The plugin carries the app's version for this build only.
cp "$PROJECT/plugin.json" "$OUT/.plugin.json.saved"
trap 'mv "$OUT/.plugin.json.saved" "$PROJECT/plugin.json"' EXIT
sed -i '' -E "s/\"version\": \"[^\"]*\"/\"version\": \"$VERSION\"/" "$PROJECT/plugin.json"
"$HERE/build.sh" >/dev/null

rm -rf "$OUT/mpc"
mkdir -p "$OUT/mpc/$NAME"
# Everything but Content/: test songs on a developer's machine never ship.
for item in "$PROJECT/build/$NAME"/*; do
  [ "$(basename "$item")" = "Content" ] && continue
  cp -R "$item" "$OUT/mpc/$NAME/"
done

cat > "$OUT/mpc/INSTALL.txt" <<TXT
DubStemMix for MPC $VERSION
===========================

Turns an Akai MIDImix plugged into an MPC into the DubStemMix dub console.
Needs an MPC standalone with MPC OS 3.10.1 or later.

The simplest way: export a setlist from the DubStemMix app on your Mac
(File > Export Setlist to MPC...). It writes this plugin and your songs on the card.

Without the app (full guide: https://yoanbernabeu.github.io/DubStemMix/docs/mpc/#without-the-app):
1. Copy the folder "$NAME" into a folder named exactly "VST2 Plugins"
   at the root of your MPC's SD card or USB drive.
2. Put your songs in "$NAME/Content/Songs/", one folder per song
   ("01 First Tune", "02 Second Tune"...), with one WAV per strip at 44.1 kHz,
   named "1 - DRUMS.wav", "2 - BASS.wav"... (strips 1 to 6). 44.1 kHz only:
   any other rate plays at the wrong speed and pitch.
3. On the MPC: Preferences > Enhancements (Beta): turn on Enable Enhancements
   and External Plugin Support. Restart the MPC.
4. Create a plugin track, load DubStemMix from External Plugins, and set the
   track's MIDI input to the MIDImix.

Akai does not test or support third-party plugins: save your projects often.
MIT licence - https://github.com/yoanbernabeu/DubStemMix
TXT

ZIP="$OUT/MPC-DubStemMix-$VERSION.zip"
rm -f "$ZIP"
(cd "$OUT/mpc" && COPYFILE_DISABLE=1 zip -qr -X "$ZIP" "$NAME" INSTALL.txt)
cp "$ZIP" "$OUT/MPC-DubStemMix.zip"
echo "Built $OUT/mpc/$NAME -> $ZIP ($(du -h "$ZIP" | cut -f1))"
