#!/bin/bash
# Independent whole-app soak: visible Large/clear panel, real engine, CPU incl. waited-for children
# (/usr/bin/time), RSS + panel visibility every 60 s, `leaks` on our own pid at the end.
# Defaults domain backed up and restored; the app is killed by PID. No screen capture.
# Usage: soak_rss.sh <seconds> <helper bin dir> <repo root> <out dir>
set -uo pipefail
SECS="$1"; BIN="$2"; ROOT="$3"; OUT="$4"; mkdir -p "$OUT"
APP="$ROOT/build/MacMonitorPanel.app/Contents/MacOS/MacMonitorPanel"
DOM=com.felixfu.MacMonitorPanel
had=0; defaults export "$DOM" "$OUT/defaults-backup.plist" 2>/dev/null && had=1
APID=""; TPID=""
cleanup() { [ -n "$APID" ] && kill "$APID" 2>/dev/null; [ -n "$TPID" ] && wait "$TPID" 2>/dev/null
  defaults delete "$DOM" 2>/dev/null; [ "$had" = 1 ] && defaults import "$DOM" "$OUT/defaults-backup.plist"; true; }
trap cleanup EXIT
defaults delete "$DOM" 2>/dev/null; defaults write "$DOM" panelVisible -bool true
defaults write "$DOM" size large; defaults write "$DOM" glass clear; defaults write "$DOM" language en
/usr/bin/time -p -o "$OUT/time.txt" "$APP" 2> "$OUT/app.log" & TPID=$!
sleep 3; APID="$(pgrep -P "$TPID" -x MacMonitorPanel | head -1)"
[ -n "$APID" ] || { echo "FAIL app did not start"; exit 1; }
echo "soak ${SECS}s app pid $APID start $(date)" | tee "$OUT/rss.txt"
for ((t = 0; t <= SECS; t += 60)); do
  W="$("$BIN/winq" window "$APID" | grep 'layer=-1' | head -1)"
  echo "t=$t rss_kb=$(ps -o rss= -p "$APID" | tr -d ' ') cputime=$(ps -o time= -p "$APID" | tr -d ' ') panel=[$W]" >> "$OUT/rss.txt"
  [ "$t" -lt "$SECS" ] && sleep $(( SECS - t < 60 ? SECS - t : 60 ))
done
leaks "$APID" > "$OUT/leaks.txt" 2>&1; echo "leaks exit $?" >> "$OUT/leaks.txt"
kill -0 "$APID" || { echo "FAIL app died"; exit 1; }
kill -TERM "$APID"; wait "$TPID" 2>/dev/null; APID=""; TPID=""
cat "$OUT/rss.txt" | tail -3
python3 - "$OUT/time.txt" <<'PY' | tee -a "$OUT/rss.txt"
import sys
v = dict(l.split() for l in open(sys.argv[1]) if len(l.split()) == 2)
cpu = float(v["user"]) + float(v["sys"]); wall = float(v["real"])
print(f"real {wall} user {v['user']} sys {v['sys']} -> {cpu / wall * 100:.3f}% of one core")
PY
grep -E "Process [0-9]+: [0-9]+ leaks|leaks for|total leaked|Physical footprint" "$OUT/leaks.txt"
