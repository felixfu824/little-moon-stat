#!/bin/bash
# WP-U live-app cases (window/status-item METADATA only, never pixels). Isolated defaults domain and
# instance lock (MAC_MONITOR_SETTINGS_DOMAIN); every app launched here is killed by PID.
# Usage: live.sh <bin dir> <repo root> <out dir> <case...>
set -uo pipefail
BIN="$1"; ROOT="$2"; OUT="$3"; shift 3; mkdir -p "$OUT"
APP="$ROOT/build/MacMonitorPanel.app/Contents/MacOS/MacMonitorPanel"
export MAC_MONITOR_SETTINGS_DOMAIN="com.felixfu.MacMonitorPanel.wpu-live"; DOM="$MAC_MONITOR_SETTINGS_DOMAIN"
PID=""; PID2=""
stop() { for p in $PID $PID2; do kill "$p" 2>/dev/null; for _ in $(seq 1 20); do kill -0 "$p" 2>/dev/null || break; sleep 0.25; done; kill -9 "$p" 2>/dev/null; done; PID=""; PID2=""; }
trap 'stop; defaults delete "$DOM" 2>/dev/null' EXIT
reset() { defaults delete "$DOM" 2>/dev/null; true; }
launch() { local log="$1"; shift; "$APP" "$@" 2> "$OUT/$log" & PID=$!; }
res() { echo "RESULT $1 $2 :: $3"; }
panel() { "$BIN/statusq" "$1" | grep 'layer=-1' | grep 'onscreen=true' | head -1; }
# macOS 26 does not list status-item windows under our pid; item geometry comes from the app's own log.
item() { grep -o 'frame=([^)]*)' "$OUT/$1" | tail -1; }
f() { echo "$2" | tr ' ' '\n' | sed -n "s/^$1=//p"; }
cpu() { ps -o time= -p "$1" | awk -F'[:.]' '{print $1*60+$2+$3/100}'; }
echo "env: $("$BIN/statusq" env | tr '\n' ' ')"
for C in "$@"; do case "$C" in
mode-menubar)  # D1 menu bar + H1/H2 (organiser state decides parked vs on-screen)
  reset; defaults write "$DOM" displayMode menuBar
  launch mb.log; sleep 42; P="$(panel $PID)"; I="$(item mb.log)"; echo "item: $I"; echo "panel: ${P:-none}"; grep -v '^COST' "$OUT/mb.log"
  if grep -q 'parked=true' "$OUT/mb.log"; then
    [ -z "$P" ] && ! grep -q 'status hidden=true' "$OUT/mb.log" && res H1 PASS "parked by organiser, no fallback panel; item $I" || res H1 FAIL "panel=${P:-none}"
  else
    [ -z "$P" ] && ! grep -q 'status hidden=true' "$OUT/mb.log" \
      && res H2/D1-menuBar PASS "not hidden, not parked (no visibility transition logged); no panel" || res H2/D1-menuBar FAIL "item=$I panel=${P:-none}"
  fi; stop;;
mode-both)
  reset; defaults write "$DOM" displayMode both
  launch both.log; sleep 25; P="$(panel $PID)"; echo "panel: ${P:-none}"; grep -v '^COST' "$OUT/both.log"
  [ -n "$P" ] && ! grep -q 'status hidden=true' "$OUT/both.log" && res D1-both PASS "panel $P; item $(grep -o 'parked=[a-z]*' "$OUT/both.log" | tail -1)" || res D1-both FAIL "panel=${P:-none}"; stop;;
mode-desktop)
  reset; defaults write "$DOM" displayMode desktop
  launch desk.log; sleep 25; P="$(panel $PID)"; echo "panel: ${P:-none}"; grep -v '^COST' "$OUT/desk.log"
  [ -n "$P" ] && ! grep -q 'status hidden=' "$OUT/desk.log" && res D1-desktop PASS "panel $P; no visibility timer in Desktop mode" || res D1-desktop FAIL "panel=${P:-none}"; stop;;
