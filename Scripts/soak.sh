#!/bin/bash
# Whole-app CPU includes waited-for ps children. Run outside the sandbox under with-lock.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SECS="${1:-600}"
[[ "$SECS" =~ ^[1-9][0-9]*$ ]] || { echo 'duration must be positive integer seconds'; exit 2; }
MODE="${2:-both}"
case "$MODE" in both|desktop|menuBar|popover) ;; *) echo 'mode must be both, desktop, menuBar or popover'; exit 2;; esac
OUT="${SOAK_OUTPUT:-$ROOT/docs/wave4/menubar}"; mkdir -p "$OUT"
LOG="$OUT/soak-${MODE}-$(date +%Y%m%d-%H%M%S).txt"
BIN="$ROOT/build/MacMonitorPanel.app/Contents/MacOS/MacMonitorPanel"
DOM="com.felixfu.MacMonitorPanel.wpq-soak-$$"
export MAC_MONITOR_SETTINGS_DOMAIN="$DOM"
SCRATCH="$(mktemp -d)"
APID=""; TPID=""; HAD_DEFAULTS=0
if defaults export "$DOM" "$SCRATCH/defaults.plist" 2>/dev/null; then HAD_DEFAULTS=1; fi
cleanup() {
  # The launch has its own process group (time + app + ps children). It is
  # owned from launch, even before APID discovery, and cannot include a tester.
  if [ -n "$TPID" ]; then
    kill -TERM -- "-$TPID" 2>/dev/null || true
    for _ in $(seq 1 30); do
      kill -0 -- "-$TPID" 2>/dev/null || break
      sleep 0.1
    done
    kill -KILL -- "-$TPID" 2>/dev/null || true
    # Never let an unreaped wrapper delay defaults restoration indefinitely.
    if ! kill -0 "$TPID" 2>/dev/null; then wait "$TPID" 2>/dev/null || true; fi
  fi
  defaults delete "$DOM" 2>/dev/null || true
  # Only our exact isolated-domain family may remove a preference file.
  case "$DOM" in
    com.felixfu.MacMonitorPanel.wpq-soak-*) rm -f "$HOME/Library/Preferences/$DOM.plist" ;;
  esac
  if [ "$HAD_DEFAULTS" = 1 ]; then defaults import "$DOM" "$SCRATCH/defaults.plist" 2>/dev/null || true; fi
  rm -rf "$SCRATCH"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
"$ROOT/Scripts/build.sh" release > /dev/null
# A locked/paused session cannot provide valid active-mode budget evidence.
cat > "$SCRATCH/locked.swift" <<'SWIFT'
import CoreGraphics
import Foundation
let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
exit(locked ? 3 : 0)
SWIFT
swiftc "$SCRATCH/locked.swift" -o "$SCRATCH/locked"
if ! "$SCRATCH/locked"; then echo 'UNVERIFIED session locked; no paused interval credited as budget evidence'; exit 3; fi
# Only inspects metadata for this PID; never captures any screen content.
cat > "$SCRATCH/visible.swift" <<'SWIFT'
import CoreGraphics
import Foundation
let pid = Int32(CommandLine.arguments[1])!
let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
for w in windows {
    guard w[kCGWindowOwnerPID as String] as? Int32 == pid,
          w[kCGWindowLayer as String] as? Int == -1,
          w[kCGWindowIsOnscreen as String] as? Bool == true,
          let bounds = w[kCGWindowBounds as String] as? [String: Double],
          (bounds["Width"] ?? 0) > 100, (bounds["Height"] ?? 0) > 100 else { continue }
    print("panel pid=\(pid) layer=-1 onscreen=true bounds=\(bounds)")
    exit(0)
}
fputs("FAIL no on-screen layer -1 panel for pid \(pid)\n", stderr)
exit(1)
SWIFT
swiftc -O "$SCRATCH/visible.swift" -o "$SCRATCH/visible"
defaults write "$DOM" panelVisible -bool true
ARGS=(--display-mode "$MODE")
if [ "$MODE" = popover ]; then ARGS=(--display-mode menuBar --menubar-popover); fi
# Bash job control gives this job a dedicated process group led by TPID.
set -m
/usr/bin/time -p -o "$SCRATCH/time" "$BIN" "${ARGS[@]}" 2> "$OUT/soak-${MODE}-app-stderr.log" &
TPID=$!
set +m
if [ -n "${SOAK_TEST_INTERRUPT_AFTER:-}" ]; then
  echo "controlled startup interruption: owned process group $TPID"
  sleep "$SOAK_TEST_INTERRUPT_AFTER"
  kill -TERM "$$"
