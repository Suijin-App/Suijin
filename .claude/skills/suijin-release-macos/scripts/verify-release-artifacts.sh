#!/bin/bash
# Checks what scripts/release-notarize.sh produced, before anything is published. Read-only apart from mounting the
# DMG read-only for a moment. Exits non-zero when any check failed.
#
# Usage: verify-release-artifacts.sh [repository root]
set -uo pipefail
ROOT="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$ROOT" || exit 1
REPO="${SUIJIN_GITHUB_REPOSITORY:-Suijin-App/Suijin}"
setting() { sed -n "s/^ *$1: *\"\{0,1\}\([^\"]*\)\"\{0,1\} *$/\1/p" project.yml | head -1; }
VERSION="$(setting MARKETING_VERSION)"; BUILD="$(setting CURRENT_PROJECT_VERSION)"
OUT="${SUIJIN_RELEASE_DIR:-$ROOT/build/release/$VERSION}"
DMG="$OUT/Suijin-$VERSION.dmg"; APPCAST="$OUT/appcast.xml"; APP="$OUT/export/Suijin.app"
FAILED=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; FAILED=1; }
field() { sed -n "s/.*<$1>\([^<]*\)<.*/\1/p" "$APPCAST" | head -1; }
attribute() { sed -n "s/.*<enclosure .*$1=\"\([^\"]*\)\".*/\1/p" "$APPCAST" | head -1; }

for file in "$DMG" "$APPCAST"; do [ -f "$file" ] && pass "exists: ${file#$ROOT/}" || fail "missing: ${file#$ROOT/}"; done
[ -d "$APP" ] && pass "exists: ${APP#$ROOT/}" || fail "missing: ${APP#$ROOT/}"
[ "$FAILED" = 0 ] || { echo; echo "Run scripts/release-notarize.sh first."; exit 1; }

# --- the app and the DMG as Gatekeeper sees them
spctl --assess --type execute -vv "$APP" 2>&1 | grep -q "source=Notarized Developer ID" && pass "app: Notarized Developer ID" || fail "app is not accepted as Notarized Developer ID"
xcrun stapler validate "$APP" >/dev/null 2>&1 && pass "app: notarization ticket stapled" || fail "app has no stapled ticket"
xcrun stapler validate "$DMG" >/dev/null 2>&1 && pass "DMG: notarization ticket stapled" || fail "DMG has no stapled ticket"
spctl --assess --type open --context context:primary-signature -vv "$DMG" 2>&1 | grep -q accepted && pass "DMG: accepted by Gatekeeper" || fail "DMG is rejected by Gatekeeper"

# --- what is inside the DMG
MOUNT="$(mktemp -d -t suijin-verify)"
if hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MOUNT" "$DMG"; then
  inner="$MOUNT/Suijin.app/Contents/Info.plist"
  value() { /usr/libexec/PlistBuddy -c "Print :$1" "$inner" 2>/dev/null || true; }
  [ "$(value CFBundleShortVersionString)" = "$VERSION" ] && pass "DMG app version is $VERSION" || fail "DMG app version is $(value CFBundleShortVersionString), not $VERSION"
  [ "$(value CFBundleVersion)" = "$BUILD" ] && pass "DMG app build is $BUILD" || fail "DMG app build is $(value CFBundleVersion), not $BUILD"
  [ "$(value SUFeedURL)" = "https://suijin.app/appcast.xml" ] && pass "DMG app asks https://suijin.app/appcast.xml" || fail "DMG app has the wrong SUFeedURL"
  [ -L "$MOUNT/Applications" ] && pass "DMG has the Applications shortcut" || fail "DMG has no Applications shortcut"
  hdiutil detach -quiet "$MOUNT" || true
  scripts/dmg/check-layout.sh "$DMG" 2>/dev/null && pass "DMG opens as the installer window (background picture set)" || fail "DMG opens as a plain window: Finder's settings name no background picture"
else
  fail "cannot mount the DMG"
fi
rmdir "$MOUNT" 2>/dev/null || true

# --- the appcast
xmllint --noout "$APPCAST" 2>/dev/null && pass "appcast is well-formed XML" || fail "appcast is not well-formed"
[ "$(field sparkle:shortVersionString)" = "$VERSION" ] && pass "appcast version is $VERSION" || fail "appcast version is $(field sparkle:shortVersionString)"
[ "$(field sparkle:version)" = "$BUILD" ] && pass "appcast build is $BUILD" || fail "appcast build is $(field sparkle:version)"
[ "$(attribute url)" = "https://github.com/$REPO/releases/download/v$VERSION/Suijin-$VERSION.dmg" ] && pass "appcast download URL matches the release asset" || fail "appcast download URL is $(attribute url)"
[ "$(attribute length)" = "$(stat -f %z "$DMG")" ] && pass "appcast length equals the DMG's size" || fail "appcast length $(attribute length) is not the DMG's size $(stat -f %z "$DMG")"
[ -n "$(attribute sparkle:edSignature)" ] && pass "appcast carries an EdDSA signature" || fail "appcast has no EdDSA signature"

echo
shasum -a 256 "$DMG" | awk '{print "DMG sha256: " $1}'
[ "$FAILED" = 0 ] && echo "Artifacts are consistent." || echo "Do not publish: fix the failures above."
exit "$FAILED"
