#!/bin/sh
# Renders og-card.html to public/og.png (1200x630) with headless Chrome. Run from web/.
set -e
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
"$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
  --window-size=1200,630 --screenshot="$PWD/public/og.png" "file://$PWD/og-card.html" 2>/dev/null
echo "public/og.png rendered"
