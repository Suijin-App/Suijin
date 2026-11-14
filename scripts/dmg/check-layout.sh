#!/bin/bash
# Says whether a disk image opens as the installer window: its Finder settings name a background picture and that
# picture is in the image. Finder writes those settings when the image is made, and now and then it does not: the
# image is then complete and installs, but opens as a plain window. Exit 0 when the layout is there, 1 when not.
#
# Usage: scripts/dmg/check-layout.sh <path/to/image.dmg>
set -euo pipefail
DMG="${1:?usage: scripts/dmg/check-layout.sh <path/to/image.dmg>}"
MOUNT="$(mktemp -d -t suijin-dmg-layout)"
trap 'hdiutil detach -quiet "$MOUNT" 2>/dev/null || true; rmdir "$MOUNT" 2>/dev/null || true' EXIT
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MOUNT" "$DMG" || { echo "check-layout: cannot mount $DMG" >&2; exit 1; }
[ -f "$MOUNT/.background/background.tiff" ] || { echo "check-layout: the background picture is missing" >&2; exit 1; }
# The icon view's settings hold an alias to the picture under this key only when the background is a picture.
grep -q "backgroundImageAlias" "$MOUNT/.DS_Store" 2>/dev/null || { echo "check-layout: Finder's settings name no background picture" >&2; exit 1; }
