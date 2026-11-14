#!/bin/bash
# Prints the update checks the suijin.app Worker counted, one line per day and app version, newest day first.
# A day's count approximates the copies of that version in use; "other" is everything that is not Suijin's updater.
#
# Usage: Tools/update-feed/checks.sh [day prefix, e.g. 2026-11]
# Needs `npx wrangler login` and CLOUDFLARE_ACCOUNT_ID set to the account that holds the suijin.app zone.
set -euo pipefail
cd "$(dirname "$0")"
PREFIX="checks:${1:-}"
keys="$(npx --yes wrangler@latest kv key list --binding CHECKS --remote --prefix "$PREFIX" 2>/dev/null \
  | sed -n 's/.*"name": *"\(checks:[^"]*\)".*/\1/p' | sort -r)"
[ -n "$keys" ] || { echo "No update checks counted yet${1:+ for $1}."; exit 0; }
printf '%-12s %-10s %s\n' DAY VERSION CHECKS
while IFS= read -r key; do
  count="$(npx --yes wrangler@latest kv key get "$key" --binding CHECKS --remote 2>/dev/null | tail -1)"
  day="${key#checks:}"; version="${day#*:}"; day="${day%%:*}"
  printf '%-12s %-10s %s\n' "$day" "$version" "$count"
done <<<"$keys"
