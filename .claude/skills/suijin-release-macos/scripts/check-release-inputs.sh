#!/bin/bash
# Read-only checks before a Suijin release. Prints one PASS/FAIL/WARN line per check and exits non-zero when any
# check failed. Changes nothing, reads no secret (only whether the notary profile and the signing identity exist).
#
# Usage: check-release-inputs.sh [repository root]   (default: the git root of the current directory)
set -uo pipefail
ROOT="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$ROOT" || { echo "FAIL  cannot enter $ROOT"; exit 1; }
REPO="${SUIJIN_GITHUB_REPOSITORY:-Suijin-App/Suijin}"
FEED="https://suijin.app/appcast.xml"
TEAM="${SUIJIN_TEAM_ID:-YWSHDN5Y3H}"
PROFILE="${SUIJIN_NOTARY_PROFILE:-suijin-notary}"
FAILED=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; FAILED=1; }
warn() { printf 'WARN  %s\n' "$1"; }
setting() { sed -n "s/^ *$1: *\"\{0,1\}\([^\"]*\)\"\{0,1\} *$/\1/p" project.yml | head -1; }
plist() { /usr/libexec/PlistBuddy -c "Print :$1" App/Info.plist 2>/dev/null || true; }
# True when $1 is a higher dotted version than $2.
newer() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }

# --- repository state
branch="$(git branch --show-current)"
[ "$branch" = main ] && pass "on main" || fail "on branch \"$branch\", not main"
[ -z "$(git status --porcelain --untracked-files=no)" ] && pass "no uncommitted changes to tracked files" || fail "tracked files have uncommitted changes"
if git fetch -q origin main 2>/dev/null; then
  [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] && pass "main matches origin/main" || fail "main differs from origin/main (push or pull first)"
else
  fail "cannot fetch origin"
fi

# --- version against what is already released
VERSION="$(setting MARKETING_VERSION)"; BUILD="$(setting CURRENT_PROJECT_VERSION)"
[ -n "$VERSION" ] && [ -n "$BUILD" ] && pass "project.yml: version $VERSION, build $BUILD" || fail "cannot read the version from project.yml"
if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  pass "gh is signed in"
  last_tag="$(gh release list --repo "$REPO" --exclude-drafts --exclude-pre-releases --limit 1 --json tagName -q '.[0].tagName' 2>/dev/null || true)"
  if [ -z "$last_tag" ]; then
    pass "no earlier release: this is the first"
  else
    last_version="${last_tag#v}"
    newer "$VERSION" "$last_version" && pass "version $VERSION is higher than the last release $last_version" \
      || fail "version $VERSION is not higher than the last release $last_version (bump MARKETING_VERSION)"
    last_build="$(curl -fsSL -m 20 "https://github.com/$REPO/releases/download/$last_tag/appcast.xml" 2>/dev/null | sed -n 's/.*<sparkle:version>\([0-9]*\)<.*/\1/p' | head -1)"
    if [ -n "$last_build" ]; then
      [ "$BUILD" -gt "$last_build" ] 2>/dev/null && pass "build $BUILD is higher than the last release's build $last_build" \
        || fail "build $BUILD is not higher than the last release's build $last_build (bump CURRENT_PROJECT_VERSION; Sparkle compares builds)"
    else
      warn "could not read the last release's build number from its appcast; compare CURRENT_PROJECT_VERSION by hand"
    fi
  fi
  if gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1 || git ls-remote --exit-code --tags origin "v$VERSION" >/dev/null 2>&1; then
    fail "v$VERSION already exists as a release or tag"
  else
    pass "tag v$VERSION is free"
  fi
  open_prs="$(gh pr list --repo "$REPO" --state open --json number -q 'length' 2>/dev/null || echo '?')"
  [ "$open_prs" = 0 ] && pass "no open pull requests" || warn "$open_prs open pull request(s): decide whether they belong in this release"
else
  fail "gh is missing or not signed in"
fi

# --- changelog
if grep -q "^## $VERSION" CHANGELOG.md; then
  grep -q "^## $VERSION (unreleased)" CHANGELOG.md && warn "CHANGELOG.md still says \"$VERSION (unreleased)\": set the release date" || pass "CHANGELOG.md has a dated section for $VERSION"
else
  fail "CHANGELOG.md has no section for $VERSION"
fi

# --- signing, notarization, updates
security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application: .*($TEAM)" \
  && pass "Developer ID Application identity of team $TEAM is in the Keychain" || fail "no Developer ID Application identity of team $TEAM"
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
  && pass "notary profile \"$PROFILE\" works" || fail "notary profile \"$PROFILE\" is missing or rejected (xcrun notarytool store-credentials)"
[ "$(plist SUFeedURL)" = "$FEED" ] && pass "SUFeedURL is $FEED" || fail "SUFeedURL is not $FEED"
[ "$(printf '%s' "$(plist SUPublicEDKey)" | base64 -D 2>/dev/null | wc -c | tr -d ' ')" = 32 ] \
  && pass "SUPublicEDKey is a Sparkle public key" || fail "SUPublicEDKey is still the placeholder (generate_keys --account suijin)"
location="$(curl -sI -m 20 "$FEED" | tr -d '\r' | sed -n 's/^[Ll]ocation: //p' | head -1)"
[ "$location" = "https://github.com/$REPO/releases/latest/download/appcast.xml" ] \
  && pass "$FEED redirects to the latest release's appcast" || fail "$FEED does not redirect to the latest release's appcast (got: ${location:-no redirect})"
for tool in xcodegen xmllint; do command -v "$tool" >/dev/null && pass "$tool found" || fail "missing tool: $tool"; done

echo
[ "$FAILED" = 0 ] && echo "All checks passed." || echo "Some checks failed: fix them before releasing."
exit "$FAILED"
