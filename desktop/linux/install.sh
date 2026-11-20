#!/bin/sh
# Adds DubStemMix to the applications menu of the current user: copies this folder to
# ~/.local/share/DubStemMix and writes a menu entry. Nothing outside the home folder, no sudo.
# Remove with: ./install.sh --remove
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
APP="$DATA/DubStemMix"
ENTRY="$DATA/applications/dubstemmix.desktop"
if [ "$1" = "--remove" ]; then
  rm -rf "$APP"
  rm -f "$ENTRY"
  echo "DubStemMix removed (your songs in ~/Music/DubStemMix and your settings are untouched)."
  exit 0
fi
mkdir -p "$APP" "$DATA/applications"
if [ "$HERE" != "$APP" ]; then cp -R "$HERE/." "$APP/"; fi
cat > "$ENTRY" <<ENTRY_END
[Desktop Entry]
Type=Application
Name=DubStemMix
Comment=Dub mixing console for stems
Exec="$APP/DubStemMix" %f
Icon=$APP/dubstemmix.png
Terminal=false
Categories=AudioVideo;Audio;Mixer;
ENTRY_END
echo "DubStemMix is in the applications menu. Program: $APP/DubStemMix"
