#!/bin/bash
# Produce a release of Suijin outside the Mac App Store (docs/release-process.md):
#   archive (Release, hardened runtime) → export with Developer ID → check the nested PTY host helper is signed with
#   Developer ID, hardened runtime and a timestamp (re-sign inside out if not) → verify the app → notarize and staple
#   the app → DMG (scripts/make-dmg.sh) → notarize and staple the DMG → Gatekeeper checks → sign the DMG for Sparkle
#   and write appcast.xml.
#
#   Nothing is uploaded. The last lines print the `gh release create` command that publishes the DMG and the appcast
#   as a GitHub release; installed copies find it through https://suijin.app/appcast.xml (docs/release-process.md).
#
# Usage:
#   scripts/release-notarize.sh [--dry-run]
#
#   --dry-run  build, sign, verify and make the DMG for real, but skip everything that leaves this Mac or reads a
#              release secret: notarization, stapling and the Sparkle signature. Problems that would stop a real run (missing tools or
#              certificate) are listed at the end instead of stopping the run.
#              Without a Developer ID certificate it signs with Apple Development and says so.
#
# Environment (all optional; none of them holds a secret):
#   SUIJIN_NOTARY_PROFILE     notarytool keychain profile name (default: suijin-notary). The owner creates it once
#                             with `xcrun notarytool store-credentials`; the password stays in the Keychain.
#   SUIJIN_TEAM_ID            Apple team (default: YWSHDN5Y3H, Tekmium Solutions).
#   SUIJIN_SIGNING_IDENTITY   identity for re-signing and the DMG (default: the Developer ID Application identity of
#                             the team found in the Keychain).
#   SUIJIN_RELEASE_DIR        output folder (default: <repo>/build/release/<version>).
#   SUIJIN_SPARKLE_ACCOUNT    Keychain account of the Sparkle EdDSA key (default: suijin).
#   SUIJIN_GITHUB_REPOSITORY  owner/name of the repository whose releases hold the downloads
#                             (default: Suijin-App/Suijin).
#
# Nothing here writes or prints a private key or password: notarytool reads its profile from the login Keychain.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'release-notarize: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

NOTARY_PROFILE="${SUIJIN_NOTARY_PROFILE:-suijin-notary}"
TEAM_ID="${SUIJIN_TEAM_ID:-YWSHDN5Y3H}"
APP_ID="com.tekmium.suijin"
HELPER_ID="com.tekmium.suijin.ptyhost"
SPARKLE_ACCOUNT="${SUIJIN_SPARKLE_ACCOUNT:-suijin}"
GITHUB_REPOSITORY="${SUIJIN_GITHUB_REPOSITORY:-Suijin-App/Suijin}"
# The feed every installed copy asks. It is part of shipped builds, so it never changes; the redirect behind it does
# (Tools/update-feed).
FEED_URL="https://suijin.app/appcast.xml"

STEP=0
BLOCKERS=()
WARNINGS=()
step() { STEP=$((STEP + 1)); printf '\n==> %d. %s\n' "$STEP" "$1"; }
note() { printf '    %s\n' "$1"; }
warn() { WARNINGS+=("$1"); printf '    WARNING: %s\n' "$1"; }
die() { printf '\nrelease-notarize: %s\n' "$1" >&2; exit 1; }
# A problem that stops a real run. A dry run lists it and goes on.
block() {
  if [ "$DRY_RUN" = 1 ]; then BLOCKERS+=("$1"); note "would stop a real run: $1"; else die "$1"; fi
}
# Prints a command the way it would be typed, quoting arguments that contain spaces.
show() {
  local line="" arg
  for arg in "$@"; do
    case "$arg" in *[[:space:]]*) line+=" '$arg'" ;; *) line+=" $arg" ;; esac
  done
  printf '    +%s\n' "$line"
}
# Prints a command and runs it.
run() { show "$@"; "$@"; }
# Prints a command and runs it, except in a dry run (steps that leave this Mac or read a release secret).
run_real() {
  if [ "$DRY_RUN" = 1 ]; then show "$@"; note "(skipped in a dry run)"; else run "$@"; fi
}

project_setting() {
  sed -n "s/^ *$1: *\"\{0,1\}\([^\"]*\)\"\{0,1\} *$/\1/p" project.yml | head -1
}
plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true; }

