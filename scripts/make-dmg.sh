#!/bin/bash
# Package a signed (normally notarized and stapled) Sevinda.app into a compressed DMG with an Applications shortcut
# to drag it onto, then sign the DMG. Called by scripts/release-notarize.sh; can also run alone.
#
# Usage:
#   scripts/make-dmg.sh --app <path/to/Sevinda.app> --out <path/to/Sevinda-0.1.0.dmg> [--sign <identity>]
#
#   --sign  codesign identity for the DMG (default: $SEVINDA_SIGNING_IDENTITY, else "Developer ID Application").
#           Pass --sign - to leave the DMG unsigned (local testing only; Gatekeeper rejects it).
#
# No credentials are read or stored here: codesign uses the certificate already in the login Keychain.
set -euo pipefail

APP=""
OUT=""
IDENTITY="${SEVINDA_SIGNING_IDENTITY:-Developer ID Application}"

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
[ "$(basename "$APP")" = "Sevinda.app" ] || die "--app must point at Sevinda.app (got $APP)"
[ -d "$APP" ] || die "app not found: $APP"
command -v hdiutil >/dev/null || die "hdiutil not found"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo unknown)"
VOLUME="Sevinda $VERSION"

STAGING="$(mktemp -d -t sevinda-dmg)"
trap 'rm -rf "$STAGING"' EXIT

step "stage the app with an Applications shortcut"
# `ditto` keeps the code signature, extended attributes and a stapled ticket intact.
run ditto "$APP" "$STAGING/Sevinda.app"
run ln -s /Applications "$STAGING/Applications"

step "create the compressed disk image"
run mkdir -p "$(dirname "$OUT")"
run hdiutil create -quiet -volname "$VOLUME" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$OUT"

if [ "$IDENTITY" = "-" ]; then
  step "leave the disk image unsigned (--sign -)"
else
  step "sign the disk image with \"$IDENTITY\""
  run codesign --force --sign "$IDENTITY" --timestamp "$OUT"
  run codesign --verify --strict --verbose=2 "$OUT"
fi
step "created $OUT"