migrate)  # D3 v1 install: only v1 keys present
  reset; defaults write "$DOM" size medium; defaults write "$DOM" glass tinted; defaults write "$DOM" language zh-Hant
  defaults write "$DOM" panelVisible -bool true; defaults write "$DOM" panelOriginX -float 300; defaults write "$DOM" panelOriginY -float 300
  launch mig.log; sleep 8; P="$(panel $PID)"; echo "panel: ${P:-none}"; grep -v '^COST' "$OUT/mig.log" | head -4
  echo "keys after launch: $(defaults read "$DOM" | tr -s ' \n' ' ')"
  [ -n "$P" ] && [ "$(f x "$P")" = 300 ] && grep -q 'size=medium glass=tinted lang=zh-Hant' "$OUT/mig.log" \
    && res D3 PASS "panel shown at saved x=300 ($P) with v1 size/glass/language (mode/moons resolved by Settings defaults)" || res D3 FAIL "panel=${P:-none}"; stop;;
invalid)  # D4
  reset; defaults write "$DOM" displayMode bogus; defaults write "$DOM" temperatureUnit bogus; defaults write "$DOM" menuBarMoons -string abc
  launch inv1.log; sleep 8; P="$(panel $PID)"; A1=$(kill -0 $PID 2>/dev/null && echo alive || echo dead); stop
  reset; defaults write "$DOM" menuBarMoons -int 99
  launch inv2.log; sleep 8; A2=$(kill -0 $PID 2>/dev/null && echo alive || echo dead); stop
  reset; defaults write "$DOM" menuBarMoons -int -1
  launch inv3.log; sleep 8; A3=$(kill -0 $PID 2>/dev/null && echo alive || echo dead); stop
  echo "bogus strings: $A1 panel=${P:-none}"; echo "menuBarMoons=99: $A2"; echo "menuBarMoons=-1: $A3"
  [ "$A1$A2$A3" = alivealivealive ] && [ -n "$P" ] && res D4 PASS "no crash; bogus mode -> panel shown (Both/Desktop)" || res D4 FAIL "see above";;
hidden-desktop)  # D5
  reset; defaults write "$DOM" displayMode desktop; defaults write "$DOM" panelVisible -bool false
  MAC_MONITOR_PROFILE=1 "$APP" 2> "$OUT/hid.log" & PID=$!; sleep 4; T0=$(cpu $PID); sleep 30; T1=$(cpu $PID); P="$(panel $PID)"
  C=$(awk -v a="$T0" -v b="$T1" 'BEGIN{printf "%.3f", (b-a)/30*100}'); grep -v '^COST' "$OUT/hid.log" | head -3
  [ -z "$P" ] && grep -q 'engine pause' "$OUT/hid.log" && ! grep -q '^COST' "$OUT/hid.log" && awk -v c="$C" 'BEGIN{exit !(c < 0.05)}' \
    && res D5 PASS "no panel, paused, 0 COST lines, cpu ${C}%" || res D5 FAIL "panel=${P:-none} cpu=${C}% COST=$(grep -c '^COST' "$OUT/hid.log")"; stop;;
gating)  # D6
  reset; defaults write "$DOM" displayMode menuBar
  MAC_MONITOR_PROFILE=1 "$APP" 2> "$OUT/gate-closed.log" & PID=$!; KIDS=0
  for _ in $(seq 1 30); do sleep 1; KIDS=$((KIDS + $(pgrep -P $PID | wc -l))); done; stop
  CL="$(grep '^COST' "$OUT/gate-closed.log" | cut -f2 | sort | uniq -c | tr -s ' \n' ' ')"
  MAC_MONITOR_PROFILE=1 "$APP" --menubar-popover 2> "$OUT/gate-open.log" & PID=$!; sleep 30; stop
  OL="$(grep '^COST' "$OUT/gate-open.log" | cut -f2 | sort | uniq -c | tr -s ' \n' ' ')"
  echo "closed COST labels: $CL (ps children seen in 30 1-s polls: $KIDS)"; echo "open COST labels: $OL"; grep 'popover' "$OUT/gate-open.log"
  [ -z "$(grep -E '^COST	(process|disk|cpu|gpu|thermal)	' "$OUT/gate-closed.log")" ] && [ "$KIDS" = 0 ] && grep -qE '^COST	process	' "$OUT/gate-open.log" \
    && res D6 PASS "closed: only $CL; open adds process/disk/cpu/gpu" || res D6 FAIL "closed=$CL kids=$KIDS";;
