#!/bin/bash
# WP-G verification: window level/bounds, size switch, origin persistence, wake path, hidden launch,
# CPU with PreviewEngine, own-window captures. Run OUTSIDE any sandbox, under the hardware lock:
#   Scripts/with-lock.sh app Scripts/verify_app.sh
# Exits non-zero on any failed assertion. Touches only the app's own defaults domain (backed up and
# restored), $TMPDIR-style scratch and docs/wave2/app/. Never captures anything but our own window.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/MacMonitorPanel.app"
BIN="$APP/Contents/MacOS/MacMonitorPanel"
DOM="com.felixfu.MacMonitorPanel.wpq-verify-$$"
export MAC_MONITOR_SETTINGS_DOMAIN="$DOM"
OUT="${VERIFY_OUTPUT:-$ROOT/docs/wave2/app}"
SCRATCH="$(mktemp -d)"
FAILS=0
PID=""
CHILD_DOMAINS=("com.felixfu.MacMonitorPanel.wpz-child-$$-q" "com.felixfu.MacMonitorPanel.wpz-child-$$-w")

clean_child() {
  local domain="$1"
  defaults delete "$domain" 2>/dev/null || true
  rm -f "$HOME/Library/Preferences/$domain.plist"
}
check_child_cleanup() {
  local domain="$1"
  # Child has exited and synchronized; allow the CFPreferences daemon's queued writes.
  sleep 3
  clean_child "$domain"
  sleep 3
  check "child preferences absent after asynchronous write window ($domain)" test ! -e "$HOME/Library/Preferences/$domain.plist"
}

pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; FAILS=$((FAILS+1)); }
check() { # check <description> <command...>
  local d="$1"; shift
  if "$@"; then pass "$d"; else fail "$d"; fi
}

stop_app() {
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    kill "$PID" 2>/dev/null
    for _ in $(seq 1 20); do kill -0 "$PID" 2>/dev/null || break; sleep 0.25; done
    kill -9 "$PID" 2>/dev/null
    wait "$PID" 2>/dev/null
  fi
  PID=""
}

BACKUP="$SCRATCH/defaults-backup.plist"
HAD_DEFAULTS=0
if defaults export "$DOM" "$BACKUP" 2>/dev/null; then HAD_DEFAULTS=1; fi
cleanup() {
  stop_app
  for child in "${CHILD_DOMAINS[@]}"; do clean_child "$child"; done
  defaults delete "$DOM" 2>/dev/null
  # Only our exact isolated-domain family may remove a preference file.
  case "$DOM" in
    com.felixfu.MacMonitorPanel.wpq-verify-*) rm -f "$HOME/Library/Preferences/$DOM.plist" ;;
  esac
  if [ "$HAD_DEFAULTS" = 1 ]; then defaults import "$DOM" "$BACKUP" 2>/dev/null; fi
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

# --- window checker (CoreGraphics + AppKit), compiled once ---------------------------------------
cat > "$SCRATCH/cgcheck.swift" <<'SWIFT'
import AppKit
import CoreGraphics
if CommandLine.arguments.contains("locked") {
    let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    print(locked ? "true" : "false"); exit(0)
}

func displays() -> [CGRect] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var n: UInt32 = 0
    CGGetActiveDisplayList(16, &ids, &n)
    return ids.prefix(Int(n)).map { CGDisplayBounds($0) }
}

