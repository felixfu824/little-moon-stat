#!/bin/bash
# Live-app acceptance checks (D3-D8, E1-E3, F4, G5). Window metadata only; with CAPTURE=1 it also
# captures OUR OWN window by id (screencapture -l), never a region or the screen. The app's defaults
# domain is backed up and restored. Every launched app is killed by PID.
# Usage: [CAPTURE=1] app_checks.sh <helper bin dir> <repo root> <out dir>
set -uo pipefail
BIN="$1"; ROOT="$2"; OUT="$3"; mkdir -p "$OUT"
APP="$ROOT/build/MacMonitorPanel.app/Contents/MacOS/MacMonitorPanel"
DOM=com.felixfu.MacMonitorPanel
PID=""; PID2=""
had=0; defaults export "$DOM" "$OUT/defaults-backup.plist" 2>/dev/null && had=1
stop() { for p in $PID $PID2; do kill "$p" 2>/dev/null; for _ in 1 2 3 4 5 6 7 8; do kill -0 "$p" 2>/dev/null || break; sleep 0.25; done; kill -9 "$p" 2>/dev/null; done; PID=""; PID2=""; }
restore() { stop; defaults delete "$DOM" 2>/dev/null; [ "$had" = 1 ] && defaults import "$DOM" "$OUT/defaults-backup.plist"; }
trap restore EXIT
reset() { defaults delete "$DOM" 2>/dev/null; true; }
launch() { local log="$1"; shift; "$APP" "$@" 2> "$OUT/$log" & PID=$!; }
win() { local l; l="$("$BIN/winq" window "$PID" | grep 'layer=-1' | head -1)"; echo "${l:-none}"; }
f() { echo "$2" | tr ' ' '\n' | sed -n "s/^$1=//p"; }
waitwin() { local prev="" cur; for _ in $(seq 1 30); do cur="$(win)"; if [ "$cur" != none ] && [ "$cur" = "$prev" ]; then W="$cur"; return 0; fi; prev="$cur"; sleep 0.7; done; W="$cur"; return 1; }
res() { echo "RESULT $1 $2 :: $3"; }
cap() { if [ "${CAPTURE:-0}" = 1 ]; then screencapture -x -o -l "$(f id "$W")" "$OUT/$1" && echo "captured own window $(f id "$W") -> $1"; fi; }

SCR="$("$BIN/winq" screens | head -1)"; echo "$SCR"
VIS="$(echo "$SCR" | sed -n 's/.*visible=(\([^)]*\)).*/\1/p' | tr -d ' ')"
FRH="$(echo "$SCR" | sed -n 's/.*frame=([^,]*,[^,]*,[^,]*, *\([0-9.]*\)).*/\1/p')"; FRH="${FRH%.*}"
VX="$(echo "$VIS" | cut -d, -f1)"; VX="${VX%.*}"; VY="$(echo "$VIS" | cut -d, -f2)"; VY="${VY%.*}"
OX=$((VX + 200)); OY=$((VY + 200))

echo "== D4/D8 large clear en"; reset; defaults write $DOM size large; defaults write $DOM glass clear; defaults write $DOM language en
launch large.log; waitwin; echo "$W"; LH="$(f h "$W")"
[ "$(f layer "$W")" = -1 ] && [ "$(f onscreen "$W")" = true ] && [ "$(f inside "$W")" = true ] && [ "$(f w "$W")" = 360 ] \
  && res D4 PASS "large $W" || res D4 FAIL "large $W"
sleep 6; cap large-clear-en.png
echo "lsof -i: [$(lsof -nP -a -i -p "$PID" 2>/dev/null | tail -n +2)]"
[ -z "$(lsof -nP -a -i -p "$PID" 2>/dev/null | tail -n +2)" ] && res F4 PASS "no internet sockets for pid $PID" || res F4 FAIL "sockets open"
stop

echo "== D4 medium tinted zh-Hant"; reset; defaults write $DOM size medium; defaults write $DOM glass tinted; defaults write $DOM language zh-Hant
launch medium.log; waitwin; echo "$W"; MH="$(f h "$W")"
[ "$(f layer "$W")" = -1 ] && [ "$(f inside "$W")" = true ] && [ "$(f w "$W")" = 360 ] && [ "$MH" -lt "$LH" ] \
  && res D4m PASS "medium h=$MH < large h=$LH" || res D4m FAIL "medium $W large h=$LH"
sleep 6; cap medium-tinted-zh.png; stop

echo "== D3 large tinted zh-Hant + medium clear en (captures)"; reset; defaults write $DOM size large; defaults write $DOM glass tinted; defaults write $DOM language zh-Hant
launch large-zh.log; waitwin; sleep 6; cap large-tinted-zh.png; stop
reset; defaults write $DOM size medium; defaults write $DOM language en
launch medium-en.log; waitwin; sleep 6; cap medium-clear-en.png; stop