fi
sleep 3
APID="$(pgrep -P "$TPID" -x MacMonitorPanel | head -1)"
[ -n "$APID" ] || { echo 'FAIL app did not start'; exit 1; }
{
  echo "soak ${SECS}s mode=$MODE, app pid $APID, $(date)"
  if [ "$MODE" = both ] || [ "$MODE" = desktop ]; then "$SCRATCH/visible" "$APID"; fi
  echo "rss_kb at start: $(ps -o rss= -p "$APID")"
} > "$LOG"
sleep "$SECS"
kill -0 "$APID" || { echo 'FAIL app exited during soak'; exit 1; }
if [ "$MODE" = both ] || [ "$MODE" = desktop ]; then "$SCRATCH/visible" "$APID" >> "$LOG"; fi
if [ "$MODE" = popover ]; then grep -q "popover opened=true" "$OUT/soak-${MODE}-app-stderr.log" || { echo "FAIL popover never opened"; exit 1; }; fi
if grep -q "engine pause (visible=" "$OUT/soak-${MODE}-app-stderr.log"; then
  echo "FAIL paused interval during soak"; exit 1
fi
if grep -q "engine pause (hidden launch" "$OUT/soak-${MODE}-app-stderr.log"; then
  grep -q "engine resume" "$OUT/soak-${MODE}-app-stderr.log" || { echo "FAIL engine never resumed"; exit 1; }
fi
"$SCRATCH/locked" || { echo "UNVERIFIED session became locked"; exit 3; }
echo "rss_kb at end: $(ps -o rss= -p "$APID")" >> "$LOG"
kill -TERM "$APID"
# SIGTERM is intentional; timing output is still required and validated below.
wait "$TPID" 2>/dev/null || true
APID=""; TPID=""
cat "$SCRATCH/time" >> "$LOG"
STATUS=0
BRAND="$(/usr/sbin/sysctl -n machdep.cpu.brand_string)"
python3 - "$SCRATCH/time" "$SECS" "$MODE" "$OUT/soak-${MODE}-app-stderr.log" "$BRAND" >> "$LOG" <<'PY' || STATUS=$?
import math, sys
try:
    vals = dict(l.split() for l in open(sys.argv[1]) if len(l.split()) == 2)
    cpu = float(vals['user']) + float(vals['sys']); wall = float(vals['real'])
    assert math.isfinite(cpu) and cpu >= 0 and math.isfinite(wall)
    assert float(sys.argv[2]) <= wall <= float(sys.argv[2]) + 30
except (KeyError, ValueError, AssertionError):
    print('FAIL malformed timing or elapsed duration'); sys.exit(1)
print(f'cpu (self+children) {cpu:.3f} s over {wall:.1f} s = {cpu / wall * 100:.3f}% of one core')
app = open(sys.argv[4]).read()
if sys.argv[3] in ('menuBar', 'popover'):
    hidden = [line for line in app.splitlines() if 'status hidden=' in line]
    if hidden and 'status hidden=true' in hidden[-1]:
        print(f'UNVERIFIED {sys.argv[3]} target: macOS hid item; measured mandatory desktop fallback above')
        sys.exit(3)
if sys.argv[3] == 'popover':
    opened = [line for line in app.splitlines() if 'popover opened=' in line]
    if not opened or 'popover opened=true' not in opened[-1]:
        print('UNVERIFIED popover closed during measurement'); sys.exit(3)
limit = 0.005 if sys.argv[3] == 'menuBar' else (0.015 if sys.argv[3] == 'popover' and sys.argv[5] == 'Apple M3' else (0.009 if sys.argv[3] == 'both' and sys.argv[5] == 'Apple M3' else 0.01))
passed = cpu / wall <= limit if sys.argv[3] in ('menuBar', 'popover', 'both') else cpu / wall < limit
print(f"{'PASS' if passed else 'FAIL'} whole app mode={sys.argv[3]} budget {limit*100:g}% of one core")
sys.exit(0 if passed else 1)
PY
cat "$LOG"
exit "$STATUS"
