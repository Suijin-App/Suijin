#!/bin/bash
# Launches a separate copy of the built Suijin on its own data folder, as the frontmost app in a wide window, captures
# that window to a PNG, then quits that copy. The user's own running Suijin and its data are not touched.
#
# Usage: capture-window.sh --data-root <dir> --out <file.png> [--wait <seconds>] [--size <WxH>] [--app <Suijin.app>]
#                          [-- <launch arguments, e.g. -SuijinInitialSettings general>]
#
# The window frame is passed through the app's saved-frame default, so this script saves that default first and
# restores it afterwards. See references/screenshots.md for the launch arguments and the privacy rules.
set -euo pipefail
DATA_ROOT=""; OUT=""; WAIT=9; SIZE="1480x850"; APP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --data-root) DATA_ROOT="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --wait) WAIT="$2"; shift 2 ;;
    --size) SIZE="$2"; shift 2 ;;
    --app) APP="$2"; shift 2 ;;
    --) shift; break ;;
    *) echo "capture-window: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$DATA_ROOT" ] && [ -n "$OUT" ] || { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
if [ -z "$APP" ]; then
  APP="$(ls -dt "$HOME"/Library/Developer/Xcode/DerivedData/Suijin-*/Build/Products/Debug/Suijin.app 2>/dev/null | head -1)"
fi
[ -d "$APP" ] || { echo "capture-window: no built Suijin.app found; build the app or pass --app" >&2; exit 1; }
mkdir -p "$DATA_ROOT" "$(dirname "$OUT")"

DOMAIN="com.tekmium.suijin"; KEY="NSWindow Frame main"
saved_frame="$(defaults read "$DOMAIN" "$KEY" 2>/dev/null || true)"
restore() {
  if [ -n "$saved_frame" ]; then defaults write "$DOMAIN" "$KEY" "$saved_frame"; else defaults delete "$DOMAIN" "$KEY" 2>/dev/null || true; fi
}
trap restore EXIT
defaults write "$DOMAIN" "$KEY" "16 50 ${SIZE%x*} ${SIZE#*x} 0 0 1512 949 "

# Lists "<window id> <width> <height>" for the on-screen windows of one process.
windows() {
  swift - "$1" <<'SWIFT'
import CoreGraphics
import Foundation
let wanted = Int32(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for window in list where (window[kCGWindowOwnerPID as String] as? Int32) == wanted {
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    print(window[kCGWindowNumber as String] ?? "", bounds["Width"] ?? "", bounds["Height"] ?? "")
}
SWIFT
}

before="$(pgrep -f "$APP/Contents/MacOS/Suijin" | tr '\n' ' ' || true)"
# The saved window state would override the frame, so it is ignored for this launch.
open -n --env "SUIJIN_DATA_ROOT=$DATA_ROOT" "$APP" --args -ApplePersistenceIgnoreState YES "$@"
sleep "$WAIT"
pid=""
for candidate in $(pgrep -f "$APP/Contents/MacOS/Suijin" || true); do
  case " $before " in *" $candidate "*) ;; *) pid="$candidate" ;; esac
done
[ -n "$pid" ] || { echo "capture-window: the launched copy was not found" >&2; exit 1; }
# The widest window is the main one; pass --wait longer if a dialog should be captured separately.
id="$(windows "$pid" | sort -k2 -n -r | head -1 | cut -d' ' -f1)"
status=0
if [ -n "$id" ]; then screencapture -x -o -l "$id" "$OUT" || status=1; else echo "capture-window: no window to capture" >&2; status=1; fi
kill -TERM "$pid" 2>/dev/null || true
sleep 2
[ "$status" = 0 ] && echo "captured: $OUT"
exit "$status"
