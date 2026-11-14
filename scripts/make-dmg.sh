#!/bin/bash
# Package a signed (normally notarized and stapled) Suijin.app into a compressed DMG, then sign the DMG. The DMG opens
# as an installer window: the app beside an Applications shortcut on the picture scripts/dmg/background.tiff, and the
# mounted volume carries scripts/dmg/VolumeIcon.icns. `create-dmg` (brew install create-dmg) lays the window out; it
# asks Finder to arrange the icons, so the first run may ask to let the terminal control Finder. Called by scripts/release-notarize.sh; can also run alone.
#
# Usage:
#   scripts/make-dmg.sh --app <path/to/Suijin.app> --out <path/to/Suijin-0.1.0.dmg> [--sign <identity>]
#
#   --sign  codesign identity for the DMG (default: $SUIJIN_SIGNING_IDENTITY, else "Developer ID Application").
#           Pass --sign - to leave the DMG unsigned (local testing only; Gatekeeper rejects it).
#
# No credentials are read or stored here: codesign uses the certificate already in the login Keychain.
set -euo pipefail

APP=""
OUT=""
IDENTITY="${SUIJIN_SIGNING_IDENTITY:-Developer ID Application}"

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; }
die() { printf 'make-dmg: %s\n' "$1" >&2; exit 1; }
step() { printf '    [make-dmg] %s\n' "$1"; }
# Prints a command the way it would be typed, quoting arguments that contain spaces, then runs it.
run() {
  local line="" arg
  for arg in "$@"; do
    case "$arg" in *[[:space:]]*) line+=" '$arg'" ;; *) line+=" $arg" ;; esac
  done
  printf '    +%s\n' "$line"
  "$@"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --app) [ $# -ge 2 ] || die "--app needs a path"; APP="$2"; shift 2 ;;
    --out) [ $# -ge 2 ] || die "--out needs a path"; OUT="$2"; shift 2 ;;
    --sign) [ $# -ge 2 ] || die "--sign needs an identity"; IDENTITY="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

[ -n "$APP" ] || die "missing --app"
[ -n "$OUT" ] || die "missing --out"
case "$OUT" in *.dmg) ;; *) die "--out must end in .dmg" ;; esac
APP="${APP%/}"
[ "$(basename "$APP")" = "Suijin.app" ] || die "--app must point at Suijin.app (got $APP)"
[ -d "$APP" ] || die "app not found: $APP"
command -v hdiutil >/dev/null || die "hdiutil not found"
command -v create-dmg >/dev/null || die "create-dmg not found (brew install create-dmg)"
ART="$(cd "$(dirname "$0")" && pwd)/dmg"
[ -f "$ART/background.tiff" ] && [ -f "$ART/VolumeIcon.icns" ] || die "installer pictures missing in $ART (run scripts/dmg/render.sh)"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo unknown)"
VOLUME="Suijin $VERSION"

STAGING="$(mktemp -d -t suijin-dmg)"
trap 'rm -rf "$STAGING"' EXIT

step "stage the app"
# `ditto` keeps the code signature, extended attributes and a stapled ticket intact.
run ditto "$APP" "$STAGING/Suijin.app"

step "create the compressed disk image with its installer window"
run mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
# The icon positions match the picture: the app at (180, 185), the Applications shortcut at (480, 185).
run create-dmg --volname "$VOLUME" --volicon "$ART/VolumeIcon.icns" --background "$ART/background.tiff" \
  --window-pos 200 120 --window-size 660 400 --icon-size 112 --text-size 13 \
  --icon Suijin.app 180 185 --hide-extension Suijin.app --app-drop-link 480 185 \
  --filesystem HFS+ --format UDZO --no-internet-enable "$OUT" "$STAGING"
[ -f "$OUT" ] || die "create-dmg did not write $OUT"

if [ "$IDENTITY" = "-" ]; then
  step "leave the disk image unsigned (--sign -)"
else
  step "sign the disk image with \"$IDENTITY\""
  run codesign --force --sign "$IDENTITY" --timestamp "$OUT"
  run codesign --verify --strict --verbose=2 "$OUT"
fi
step "created $OUT"