VERSION="$(project_setting MARKETING_VERSION)"
BUILD_NUMBER="$(project_setting CURRENT_PROJECT_VERSION)"
[ -n "$VERSION" ] && [ -n "$BUILD_NUMBER" ] || die "cannot read MARKETING_VERSION / CURRENT_PROJECT_VERSION from project.yml"
OUT="${SUIJIN_RELEASE_DIR:-$ROOT/build/release/$VERSION}"
ARCHIVE="$OUT/Suijin.xcarchive"
EXPORT="$OUT/export"
APP="$EXPORT/Suijin.app"
HELPER="$APP/Contents/MacOS/SuijinPTYHost"
DERIVED="$OUT/DerivedData"
DMG="$OUT/Suijin-$VERSION.dmg"
APP_ZIP="$OUT/Suijin-$VERSION-notarize.zip"
EXPORT_OPTIONS="$OUT/ExportOptions.plist"
APPCAST="$OUT/appcast.xml"
TAG="v$VERSION"
DOWNLOAD_URL="https://github.com/$GITHUB_REPOSITORY/releases/download/$TAG/Suijin-$VERSION.dmg"
RELEASE_PAGE="https://github.com/$GITHUB_REPOSITORY/releases/tag/$TAG"
SPARKLE_BIN="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin"

printf 'Suijin release %s (%s)%s\n' "$VERSION" "$BUILD_NUMBER" \
  "$([ "$DRY_RUN" = 1 ] && echo ' — DRY RUN: builds and signs locally, nothing is notarized or published')"
note "output:          $OUT"
note "notary profile:  $NOTARY_PROFILE"

# ---------------------------------------------------------------------------------------------------------------------
step "check the tools and the release inputs"
for tool in xcodebuild xcodegen codesign spctl hdiutil ditto xmllint; do
  command -v "$tool" >/dev/null || die "missing tool: $tool"
done
for tool in notarytool stapler; do
  xcrun --find "$tool" >/dev/null 2>&1 || block "missing tool: xcrun $tool"
done
note "tools found"
# A release carries the feed and the public half of the key its updates are signed with; without both, installed
# copies could never update.
[ "$(plist_value App/Info.plist SUFeedURL)" = "$FEED_URL" ] || block "App/Info.plist: SUFeedURL is not $FEED_URL"
PUBLIC_KEY="$(plist_value App/Info.plist SUPublicEDKey)"
if [ "$(printf '%s' "$PUBLIC_KEY" | base64 -D 2>/dev/null | wc -c | tr -d ' ')" != 32 ]; then
  block "App/Info.plist: SUPublicEDKey is not a Sparkle public key yet (docs/release-process.md, \"Sparkle EdDSA key\")"
fi
MINIMUM_SYSTEM="$(sed -n 's/^ *macOS: *"\{0,1\}\([0-9.]*\)"\{0,1\} *$/\1/p' project.yml | head -1)"
[ -n "$MINIMUM_SYSTEM" ] || die "cannot read the macOS deployment target from project.yml"

# Lists certificate names only; private keys never leave the Keychain.
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
DEVELOPER_ID="$(sed -n "s/.*\"\(Developer ID Application: .*($TEAM_ID)\)\"/\1/p" <<<"$IDENTITIES" | head -1)"
EXPORT_METHOD="developer-id"
if [ -n "${SUIJIN_SIGNING_IDENTITY:-}" ]; then
  IDENTITY="$SUIJIN_SIGNING_IDENTITY"
elif [ -n "$DEVELOPER_ID" ]; then
  IDENTITY="$DEVELOPER_ID"
elif [ "$DRY_RUN" = 1 ]; then
  IDENTITY="$(sed -n 's/.*"\(Apple Development: .*\)"/\1/p' <<<"$IDENTITIES" | head -1)"
  [ -n "$IDENTITY" ] || die "no Developer ID Application or Apple Development identity in the Keychain"
  EXPORT_METHOD="debugging"
  warn "no \"Developer ID Application\" certificate of team $TEAM_ID: signing with \"$IDENTITY\"; Gatekeeper will reject this build"
  BLOCKERS+=("no Developer ID Application certificate of team $TEAM_ID in the Keychain")
else
  die "no \"Developer ID Application\" certificate of team $TEAM_ID in the Keychain"