let args = CommandLine.arguments
if args.count >= 2, args[1] == "info" {
    let v = NSScreen.screens[0].visibleFrame
    print("visible=\(Int(v.minX)),\(Int(v.minY)),\(Int(v.width)),\(Int(v.height)) primaryHeight=\(Int(NSScreen.screens[0].frame.height))")
    exit(0)
}
guard args.count >= 3, args[1] == "window", let pid = Int32(args[2]) else { exit(2) }
let list = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
var best: (area: Double, line: String)?
for w in list {
    guard (w[kCGWindowOwnerPID as String] as? Int32) == pid,
          (w[kCGWindowLayer as String] as? Int) == -1,
          let b = w[kCGWindowBounds as String] as? [String: Double],
          let id = w[kCGWindowNumber as String] as? Int else { continue }
    let rect = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
    if rect.width < 100 { continue }
    let onscreen = (w[kCGWindowIsOnscreen as String] as? Bool) ?? false
    let inside = displays().contains { $0.contains(rect) }
    let line = "id=\(id) layer=-1 onscreen=\(onscreen) x=\(Int(rect.minX)) y=\(Int(rect.minY)) w=\(Int(rect.width)) h=\(Int(rect.height)) inside=\(inside)"
    let area = Double(rect.width * rect.height)
    if best == nil || area > best!.area { best = (area, line) }
}
if let best { print(best.line); exit(0) }
print("none")
exit(1)
SWIFT
swiftc -O -o "$SCRATCH/cgcheck" "$SCRATCH/cgcheck.swift" 2>&1 | grep -v "^$" || true
[ -x "$SCRATCH/cgcheck" ] || { echo "FAIL  could not compile window checker"; exit 1; }
CG="$SCRATCH/cgcheck"
LOCKED="$("$CG" locked)"
echo "session locked=$LOCKED"

field() { # field <key> <line>
  echo "$2" | tr ' ' '\n' | sed -n "s/^$1=//p"
}

# capture <windowID> <file>: our own window only (privacy rule); never full-screen or region
capture() {
  if [ "${MAC_MONITOR_NO_CAPTURE:-0}" = 1 ]; then echo "UNVERIFIED capture disabled by runner"; return; fi
  if [ "${LOCKED:-false}" = true ]; then echo "SKIP own-window capture: session locked; use RenderCards"; return; fi
  rm -f "$2"
  screencapture -x -o -l "$1" "$2" 2>/dev/null
  check "capture $(basename "$2") (own window $1 only)" [ -s "$2" ]
}

# launch <logfile> [args...]: starts the binary directly (open may be blocked), sets PID
launch() {
  local log="$1"; shift
  "$BIN" "$@" 2> "$log" &
  PID=$!
}

# wait_window: polls until a layer -1 window of $PID appears and its geometry is stable across two
# queries 0.7 s apart (the order-front animation briefly reports a smaller window). Sets WIN.
wait_window() {
  WIN=""
  local prev="" cur
  for _ in $(seq 1 40); do
    if cur="$("$CG" window "$PID" 2>/dev/null)"; then
      if [ "$cur" = "$prev" ]; then WIN="$cur"; return 0; fi
      prev="$cur"
    fi
    sleep 0.7
  done
  WIN="$prev"
  [ -n "$prev" ]
}

echo "== build =="
"$ROOT/Scripts/build.sh" 2>&1 | tail -3
[ -x "$BIN" ] || { echo "FAIL  build produced no binary"; exit 1; }
mkdir -p "$OUT"

INFO="$("$CG" info)"
echo "screen: $INFO"
VIS="$(echo "$INFO" | sed -n 's/^visible=\([^ ]*\).*/\1/p')"
PRIMARY_H="$(echo "$INFO" | sed -n 's/.*primaryHeight=//p')"
VX="${VIS%%,*}"; rest="${VIS#*,}"; VY="${rest%%,*}"
OX=$((VX + 120)); OY=$((VY + 120))   # AppKit bottom-left origin, well inside the primary screen

reset_defaults() { defaults delete "$DOM" 2>/dev/null; defaults write "$DOM" displayMode desktop; }

# --- Run 1: large + clear, saved origin ----------------------------------------------------------
echo; echo "== run 1: size=large glass=clear, saved origin ($OX,$OY) =="
reset_defaults
defaults write "$DOM" size large; defaults write "$DOM" glass clear; defaults write "$DOM" language en
defaults write "$DOM" panelOriginX -float "$OX"; defaults write "$DOM" panelOriginY -float "$OY"
launch "$SCRATCH/run1.log" --display-mode both
if wait_window; then
  echo "$WIN"
  L_H="$(field h "$WIN")"; L_W="$(field w "$WIN")"
  check "window layer is -1" [ "$(field layer "$WIN")" = "-1" ]
  check "window is on screen" [ "$(field onscreen "$WIN")" = "true" ]
  check "bounds inside a visible screen" [ "$(field inside "$WIN")" = "true" ]
  EXP_Y=$((PRIMARY_H - (OY + L_H)))
  check "persisted origin restored (x=$OX, cgY=$EXP_Y)" [ "$(field x "$WIN")" = "$OX" -a "$(field y "$WIN")" = "$EXP_Y" ]
  sleep 2
  capture "$(field id "$WIN")" "$OUT/large-clear.png"
