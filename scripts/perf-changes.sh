#!/bin/bash
# Measures the Changes tab of a built Suijin: scripts/perf-changes.sh <Suijin.app> <repository> [<repository>…]
#
# The app must be a development build (Debug, or Release with SWIFT_ACTIVE_COMPILATION_CONDITIONS=SUIJIN_PERF) so it
# carries PerfChangesProbe. The probe rewrites a file in every checkout, so pass copies, not your own repositories.
#
# The app runs on a new data root and its own PTY host service name, so it never reaches your workspaces, sessions or
# helper. It shares the UserDefaults domain of the installed app; the keys it changes are put back when it quits.
# Every 0.2 s the script samples the app's child git processes, CPU and memory, then prints one row per phase.
set -uo pipefail
if [ $# -lt 2 ]; then
  echo "usage: $0 <Suijin.app> <repository> [<repository>…]" >&2
  exit 2
fi
APP="$1"
shift
REPOS="$(IFS=:; echo "$*")"
RUN="$(mktemp -d -t suijin-perf-changes)"
DOMAIN="com.tekmium.suijin"

defaults export "$DOMAIN" "$RUN/defaults-before.plist"

SUIJIN_DATA_ROOT="$RUN/data" \
SUIJIN_PTYHOST_SERVICE="com.tekmium.suijin.ptyhost.perf" \
SUIJIN_PERF_OUT="$RUN/probe.jsonl" \
SUIJIN_PERF_SCENARIO=changes \
SUIJIN_PERF_REPOS="$REPOS" \
  "$APP/Contents/MacOS/Suijin" > "$RUN/app.log" 2>&1 &
PID=$!
echo "Measuring (pid $PID), results in $RUN"

# Wall-clock time, child git processes, app CPU % and resident memory (KB), every 0.2 s while the app runs.
python3 -I - "$PID" "$RUN/samples.tsv" <<'PY' &
import os, subprocess, sys, time
pid, out = int(sys.argv[1]), sys.argv[2]
with open(out, "w") as f:
    while True:
        try:
            os.kill(pid, 0)
        except OSError:
            break
        children = subprocess.run(["pgrep", "-P", str(pid), "-x", "git"], capture_output=True, text=True).stdout.split()
        stat = subprocess.run(["ps", "-o", "%cpu=,rss=", "-p", str(pid)], capture_output=True, text=True).stdout.split()
        cpu, rss = (stat + ["0", "0"])[:2]
        f.write(f"{time.time():.3f}\t{len(children)}\t{cpu}\t{rss}\n")
        f.flush()
        time.sleep(0.2)
PY
SAMPLER=$!

# The probe quits the app when it is done; after 15 minutes the process this script started is stopped.
for _ in $(seq 1 900); do
  kill -0 "$PID" 2>/dev/null || break
  sleep 1
done
if kill -0 "$PID" 2>/dev/null; then
  echo "Timed out; stopping pid $PID" >&2
  kill -TERM "$PID"
  sleep 5
fi
wait "$SAMPLER" 2>/dev/null

# Put back the defaults keys the run changed and keep every other key as it is now.
defaults export "$DOMAIN" "$RUN/defaults-after.plist"
python3 -I - "$RUN/defaults-before.plist" "$RUN/defaults-after.plist" "$RUN/defaults-restored.plist" <<'PY'
import plistlib, sys
before = plistlib.load(open(sys.argv[1], "rb"))
after = plistlib.load(open(sys.argv[2], "rb"))
merged = dict(after)
for key in set(before) | set(after):
    if before.get(key) != after.get(key):
        if key in before:
            merged[key] = before[key]
        else:
            merged.pop(key, None)
plistlib.dump(merged, open(sys.argv[3], "wb"))
PY
defaults import "$DOMAIN" "$RUN/defaults-restored.plist"

# One row per target and phase: the main run loop (from the probe) next to git, CPU and memory (from the samples).
python3 -I - "$RUN" <<'PY'
import json, sys
run = sys.argv[1]
probe = [json.loads(line) for line in open(f"{run}/probe.jsonl")]
samples = [tuple(float(v) for v in line.split("\t")) for line in open(f"{run}/samples.tsv")]
for record in probe:
    if "error" in record:
        print("error:", record)
print(f"{'target':<20}{'phase':<7}{'busy%':>7}{'maxTurn ms':>12}{'git max':>9}{'git proc·s':>12}{'cpu%':>7}{'MB':>7}")
for record in probe:
    if "t0" not in record:
        continue
    window = [s for s in samples if record["t0"] <= s[0] <= record["t1"]] or [(0, 0, 0, 0)]
    gits = [s[1] for s in window]
    print(f"{record['target'][:19]:<20}{record['name']:<7}{record['busyPct']:>7.1f}{record['maxTurnMs']:>12.0f}"
          f"{max(gits):>9.0f}{sum(gits) * 0.2:>12.1f}{sum(s[2] for s in window) / len(window):>7.0f}"
          f"{max(s[3] for s in window) / 1024:>7.0f}")
print("completed" if any(r.get("name") == "done" for r in probe) else "did NOT complete")
PY