popover)  # P3/P4
  reset; defaults write "$DOM" displayMode menuBar
  launch pop.log --menubar-popover; sleep 6; echo "windows: $("$BIN/statusq" $PID | tr '\n' ';')"; grep -v '^COST' "$OUT/pop.log"
  W="$("$BIN/statusq" $PID | grep 'layer=25' | grep 'onscreen=true' | awk -F'w=' '{split($2,a," "); if (a[1] > 300) print}' | head -1)"
  grep -q 'popover opened=true' "$OUT/pop.log" && [ -n "$W" ] && res P3 PASS "popover window $W" || res P3 FAIL "window=${W:-none}"; stop;;
check)  # verify the debug acceptance flow, then D2 relaunch persistence
  reset; defaults write "$DOM" displayMode desktop
  launch chk.log --menubar-check; for _ in $(seq 1 30); do kill -0 $PID 2>/dev/null || break; sleep 1; done; grep 'TEST' "$OUT/chk.log"
  PERS="$(defaults read "$DOM" displayMode) $(defaults read "$DOM" menuBarMoons)"; PID=""
  N=$(grep -c '=true' <(grep 'TEST' "$OUT/chk.log")); F=$(grep 'TEST' "$OUT/chk.log" | grep -c '=false')
  [ "$F" = 0 ] && [ "$N" -ge 8 ] && res P4/H3/M7 PASS "$N TEST assertions true (escape, forced-hidden fallback, all 8 subsets)" || res P4/H3/M7 FAIL "$F false"
  launch rel.log; sleep 8; P="$(panel $PID)"; echo "persisted: $PERS; relaunch panel ${P:-none}"; grep -v '^COST' "$OUT/rel.log"
  [ "$PERS" = "menuBar 7" ] && [ -z "$P" ] && grep -q 'launched visible=false' "$OUT/rel.log" && res D2 PASS "persisted '$PERS'; relaunch in Menu bar mode: no panel" || res D2 FAIL "persisted '$PERS' panel=${P:-none}"; stop;;
single)  # R3
  reset; launch s1.log; sleep 4; A=$PID; "$APP" 2> "$OUT/s2.log" & PID2=$!; sleep 5
  kill -0 $PID2 2>/dev/null && res R3 FAIL "second instance alive" || res R3 PASS "second instance exited; first alive=$(kill -0 $A && echo yes)"; stop;;
wake)  # R4
  reset; MAC_MONITOR_PROFILE=1 "$APP" --simulate-wake-after 4 2> "$OUT/wake.log" & PID=$!; sleep 14
  WL="$(grep -n 'wake handled' "$OUT/wake.log" | cut -d: -f1)"; AFTER=$(tail -n +"${WL:-1}" "$OUT/wake.log" | grep -c '^COST')
  [ -n "$WL" ] && [ "$AFTER" -gt 5 ] && kill -0 $PID && res R4 PASS "wake logged, $AFTER COST lines after" || res R4 FAIL "wake=$WL after=$AFTER"; stop;;
network)  # B6
  reset; launch net.log; sleep 6; L="$(lsof -nP -a -i -p $PID 2>/dev/null | tail -n +2)"; stop
  S="$(nm -um "$APP" 2>/dev/null | grep -ciE 'URLSession|CFNetwork|NSURLConnection')"
  [ -z "$L" ] && [ "$S" = 0 ] && res B6 PASS "lsof -i empty; 0 URLSession/CFNetwork undefined symbols" || res B6 FAIL "lsof=[$L] symbols=$S";;
esac; done
reset
