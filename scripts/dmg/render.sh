#!/bin/bash
# Render the installer's pictures from their HTML sources with headless Chrome:
#   scripts/dmg/background.tiff    the window background, at 1x and 2x in one file
#   scripts/dmg/VolumeIcon.icns    the icon of the mounted volume and of the image file: the app's icon
# Run it after changing background.html, or when the app icon changed, and commit the results.
#
# Usage: scripts/dmg/render.sh <path/to/app-icon.png>     (a 1024 × 1024 PNG of Suijin's icon)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ICON="${1:?usage: scripts/dmg/render.sh <path/to/app-icon.png>}"
[ -f "$ICON" ] || { echo "render: icon not found: $ICON" >&2; exit 1; }
ICON="$(cd "$(dirname "$ICON")" && pwd)/$(basename "$ICON")"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[ -x "$CHROME" ] || { echo "render: Google Chrome not found" >&2; exit 1; }
WORK="$(mktemp -d -t suijin-dmg-art)"
trap 'rm -rf "$WORK"' EXIT

shot() { # <scale> <width> <height> <url> <out.png>
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --allow-file-access-from-files --default-background-color=00000000 \
    --force-device-scale-factor="$1" --window-size="$2,$3" --screenshot="$5" "$4" >/dev/null 2>&1
}

shot 1 660 400 "file://$HERE/background.html" "$WORK/background.png"
shot 2 660 400 "file://$HERE/background.html" "$WORK/background@2x.png"
# The 2x picture must say it is 144 dpi, or Finder draws it twice as large.
sips -s dpiWidth 144 -s dpiHeight 144 "$WORK/background@2x.png" >/dev/null
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$HERE/background.tiff" >/dev/null 2>&1

# The volume carries the app's own icon: a drawn disk never looks as good as the real thing.
cp "$ICON" "$WORK/volume.png"
SET="$WORK/VolumeIcon.iconset"; mkdir "$SET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$WORK/volume.png" --out "$SET/icon_${size}x${size}.png" >/dev/null
  sips -z "$((size * 2))" "$((size * 2))" "$WORK/volume.png" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$HERE/VolumeIcon.icns"
cp "$WORK/background@2x.png" "$WORK/volume.png" "${RENDER_PREVIEW_DIR:-$WORK}/" 2>/dev/null || true
echo "rendered $HERE/background.tiff and $HERE/VolumeIcon.icns"
