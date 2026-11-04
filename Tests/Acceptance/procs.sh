#!/bin/bash
# Process-ranking robustness run next to the real engine (EngineDump --json):
#   10-30 s  one spinning thread (B3 normalisation, B7 #1 ranking, B9 RSS)
#   45-65 s  4 threads under a 50+-char name with spaces and CJK (G2, G3), exits by itself (G4)
#   75-95 s  process churn: thousands of short-lived /usr/bin/true (G1)
# All loads are bounded and killed by PID on exit. Usage: procs.sh <bin dir> <out dir>
set -uo pipefail
BIN="$1"; OUT="$2"; mkdir -p "$OUT"
LONG="$OUT/Acceptance Long Process Name 測試 Worker With Many Characters"
cp "$BIN/spin" "$LONG"
PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT
now() { perl -MTime::HiRes=time -e 'printf "%.2f\n", time'; }
ev() { echo "$(now) $*" >> "$OUT/events.txt"; }
: > "$OUT/events.txt"; ev start ncpu=$(sysctl -n hw.ncpu)
"$BIN/EngineDump" --json --seconds 110 > "$OUT/engine.jsonl" 2> "$OUT/engine.err" & EPID=$!; PIDS+=($EPID)
top -l 55 -s 2 -o cpu -n 6 -stats pid,command,cpu,rsize > "$OUT/top.txt" 2>&1 & PIDS+=($!)
( while true; do echo "== $(now)"; ps -A -o pid=,rss=,comm=; sleep 5; done ) > "$OUT/ps.txt" & PIDS+=($!)
sleep 10
ev single-start; "$BIN/spin" 1 20 & P=$!; PIDS+=($P); echo "$P" > "$OUT/single.pid"; wait "$P"; ev single-end
sleep 15
ev long-start; "$LONG" 4 20 & P=$!; PIDS+=($P); echo "$P" > "$OUT/long.pid"; wait "$P"; ev long-end
sleep 10
ev churn-start
N=0; END=$(( $(date +%s) + 20 ))
while [ "$(date +%s)" -lt "$END" ]; do C=(); for _ in $(seq 1 50); do /usr/bin/true & C+=($!); done; wait "${C[@]}"; N=$((N + 50)); done
ev churn-end n=$N
wait "$EPID"; ev end
tail -1 "$OUT/engine.jsonl"; echo "churn processes: $N"
