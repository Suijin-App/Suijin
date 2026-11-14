#!/bin/bash
# Checks a published release the way an installed copy meets it: through the feed, then the download. Read-only.
# Exits non-zero when any check failed.
#
# Usage: verify-published-release.sh [repository root]
set -uo pipefail
ROOT="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$ROOT" || exit 1
REPO="${SUIJIN_GITHUB_REPOSITORY:-Suijin-App/Suijin}"
FEED="https://suijin.app/appcast.xml"
setting() { sed -n "s/^ *$1: *\"\{0,1\}\([^\"]*\)\"\{0,1\} *$/\1/p" project.yml | head -1; }
VERSION="$(setting MARKETING_VERSION)"
OUT="${SUIJIN_RELEASE_DIR:-$ROOT/build/release/$VERSION}"
DMG="$OUT/Suijin-$VERSION.dmg"; APPCAST="$OUT/appcast.xml"
FAILED=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; FAILED=1; }
WORK="$(mktemp -d -t suijin-published)"; trap 'rm -rf "$WORK"' EXIT

state="$(gh release view "v$VERSION" --repo "$REPO" --json isDraft,isPrerelease -q '"\(.isDraft) \(.isPrerelease)"' 2>/dev/null || true)"
[ "$state" = "false false" ] && pass "v$VERSION is published (not a draft, not a pre-release)" || fail "v$VERSION is missing, a draft or a pre-release (releases/latest ignores those)"
latest="$(gh release list --repo "$REPO" --exclude-drafts --exclude-pre-releases --limit 1 --json tagName -q '.[0].tagName' 2>/dev/null || true)"
[ "$latest" = "v$VERSION" ] && pass "v$VERSION is the latest release" || fail "the latest release is ${latest:-none}, not v$VERSION"

if curl -fsSL -m 60 "$FEED" -o "$WORK/appcast.xml"; then
  pass "$FEED answers"
  cmp -s "$WORK/appcast.xml" "$APPCAST" && pass "the feed serves the appcast that was built" || fail "the feed serves a different appcast than $APPCAST"
else
  fail "$FEED does not answer"
fi
url="$(sed -n 's/.*<enclosure .*url="\([^"]*\)".*/\1/p' "$WORK/appcast.xml" 2>/dev/null | head -1)"
length="$(sed -n 's/.*<enclosure .*length="\([^"]*\)".*/\1/p' "$WORK/appcast.xml" 2>/dev/null | head -1)"
if [ -n "$url" ] && curl -fsSL -m 600 "$url" -o "$WORK/download.dmg"; then
  pass "the download in the appcast answers"
  [ "$(stat -f %z "$WORK/download.dmg")" = "$length" ] && pass "the download has the length the appcast names" || fail "the download's size is not the appcast's length"
  [ "$(shasum -a 256 "$WORK/download.dmg" | cut -d' ' -f1)" = "$(shasum -a 256 "$DMG" | cut -d' ' -f1)" ] \
    && pass "the download is byte for byte the DMG that was built" || fail "the download differs from $DMG"
  spctl --assess --type open --context context:primary-signature -vv "$WORK/download.dmg" 2>&1 | grep -q accepted \
    && pass "the download is accepted by Gatekeeper" || fail "the download is rejected by Gatekeeper"
else
  fail "the download in the appcast does not answer (${url:-no URL})"
fi

echo
[ "$FAILED" = 0 ] && echo "The published release is what was built." || echo "The published release has problems: see the failures above."
exit "$FAILED"