else
  fail "no layer -1 window appeared (large/clear)"; L_H=0
fi
stop_app
if [ "$("$CG" locked)" = true ]; then
  echo 'UNVERIFIED startup STATUS transitions: session locked'
else
  check "startup STATUS transitions publish after fast metrics and never reset to firstSample" python3 - "$SCRATCH/run1.log" <<'PYSTARTUP'
import sys
previous = {}
measured = set()
initial = {}
for line in open(sys.argv[1]):
    if not line.startswith('STATUS '): continue
    _, metric, quality, fault = line.split()
    status = (quality, fault)
    assert previous.get(metric) != status, ('duplicate transition', metric, status)
    assert not (metric in measured and fault == 'firstSample'), ('startup reset', metric)
    if quality in ('live', 'estimated'): measured.add(metric)
    initial.setdefault(metric, status)
    previous[metric] = status
assert len(initial) == 9, initial
for metric in ('cpuTemp', 'gpuTemp', 'memory'):
    assert initial[metric][1] != 'firstSample', ('published before first fast tick', metric)
PYSTARTUP
fi

# --- Run 2: medium + tinted ----------------------------------------------------------------------
echo; echo "== run 2: size=medium glass=tinted =="
reset_defaults
defaults write "$DOM" size medium; defaults write "$DOM" glass tinted; defaults write "$DOM" language en
launch "$SCRATCH/run2.log"
if wait_window; then
  echo "$WIN"
  M_H="$(field h "$WIN")"
  check "medium height ($M_H) differs from large ($L_H)" [ "$M_H" != "$L_H" -a "$M_H" -gt 0 ]
  check "medium window layer -1, on screen, inside screen" \
    [ "$(field layer "$WIN")" = "-1" -a "$(field onscreen "$WIN")" = "true" -a "$(field inside "$WIN")" = "true" ]
  sleep 2
  capture "$(field id "$WIN")" "$OUT/medium-tinted.png"
else
  fail "no layer -1 window appeared (medium/tinted)"
fi
stop_app

# --- Run 3: large + tinted capture (clear vs tinted on the same size) ----------------------------
echo; echo "== run 3: size=large glass=tinted capture =="
reset_defaults
defaults write "$DOM" size large; defaults write "$DOM" glass tinted
launch "$SCRATCH/run3.log"
if wait_window; then
  sleep 2
  capture "$(field id "$WIN")" "$OUT/large-tinted.png"
else
  fail "no layer -1 window appeared (large/tinted)"
fi
stop_app

# --- Run 4: drag persistence + simulated wake ----------------------------------------------------
echo; echo "== run 4: --simulate-move-after 2, --simulate-wake-after 3, then relaunch =="
reset_defaults
defaults write "$DOM" size large
defaults write "$DOM" panelOriginX -float "$OX"; defaults write "$DOM" panelOriginY -float "$OY"
launch "$SCRATCH/run4.log" --simulate-move-after 2 --simulate-wake-after 3
sleep 6
cat "$SCRATCH/run4.log"
check "simulated wake logs the wake path" grep -q "wake handled via simulated path: engine.systemDidWake()" "$SCRATCH/run4.log"
NX="$(defaults read "$DOM" panelOriginX 2>/dev/null)"; NY="$(defaults read "$DOM" panelOriginY 2>/dev/null)"
echo "defaults after move: x=$NX y=$NY (expected x=$((OX+50)) y=$((OY-50)))"
check "windowDidMove persisted the new origin" [ "${NX%.*}" = "$((OX+50))" -a "${NY%.*}" = "$((OY-50))" ]
stop_app
launch "$SCRATCH/run4b.log"
if wait_window; then
  echo "$WIN"
  EXP_Y=$((PRIMARY_H - ((OY-50) + $(field h "$WIN"))))
  check "relaunch restores the dragged origin" [ "$(field x "$WIN")" = "$((OX+50))" -a "$(field y "$WIN")" = "$EXP_Y" ]
