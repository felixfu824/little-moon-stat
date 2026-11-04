#!/bin/bash
# U1 (re-test): the live panel must keep updating every section after the granular-rendering change.
# Captures OUR OWN window by id only (screencapture -l) at rest, under a bounded all-core load, and after;
# records the wall clock at each capture. Defaults backed up/restored; app and load killed by PID.
# Usage: live_update.sh <helper bin dir> <repo root> <out dir>
set -uo pipefail
BIN="$1"; ROOT="$2"; OUT="$3"; mkdir -p "$OUT"
APP="$ROOT/build/MacMonitorPanel.app/Contents/MacOS/MacMonitorPanel"; DOM=com.felixfu.MacMonitorPanel
had=0; defaults export "$DOM" "$OUT/defaults-backup.plist" 2>/dev/null && had=1
PID=""; LP=""
cleanup() { [ -n "$LP" ] && kill "$LP" 2>/dev/null; [ -n "$PID" ] && kill "$PID" 2>/dev/null; sleep 1
  defaults delete "$DOM" 2>/dev/null; [ "$had" = 1 ] && defaults import "$DOM" "$OUT/defaults-backup.plist"; true; }
trap cleanup EXIT
defaults delete "$DOM" 2>/dev/null; defaults write "$DOM" size "${SIZE:-large}"
"$APP" 2> "$OUT/app.log" & PID=$!; sleep 8
ID="$("$BIN/winq" window "$PID" | grep 'layer=-1' | head -1 | sed -n 's/^id=\([0-9]*\).*/\1/p')"
cap() { screencapture -x -o -l "$ID" "$OUT/$1.png"; echo "$1 captured at $(date +%H:%M:%S) (own window $ID)"; }
cap a-rest
"$BIN/spin" "$(sysctl -n hw.ncpu)" 20 & LP=$!; sleep 17; cap b-load; wait "$LP"; LP=""
sleep 25; cap c-after
S=$(( 61 - $(date +%S) )); sleep "$S"; cap d-next-minute
grep -E "pause|resume" "$OUT/app.log" || echo "no pause/resume lines"
