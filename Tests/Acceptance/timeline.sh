#!/bin/bash
# Correctness + temperature timeline. Runs the real engine (EngineDump --json) next to independent
# references (top, ioreg, vm_stat, df, SMC probe, thermal state) through rest -> CPU load -> cooldown ->
# GPU load -> cooldown. Every load is bounded (spin/gpuload exit by themselves) and killed by PID.
# Usage: timeline.sh <bin dir> <out dir>    (run outside any sandbox; on the Pro under with-lock.sh)
set -uo pipefail
BIN="$1"; OUT="$2"; mkdir -p "$OUT"
NCPU="$(sysctl -n hw.ncpu)"
REST=30; CPUL=20; COOL1=60; GPUL=20; COOL2=30
TOTAL=$((REST + CPUL + COOL1 + GPUL + COOL2))
PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT
now() { perl -MTime::HiRes=time -e 'printf "%.2f\n", time'; }
ev() { echo "$(now) $*" >> "$OUT/events.txt"; }
: > "$OUT/events.txt"
ev start ncpu=$NCPU

"$BIN/EngineDump" --json --seconds "$TOTAL" > "$OUT/engine.jsonl" 2> "$OUT/engine.err" & PIDS+=($!); EPID=$!
top -l $((TOTAL / 2)) -s 2 -o cpu -n 8 -stats pid,command,cpu,rsize > "$OUT/top.txt" 2>&1 & PIDS+=($!)
( while true; do
    echo "$(now) $(ioreg -r -c IOAccelerator -d 1 | grep -o '"Device Utilization %"=[0-9]*' | head -1)"
    sleep 2; done ) > "$OUT/gpu.txt" & PIDS+=($!)
( while true; do echo "== $(now)"; vm_stat; sleep 10; done ) > "$OUT/vm.txt" & PIDS+=($!)
( while true; do echo "== $(now)"; "$BIN/smcprobe" | grep '^SMC'; sleep 3; done ) > "$OUT/smc.txt" & PIDS+=($!)
( while true; do echo "$(now) $("$BIN/winq" thermal)"; sleep 5; done ) > "$OUT/thermal.txt" & PIDS+=($!)
{ df -k /; diskutil info / | grep -E 'Container (Total|Free) Space|Volume Name|Disk / Partition Size'; } > "$OUT/disk.txt" 2>&1
sysctl -n hw.memsize hw.pagesize > "$OUT/mem.txt"

sleep "$REST"
ev cpuload-start; "$BIN/spin" "$NCPU" "$CPUL" & LP=$!; PIDS+=($LP); wait "$LP"; ev cpuload-end
sleep "$COOL1"
ev gpuload-start; "$BIN/gpuload" "$GPUL" & LP=$!; PIDS+=($LP); wait "$LP"; ev gpuload-end
sleep "$COOL2"
wait "$EPID"; ev end
cat "$OUT/engine.err" | tail -2
echo "done: $OUT"