else
  fail "no window after relaunch"
fi
stop_app

# --- Run 5: launch hidden ------------------------------------------------------------------------
echo; echo "== run 5: panelVisible=false =="
reset_defaults
defaults write "$DOM" panelVisible -bool false
launch "$SCRATCH/run5.log"
sleep 4
HID="$("$CG" window "$PID" 2>/dev/null)"; echo "window query: $HID"
check "hidden launch shows no on-screen panel" [ "$HID" = "none" -o "$(field onscreen "$HID")" = "false" ]
check "hidden launch pauses the engine" grep -q "engine pause" "$SCRATCH/run5.log"
stop_app

# --- Run 6: CPU over 20 s with PreviewEngine -----------------------------------------------------
echo; echo "== run 6: CPU over 20 s (large, clear, PreviewEngine) =="
reset_defaults
defaults write "$DOM" size large
launch "$SCRATCH/run6.log" --preview-engine
wait_window >/dev/null
sleep 3
to_sec() { echo "$1" | awk -F'[:.]' '{ if (NF==3) print $1*60+$2+$3/100; else print $1*3600+$2*60+$3+$4/100 }'; }
T0="$(to_sec "$(ps -o time= -p "$PID" | tr -d ' ')")"
SAMPLES=""
for i in $(seq 1 10); do
  sleep 2
  S="$(ps -o %cpu= -p "$PID" | tr -d ' ')"; SAMPLES="$SAMPLES $S"
done
T1="$(to_sec "$(ps -o time= -p "$PID" | tr -d ' ')")"
echo "ps %cpu samples (every 2 s):$SAMPLES"
CPU="$(awk -v a="$T0" -v b="$T1" 'BEGIN { printf "%.3f", (b-a)/20*100 }')"
echo "cputime delta over 20 s: ${T0}s -> ${T1}s = ${CPU}% of one core"
check "UI-only self CPU over 20 s < 1.0% of one core (measured ${CPU}%)" awk -v c="$CPU" 'BEGIN { exit !(c < 1.0) }'
stop_app

# --- Run 7: live option change (size large -> medium) re-fits the panel, keeps the top edge -------
echo; echo "== run 7: --simulate-options-after 3 (large/clear/en -> medium/tinted/zh-Hant) =="
reset_defaults
defaults write "$DOM" size large; defaults write "$DOM" glass clear
defaults write "$DOM" panelOriginX -float "$OX"; defaults write "$DOM" panelOriginY -float "$OY"
launch "$SCRATCH/run7.log" --simulate-options-after 3
wait_window >/dev/null; BEFORE="$WIN"; echo "before: $BEFORE"
sleep 5
wait_window >/dev/null; AFTER="$WIN"; echo "after:  $AFTER"
cat "$SCRATCH/run7.log"
check "live switch re-fits height ($(field h "$BEFORE") -> $(field h "$AFTER"))" \
  [ "$(field h "$BEFORE")" = "$L_H" -a "$(field h "$AFTER")" = "$M_H" ]
check "top edge stays fixed after re-fit (cgY $(field y "$BEFORE") -> $(field y "$AFTER"))" \
  [ "$(field y "$BEFORE")" = "$(field y "$AFTER")" -a "$(field x "$BEFORE")" = "$(field x "$AFTER")" ]
SAVED_Y="$(defaults read "$DOM" panelOriginY)"; EXP_SAVED_Y=$((OY + L_H - M_H))
check "re-fit persists the moved origin (panelOriginY=$SAVED_Y, expected $EXP_SAVED_Y)" [ "${SAVED_Y%.*}" = "$EXP_SAVED_Y" ]
check "switch persisted (size=medium glass=tinted language=zh-Hant)" \
  [ "$(defaults read "$DOM" size)" = medium -a "$(defaults read "$DOM" glass)" = tinted -a "$(defaults read "$DOM" language)" = zh-Hant ]