fi
note "signing:         $IDENTITY (export method $EXPORT_METHOD)"

# ---------------------------------------------------------------------------------------------------------------------
step "generate the Xcode project and archive the Release configuration (hardened runtime)"
run rm -rf "$ARCHIVE" "$EXPORT"
run mkdir -p "$OUT"
run xcodegen generate --quiet
LOG="$OUT/archive.log"
show xcodebuild archive -project Suijin.xcodeproj -scheme Suijin -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" -derivedDataPath "$DERIVED" \
  -skipPackagePluginValidation -allowProvisioningUpdates -packageAuthorizationProvider netrc \
  ENABLE_HARDENED_RUNTIME=YES DEVELOPMENT_TEAM="$TEAM_ID"
note "(log: $LOG)"
xcodebuild archive -project Suijin.xcodeproj -scheme Suijin -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" -derivedDataPath "$DERIVED" \
  -skipPackagePluginValidation -allowProvisioningUpdates -packageAuthorizationProvider netrc \
  ENABLE_HARDENED_RUNTIME=YES DEVELOPMENT_TEAM="$TEAM_ID" >"$LOG" 2>&1 \
  || { grep -E "error:" "$LOG" | sort -u | head -20 >&2; die "archive failed; see $LOG"; }
[ -x "$ARCHIVE/Products/Applications/Suijin.app/Contents/MacOS/SuijinPTYHost" ] \
  || die "the archived app does not contain Contents/MacOS/SuijinPTYHost"
note "archived $ARCHIVE"

# ---------------------------------------------------------------------------------------------------------------------
step "export the archive ($EXPORT_METHOD)"
cat >"$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>$EXPORT_METHOD</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
</dict>
</plist>
PLIST
LOG="$OUT/export.log"
show xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" -exportOptionsPlist "$EXPORT_OPTIONS" \
  -allowProvisioningUpdates
if ! xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" -exportOptionsPlist "$EXPORT_OPTIONS" \
    -allowProvisioningUpdates >"$LOG" 2>&1; then
  grep -E "error:" "$LOG" | sort -u | head -20 >&2
  [ "$EXPORT_METHOD" = "debugging" ] || die "export failed; see $LOG"
  # A development export needs a provisioning profile for this Mac; the archived app is already signed with the
  # same development identity, so a dry run can go on with it and re-sign below.
  warn "development export failed (see $LOG); using the archived app"
  run mkdir -p "$EXPORT"
  run ditto "$ARCHIVE/Products/Applications/Suijin.app" "$APP"
fi
[ -d "$APP" ] || die "export produced no Suijin.app in $EXPORT"
note "exported $APP"

# ---------------------------------------------------------------------------------------------------------------------
step "check the nested PTY host helper signature"
# Expected for a release: Developer ID authority of the team, hardened runtime, a secure timestamp, its own identifier.
helper_signature_ok() {
  local details
  details="$(codesign -dvvv "$HELPER" 2>&1)" || return 1
  printf '%s\n' "$details" | grep -E '^(Identifier|Authority|TeamIdentifier|Timestamp|CodeDirectory)' | sed 's/^/      /'
  grep -q "^Identifier=$HELPER_ID$" <<<"$details" || { note "helper identifier is not $HELPER_ID"; return 1; }
  grep -q "^TeamIdentifier=$TEAM_ID$" <<<"$details" || { note "helper is not signed by team $TEAM_ID"; return 1; }
  grep -Eq "flags=0x[0-9a-f]+\(.*runtime.*\)" <<<"$details" || { note "helper has no hardened runtime"; return 1; }
  grep -q "^Timestamp=" <<<"$details" || { note "helper has no secure timestamp"; return 1; }
  if [ "$EXPORT_METHOD" = "developer-id" ]; then
    grep -q "^Authority=Developer ID Application" <<<"$details" || { note "helper is not signed with Developer ID"; return 1; }
  fi
}
if helper_signature_ok; then
  note "helper signed as expected by the export"