echo "== D5 saved origin, simulated drag, relaunch"; reset; defaults write $DOM panelOriginX -float $OX; defaults write $DOM panelOriginY -float $OY
launch d5.log --simulate-move-after 2; waitwin; echo "$W"
EY=$((FRH - (OY + LH)))
[ "$(f x "$W")" = "$OX" ] && [ "$(f y "$W")" = "$EY" ] && res D5a PASS "restored x=$OX cgY=$EY" || res D5a FAIL "expected x=$OX y=$EY got $W"
sleep 4; NX="$(defaults read $DOM panelOriginX)"; NY="$(defaults read $DOM panelOriginY)"; stop
[ "${NX%.*}" = $((OX + 50)) ] && [ "${NY%.*}" = $((OY - 50)) ] && res D5b PASS "drag saved $NX,$NY" || res D5b FAIL "saved $NX,$NY"
launch d5b.log; waitwin; EY=$((FRH - (OY - 50 + LH)))
[ "$(f x "$W")" = $((OX + 50)) ] && [ "$(f y "$W")" = "$EY" ] && res D5c PASS "relaunch at dragged origin $W" || res D5c FAIL "$W expected x=$((OX+50)) y=$EY"
stop

echo "== D6 off-screen origin"; reset; defaults write $DOM panelOriginX -float 99999; defaults write $DOM panelOriginY -float 99999
launch d6.log; waitwin; echo "$W"
[ "$(f inside "$W")" = true ] && [ "$(f onscreen "$W")" = true ] && res D6 PASS "$W" || res D6 FAIL "$W"; stop

echo "== D7 invalid defaults"; reset; defaults write $DOM size bogus; defaults write $DOM glass bogus; defaults write $DOM language bogus
launch d7.log; waitwin; sleep 3; cat "$OUT/d7.log"
kill -0 "$PID" && [ "$(f h "$W")" = "$LH" ] && grep -q "size=large glass=clear lang=en" "$OUT/d7.log" && res D7 PASS "fell back to large/clear/en" || res D7 FAIL "$W"; stop

echo "== E1 hidden launch"; reset; defaults write $DOM panelVisible -bool false
MAC_MONITOR_PROFILE=1 "$APP" 2> "$OUT/e1.log" & PID=$!
sleep 3; T0="$(ps -o time= -p $PID)"; sleep 30; T1="$(ps -o time= -p $PID)"; W="$(win)"
echo "window: $W cputime $T0 -> $T1"; cat "$OUT/e1.log" | head -5
tosec() { echo "$1" | awk -F'[:.]' '{print $1*60+$2+$3/100}'; }
CPU="$(awk -v a="$(tosec $T0)" -v b="$(tosec $T1)" 'BEGIN{printf "%.3f", (b-a)/30*100}')"
{ [ "$W" = none ] || [ "$(f onscreen "$W")" = false ]; } && ! grep -q '^COST' "$OUT/e1.log" && grep -q "engine pause" "$OUT/e1.log" \
  && awk -v c="$CPU" 'BEGIN{exit !(c < 0.05)}' && res E1 PASS "hidden, no COST lines, cpu ${CPU}%" || res E1 FAIL "win=$W cpu=${CPU}% COST=$(grep -c '^COST' "$OUT/e1.log")"
stop

echo "== E2 simulated wake while visible"; reset
MAC_MONITOR_PROFILE=1 "$APP" --simulate-wake-after 4 2> "$OUT/e2.log" & PID=$!
sleep 14; ALIVE=$(kill -0 $PID 2>/dev/null && echo yes || echo no)
WL="$(grep -n 'wake handled' "$OUT/e2.log" | cut -d: -f1)"
AFTER="$( [ -n "$WL" ] && tail -n +"$WL" "$OUT/e2.log" | grep -c '^COST' || echo 0)"
grep 'wake handled' "$OUT/e2.log"; echo "COST lines after wake: $AFTER alive=$ALIVE"
[ -n "$WL" ] && [ "$AFTER" -gt 5 ] && [ "$ALIVE" = yes ] && res E2 PASS "wake logged, $AFTER COST lines after" || res E2 FAIL "wake=$WL after=$AFTER alive=$ALIVE"
stop

echo "== E3 runtime option change"; reset; defaults write $DOM panelOriginX -float $OX; defaults write $DOM panelOriginY -float $OY
launch e3.log --simulate-options-after 4; waitwin; B="$W"; sleep 6; waitwin; A="$W"; echo "before $B"; echo "after  $A"
S="$(defaults read $DOM size) $(defaults read $DOM glass) $(defaults read $DOM language)"
[ "$(f h "$B")" = "$LH" ] && [ "$(f h "$A")" = "$MH" ] && [ "$(f y "$B")" = "$(f y "$A")" ] && [ "$S" = "medium tinted zh-Hant" ] \
  && res E3 PASS "h $LH->$MH, top edge fixed, persisted '$S'" || res E3 FAIL "before=$B after=$A persisted='$S'"
stop

echo "== G5 two instances"; reset
launch g5a.log; sleep 4; A1=$PID; "$APP" 2> "$OUT/g5b.log" & PID2=$!; sleep 5
N1="$("$BIN/winq" window $A1 | grep -c 'layer=-1')"; N2="$("$BIN/winq" window $PID2 | grep -c 'layer=-1')"
AL2=$(kill -0 $PID2 2>/dev/null && echo yes || echo no)
echo "first pid $A1 panels=$N1; second pid $PID2 alive=$AL2 panels=$N2"
if [ "$AL2" = no ]; then res G5 PASS "second instance exited"; elif [ "$N2" -ge 1 ]; then res G5 MINOR "two panels on screen ($A1, $PID2)"; else res G5 PASS "second alive, no panel"; fi
stop
echo "== done"