stop_app

# --- Run 8: direct executable launch also obeys the single-instance guard ------------------------
echo; echo "== run 8: duplicate direct executable launch =="
reset_defaults
launch "$SCRATCH/run8.log"
wait_window >/dev/null
FIRST="$PID"
"$BIN" 2> "$SCRATCH/run8-duplicate.log" &
SECOND=$!
for _ in $(seq 1 30); do kill -0 "$SECOND" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$SECOND" 2>/dev/null; then
  fail "duplicate exits within 3 seconds"
  kill -TERM "$SECOND" 2>/dev/null
  wait "$SECOND" 2>/dev/null
else
  wait "$SECOND"; DUP_STATUS=$?
  check "duplicate exits quietly with status 0" [ "$DUP_STATUS" -eq 0 ]
fi
check "original process survives duplicate launch" kill -0 "$FIRST"
check "original panel survives duplicate launch" "$CG" window "$FIRST"
check "duplicate owns no panel" [ "$("$CG" window "$SECOND" 2>/dev/null)" = none ]
stop_app

# --- WP-Q: native item, fixed width, three modes, popover and hidden fallback -------------------
echo "== WP-Q menu-bar acceptance =="
reset_defaults
launch "$SCRATCH/menubar.log" --preview-engine --menubar-check
for _ in $(seq 1 60); do kill -0 "$PID" 2>/dev/null || break; sleep 0.2; done
cat "$SCRATCH/menubar.log"
check "hiding desktop preserves frame/origin" grep -q 'TEST menubar geometryPreserved=true' "$SCRATCH/menubar.log"
check "status item present" grep -q 'status present=true' "$SCRATCH/menubar.log"
check "menu-bar mode hides panel with fixed item width" grep -q 'TEST menubar mode panelHidden=true widthFixed=true' "$SCRATCH/menubar.log"
check "debug action opens native popover" grep -q 'TEST menubar popover=true' "$SCRATCH/menubar.log"
check "Escape cancel action closes native popover" grep -q 'TEST menubar escapeCloses=true' "$SCRATCH/menubar.log"
check "desktop right/Control menus share settings, Quit and hidden note in every mode" grep -q 'TEST menubar panelContextMenus=true' "$SCRATCH/menubar.log"
check "hidden status item restores desktop" grep -q 'TEST menubar fallback=true' "$SCRATCH/menubar.log"
check "Both mode shows panel with fixed item width" grep -q 'TEST menubar both=true widthFixed=true' "$SCRATCH/menubar.log"
check "all checkbox subsets persist with fixed width" grep -q 'TEST menubar allSubsets=true' "$SCRATCH/menubar.log"
check "Desktop mode retains minimal status item" grep -q 'TEST menubar desktop=true minimal=true' "$SCRATCH/menubar.log"
stop_app

swiftc -parse-as-library -I "$ROOT/.build/release" "$ROOT/.build/release/MonitorCore.o" \
  "$ROOT/Sources/MonitorApp/Settings.swift" "$ROOT/Tests/Acceptance/wpq_settings.swift" -o "$SCRATCH/settings-check"
check "settings migration and persistence" env MAC_MONITOR_SETTINGS_DOMAIN="${CHILD_DOMAINS[0]}" "$SCRATCH/settings-check"
check_child_cleanup "${CHILD_DOMAINS[0]}"

swiftc -parse-as-library -I "$ROOT/.build/release" "$ROOT/.build/release/MonitorCore.o" "$ROOT/.build/release/MonitorUI.o" \
  "$ROOT/Sources/MonitorApp/PanelController.swift" "$ROOT/Sources/MonitorApp/MoonStatusController.swift" \
  "$ROOT/Tests/Acceptance/wps_controller.swift" -o "$SCRATCH/controller-check"
check "controller accessibility changes language with constant and missing readings" "$SCRATCH/controller-check"


