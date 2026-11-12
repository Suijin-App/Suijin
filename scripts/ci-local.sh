#!/bin/bash
# Source of truth for "is the code tree healthy". Every phase must pass this script before closing.
#
# Usage:
#   scripts/ci-local.sh            everything
#   scripts/ci-local.sh checks     static checks only (English comments)
#   scripts/ci-local.sh packages   `swift test` for each package only
#   scripts/ci-local.sh app        app build + app tests
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FAILED=0
step() { printf "\n\033[1m==> %s\033[0m\n" "$1"; }
ok()   { printf "    \033[32m✓\033[0m %s\n" "$1"; }
bad()  { printf "    \033[31m✗\033[0m %s\n" "$1"; FAILED=1; }
WHAT="${1:-all}"
LOG_DIR="$(mktemp -d -t mercury-ci)"

[ -d Mercury.xcodeproj ] || scripts/bootstrap.sh >/dev/null

if [ "$WHAT" = all ] || [ "$WHAT" = checks ]; then
  step "Code comments (English)"
  if out=$(Tools/comment-lint/comment-lint.py 2>&1); then ok "${out##*$'\n'}"; else bad "non-English comments"; printf '%s\n' "$out" | head -20; fi
fi

if [ "$WHAT" = all ] || [ "$WHAT" = packages ]; then
  step "Package tests"
  for pkg in Packages/*/; do
    name="$(basename "$pkg")"
    if swift test --package-path "$pkg" >"$LOG_DIR/$name.log" 2>&1; then
      ok "$name ($(grep -Eo 'with [0-9]+ tests?' "$LOG_DIR/$name.log" | tail -1))"
      if grep -qE "warning: .*\.swift" "$LOG_DIR/$name.log"; then
        bad "$name has compiler warnings"; grep -E "warning: .*\.swift" "$LOG_DIR/$name.log" | grep -v '/.build/checkouts/' | sort -u | head -5
      fi
    else
      bad "$name — see $LOG_DIR/$name.log"
      grep -E "error:|✘" "$LOG_DIR/$name.log" | head -8
    fi
  done
fi

if [ "$WHAT" = all ] || [ "$WHAT" = app ]; then
  step "App build + tests"
  # SwiftTerm ships a build-tool plugin; command-line builds must skip the interactive trust prompt.
  if xcodebuild -project Mercury.xcodeproj -scheme Mercury -destination 'platform=macOS,arch=arm64' \
      -skipPackagePluginValidation -packageAuthorizationProvider netrc -allowProvisioningUpdates test >"$LOG_DIR/app.log" 2>&1; then
    ok "$(grep -aEo 'Test run with [0-9]+ tests? in [0-9]+ suites? passed' "$LOG_DIR/app.log" | tail -1)"
    if grep -E "warning: .*\.swift" "$LOG_DIR/app.log" | grep -qv '/SourcePackages/checkouts/'; then
      bad "compiler warnings"; grep -E "warning: .*\.swift" "$LOG_DIR/app.log" | grep -v '/SourcePackages/checkouts/' | sort -u | head -10
    fi
  else
    bad "app build/test failed — see $LOG_DIR/app.log"
    grep -E "error:|failed" "$LOG_DIR/app.log" | sort -u | head -10
  fi
fi

echo
if [ "$FAILED" -eq 0 ]; then printf "\033[32m✓ ci-local green\033[0m\n"; rm -rf "$LOG_DIR"; else printf "\033[31m✗ ci-local red (logs: %s)\033[0m\n" "$LOG_DIR"; fi
exit "$FAILED"