else
  # Re-sign inside out: the helper first, then the app around it. The app keeps its entitlements; Sparkle's nested
  # code was signed by the export and is left untouched (never `codesign --deep` to sign).
  note "re-signing the helper and the app (inside out)"
  APP_ENTITLEMENTS="$OUT/app-entitlements.plist"
  codesign -d --entitlements - --xml "$APP" >"$APP_ENTITLEMENTS" 2>/dev/null || die "cannot read the app's entitlements"
  run codesign --force --sign "$IDENTITY" --options runtime --timestamp --identifier "$HELPER_ID" "$HELPER"
  run codesign --force --sign "$IDENTITY" --options runtime --timestamp --entitlements "$APP_ENTITLEMENTS" "$APP"
  helper_signature_ok || die "the helper is still not signed correctly after re-signing"
fi

# ---------------------------------------------------------------------------------------------------------------------
step "verify the app signature and hardened runtime"
run codesign --verify --deep --strict --verbose=2 "$APP"
details="$(codesign -dvvv "$APP" 2>&1)"
grep -q "^Identifier=$APP_ID$" <<<"$details" || die "the app identifier is not $APP_ID"
grep -q "^TeamIdentifier=$TEAM_ID$" <<<"$details" || die "the app is not signed by team $TEAM_ID"
grep -Eq "flags=0x[0-9a-f]+\(.*runtime.*\)" <<<"$details" || die "the app's hardened runtime is off"
grep -q "^Timestamp=" <<<"$details" || die "the app signature has no secure timestamp"
if grep -q "^Authority=Developer ID Application" <<<"$details"; then
  note "app signed with Developer ID, hardened runtime, timestamped"
elif [ "$EXPORT_METHOD" = "developer-id" ]; then
  die "the app is not signed with Developer ID"
else
  note "app signed with $IDENTITY (development fallback), hardened runtime, timestamped"
fi
if codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "get-task-allow"; then
  if [ "$EXPORT_METHOD" = "developer-id" ]; then
    die "the app still carries the debugging entitlement get-task-allow"
  else
    note "get-task-allow present (expected for a development fallback build)"
  fi
fi
[ -f "$APP/Contents/Library/LaunchAgents/$HELPER_ID.plist" ] || die "the LaunchAgent plist is missing from the app"
[ -d "$APP/Contents/Frameworks/Sparkle.framework" ] || die "Sparkle.framework is not embedded in the app"
[ "$(plist_value "$APP/Contents/Info.plist" CFBundleShortVersionString)" = "$VERSION" ] \
  || die "the exported app's version is not $VERSION"
[ "$(plist_value "$APP/Contents/Info.plist" CFBundleVersion)" = "$BUILD_NUMBER" ] \
  || die "the exported app's build is not $BUILD_NUMBER"

# ---------------------------------------------------------------------------------------------------------------------
# One submission for the app (so its ticket can be stapled before it goes into the DMG), one for the DMG (so the
# download opens offline without a warning).
notarize() {
  local file="$1" result status id
  show xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json
  if [ "$DRY_RUN" = 1 ]; then
    note "(skipped in a dry run; the profile is not looked up because that contacts Apple)"
    return 0
  fi
  result="$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)" \
    || die "notarytool could not submit $file (is the profile \"$NOTARY_PROFILE\" stored? see docs/release-process.md)"
  status="$(plutil -extract status raw -o - - <<<"$result" 2>/dev/null || true)"
  id="$(plutil -extract id raw -o - - <<<"$result" 2>/dev/null || true)"
  if [ "$status" != "Accepted" ]; then
    [ -z "$id" ] || xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    die "notarization of $file ended with status \"${status:-unknown}\""
  fi
  note "accepted (submission $id)"
}

step "notarize the app (keychain profile \"$NOTARY_PROFILE\")"
run rm -f "$APP_ZIP"
run ditto -c -k --sequesterRsrc --keepParent "$APP" "$APP_ZIP"
notarize "$APP_ZIP"

step "staple the notarization ticket to the app"
run_real xcrun stapler staple "$APP"
run_real xcrun stapler validate "$APP"

# ---------------------------------------------------------------------------------------------------------------------
step "create and sign the DMG"
run bash "$ROOT/scripts/make-dmg.sh" --app "$APP" --out "$DMG" --sign "$IDENTITY"

step "notarize and staple the DMG"
notarize "$DMG"
run_real xcrun stapler staple "$DMG"
run_real xcrun stapler validate "$DMG"