# --- WP-V begin
echo "== WP-V status and recovery acceptance =="
swift build --package-path "$ROOT" -c release --product EngineDump > "$SCRATCH/wpv-build.log" 2>&1
DUMP="$ROOT/.build/release/EngineDump"
if [ -x "$DUMP" ]; then
  # Headless real engine remains active in a locked session. Never credit a paused app as evidence.
  for spec in cpuTemp:unavailable gpuTemp:generic procs:slow cpuTemp:stuck; do
    name="${spec%:*}"
    mode="${spec#*:}"
    seconds=8
    if [ "$mode" = stuck ]; then seconds=60; fi
    log="$SCRATCH/wpv-$name-$mode.log"
    MAC_MONITOR_PROFILE=1 MAC_MONITOR_STUCK_TICKS=5 MAC_MONITOR_PS_EXECUTABLE="$ROOT/Tests/Scripts/slow_ps.sh" \
      "$DUMP" --seconds "$seconds" --fault "$spec" > "$SCRATCH/wpv-$name-$mode.json" 2> "$log"
    case "$spec" in
      cpuTemp:unavailable) check "WP-V unavailable CPU temperature" grep -q 'STATUS cpuTemp unavailable apiError' "$log" ;;
      gpuTemp:generic) check "WP-V generic GPU temperature" grep -q 'STATUS gpuTemp estimated unknownChip' "$log" ;;
      procs:slow) check "WP-V timed-out ps falls back to libproc" grep -q 'STATUS processes estimated timeout' "$log" ;;
      cpuTemp:stuck)
        check "WP-V stuck temperature detected" grep -q 'STATUS cpuTemp unavailable stuck' "$log"
        reopens="$(grep -c '^smc.reopen$' "$log" || true)"
        check "WP-V no SMC reopen storm ($reopens in 60 s)" [ "$reopens" -le 4 ] ;;
    esac
  done
  if [ "$("$CG" locked)" = true ]; then
    echo 'UNVERIFIED WP-V app fault transitions: locked session pauses app; real headless engine checked above'
  else
    reset_defaults
    launch "$SCRATCH/wpv-app.log" --fault cpuTemp:unavailable --display-mode both
    sleep 8
    check "WP-V app fault argument reaches sampling" grep -q 'STATUS cpuTemp unavailable apiError' "$SCRATCH/wpv-app.log"
    stop_app
  fi
else
  fail "WP-V EngineDump build"
  cat "$SCRATCH/wpv-build.log"
fi
# --- WP-V end

# --- WP-W begin
# Real coach windows, persistence, keyboard and harness suppression.
echo "== WP-W onboarding acceptance =="
if [ "$("$CG" locked)" = true ]; then
  echo "UNVERIFIED WP-W coach windows/navigation: session locked"
else
for TOUR_MODE in both menuBar desktop hidden; do
  reset_defaults
  TOUR_LOG="$SCRATCH/tour-$TOUR_MODE.log"
  TOUR_HARNESS_HIDDEN=false
  if [ "$TOUR_MODE" = hidden ]; then
    TOUR_HARNESS_HIDDEN=true
    launch "$TOUR_LOG" --tour --tour-check --tour-mode menuBar --tour-hidden
  else
    launch "$TOUR_LOG" --tour --tour-check --tour-mode "$TOUR_MODE"
  fi
  TOUR_LOCKED=0
  for _ in $(seq 1 100); do
    if [ "$("$CG" locked)" = true ]; then TOUR_LOCKED=1; break; fi
    kill -0 "$PID" 2>/dev/null || break
    sleep 0.2
  done
  cat "$TOUR_LOG"
  if [ "$TOUR_LOCKED" = 1 ] || [ "$("$CG" locked)" = true ]; then
    echo "UNVERIFIED WP-W $TOUR_MODE: session locked during tour"
    stop_app
    break
  fi
  check "tour $TOUR_MODE completes" grep -q 'TEST tour outcome=completed version=1' "$TOUR_LOG"
  check "tour $TOUR_MODE tears down its resources and restores panel level" grep -q 'TEST tour teardown=true panelLevel=-1' "$TOUR_LOG"
  check "tour $TOUR_MODE mode picker persists without replanning" grep -q 'TEST tour modePicker=true planFixed=true' "$TOUR_LOG"
  check "tour $TOUR_MODE refreshes settings card in both languages with accessibility" grep -q 'TEST tour languageRefresh=true step=settings' "$TOUR_LOG"
  check "tour $TOUR_MODE refreshes mode card in both languages with accessibility" grep -q 'TEST tour languageRefresh=true step=mode' "$TOUR_LOG"
  check "tour $TOUR_MODE Escape skips and persists" grep -q 'TEST tour escapeSkipped=true persisted=true' "$TOUR_LOG"
  python3 - "$TOUR_LOG" "$TOUR_MODE" "$TOUR_HARNESS_HIDDEN" <<'PYTOUR'
import re, sys
text = open(sys.argv[1]).read()
steps = [line for line in text.splitlines() if 'TEST tour step=' in line]
assert steps, 'no presented coach windows'
assert all('onScreen=true' in line and 'key=true' in line for line in steps), 'coach offscreen or not key'
for line in steps:
    if 'anchor=panel ' in line:
        assert int(re.search(r' panelLevel=(\d+)', line)[1]) == 3
    if 'step=popover ' in line:
        assert int(re.search(r' level=(\d+)', line)[1]) >= int(re.search(r' moonLevel=(\d+)', line)[1])
seen = {re.search(r'step=(\w+)', line)[1] for line in steps}
expected = {'moons', 'popover', 'settings', 'mode'}
if sys.argv[2] in ('both', 'desktop'): expected.add('panel')
# Only independent harness control or initial visibility evidence authorizes
# a shortened plan. A self-reported count cannot establish hidden state.
harness_hidden = len(sys.argv) > 3 and sys.argv[3] == 'true'
prelude = text.split(steps[0], 1)[0]
visibility = re.findall(r'status hidden=(true|false)\b', prelude)
initial_hidden = bool(visibility) and visibility[-1] == 'true'
if harness_hidden or initial_hidden:
    expected.remove('popover')
elif 'anchor=panel ' in steps[0]:
    print('UNVERIFIED unexpected initial hidden/parked item; full visible plan not established')
    sys.exit(3)
if sys.argv[2] == 'hidden':
    assert harness_hidden, 'hidden fixture requires harness control'
    assert all('anchor=panel ' in line for line in steps)
assert seen == expected, (seen, expected)
assert all(re.search(r'index=\d+/(\d+)', line)[1] == str(len(expected)) for line in steps)
PYTOUR
  TOUR_PLAN_RC=$?
  case "$TOUR_PLAN_RC" in
    0) pass "tour $TOUR_MODE window geometry, level and expected plan" ;;
    3) echo "UNVERIFIED tour $TOUR_MODE window geometry and full visible plan: unexpected hidden item" ;;
    *) fail "tour $TOUR_MODE window geometry, level and expected plan" ;;
  esac
  stop_app
done
if [ "$("$CG" locked)" = true ]; then
  echo "UNVERIFIED WP-W automatic-tour UI: session locked"
else
reset_defaults
launch "$SCRATCH/tour-suppressed.log"
sleep 4
check "fresh harness domain suppresses the automatic tour" grep -q 'TEST tour autoRun=false reason=harness-domain' "$SCRATCH/tour-suppressed.log"
check "harness did not show a coach window" test "$(grep -c 'TEST tour step=' "$SCRATCH/tour-suppressed.log")" = 0
stop_app
fi
fi
swiftc -parse-as-library -I "$ROOT/.build/release" "$ROOT/.build/release/MonitorCore.o" \
  "$ROOT/Sources/MonitorApp/Settings.swift" "$ROOT/Tests/Acceptance/wpw_settings.swift" -o "$SCRATCH/tour-settings-check"
check "tour persistence, interrupted launch, reset and existing-install keys" env MAC_MONITOR_SETTINGS_DOMAIN="${CHILD_DOMAINS[1]}" "$SCRATCH/tour-settings-check"
check_child_cleanup "${CHILD_DOMAINS[1]}"
# --- WP-W end

echo
if [ "$FAILS" -eq 0 ]; then echo "ALL CHECKS PASSED"; else echo "$FAILS CHECK(S) FAILED"; fi
exit $((FAILS > 0))