# ---------------------------------------------------------------------------------------------------------------------
step "Gatekeeper and signature checks"
run codesign --verify --deep --strict --verbose=2 "$APP"
show spctl --assess --type execute -vv "$APP"
assessment="$(spctl --assess --type execute -vv "$APP" 2>&1 || true)"
printf '%s\n' "$assessment" | sed 's/^/      /'
if grep -q "source=Notarized Developer ID" <<<"$assessment"; then
  note "Gatekeeper: accepted, source=Notarized Developer ID"
elif [ "$DRY_RUN" = 1 ]; then
  note "not notarized yet (expected in a dry run)"
else
  die "Gatekeeper does not report the app as \"Notarized Developer ID\""
fi
show spctl --assess --type open --context context:primary-signature -vv "$DMG"
dmg_assessment="$(spctl --assess --type open --context context:primary-signature -vv "$DMG" 2>&1 || true)"
printf '%s\n' "$dmg_assessment" | sed 's/^/      /'
[ "$DRY_RUN" = 1 ] || grep -q "accepted" <<<"$dmg_assessment" || die "Gatekeeper rejects the DMG"

# ---------------------------------------------------------------------------------------------------------------------
step "sign the DMG for Sparkle and write the appcast"
[ -x "$SPARKLE_BIN/sign_update" ] || die "Sparkle's sign_update is missing from $SPARKLE_BIN"
run rm -f "$APPCAST"
show "$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" "$DMG"
if [ "$DRY_RUN" = 1 ]; then
  note "(skipped in a dry run: signing reads the private key; no appcast is written)"
else
  # Prints `sparkle:edSignature="…" length="…"`; the private key stays in the login Keychain.
  SIGNATURE="$("$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" "$DMG")" \
    || die "sign_update failed (is the Sparkle key stored under the account \"$SPARKLE_ACCOUNT\"? see docs/release-process.md)"
  grep -q 'sparkle:edSignature="[^"]\{1,\}" length="[0-9]\{1,\}"' <<<"$SIGNATURE" || die "unexpected sign_update output"
  # The key that signed must be the one the app trusts, or no installed copy accepts the update.
  KEYCHAIN_PUBLIC_KEY="$("$SPARKLE_BIN/generate_keys" --account "$SPARKLE_ACCOUNT" -p 2>/dev/null || true)"
  [ "$KEYCHAIN_PUBLIC_KEY" = "$PUBLIC_KEY" ] \
    || die "the Sparkle key in the Keychain is not the one in App/Info.plist (SUPublicEDKey)"
  cat >"$APPCAST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Suijin</title>
    <link>$FEED_URL</link>
    <description>Updates of Suijin</description>
    <language>en</language>
    <item>
      <title>$VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINIMUM_SYSTEM</sparkle:minimumSystemVersion>
      <description><![CDATA[<p>Suijin $VERSION. <a href="$RELEASE_PAGE">Release notes</a></p>]]></description>
      <enclosure url="$DOWNLOAD_URL" $SIGNATURE type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
  run xmllint --noout "$APPCAST"
  note "appcast: $APPCAST"
fi

# ---------------------------------------------------------------------------------------------------------------------
printf '\n'
if [ "$DRY_RUN" = 1 ]; then
  printf 'Dry run finished: %d steps. Built and signed:\n  %s\n  %s\n' "$STEP" "$APP" "$DMG"
  if [ "${#WARNINGS[@]}" -gt 0 ]; then
    printf 'Warnings:\n'
    for warning in "${WARNINGS[@]}"; do printf '  - %s\n' "$warning"; done
  fi
  if [ "${#BLOCKERS[@]}" -eq 0 ]; then
    printf 'Nothing found that blocks a real run (the notary profile is only checked by a real run).\n'
  else
    printf 'A real run would stop at:\n'
    for blocker in "${BLOCKERS[@]}"; do printf '  - %s\n' "$blocker"; done
  fi
else
  printf 'Release %s ready:\n  %s\n  %s\n  %s\nNothing was published. To publish (the DMG first, then the appcast):\n' "$VERSION" "$APP" "$DMG" "$APPCAST"
  printf '  gh release create %s %s %s --repo %s --title "Suijin %s" --notes-file <release-notes.md>\n' \
    "$TAG" "$DMG" "$APPCAST" "$GITHUB_REPOSITORY" "$VERSION"
fi
