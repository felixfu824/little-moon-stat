#!/bin/bash
# WP-U V1-V6: real engine (mbdump, menu-bar-closed configuration by default) next to independent references
# (raw SMC probe, vm_stat) through rest -> CPU load -> cooldown -> Metal load -> cooldown -> +2 GiB memory -> rest.
# Every load is bounded (<= 20 s, self-terminating) and killed by PID. Usage: vtimeline.sh <bin> <out> [closed|open]
set -uo pipefail
BIN="$1"; OUT="$2"; CFG="${3:-closed}"; mkdir -p "$OUT"
NCPU="$(sysctl -n hw.ncpu)"
REST=30; CPUL=20; COOL1=60; GPUL=20; COOL2=30; MEML=20; COOL3=20
TOTAL=$((REST + CPUL + COOL1 + GPUL + COOL2 + MEML + COOL3))
PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT
now() { perl -MTime::HiRes=time -e 'printf "%.2f\n", time'; }
ev() { echo "$(now) $*" >> "$OUT/events.txt"; }
: > "$OUT/events.txt"; ev start ncpu=$NCPU cfg=$CFG
"$BIN/mbdump" "$TOTAL" "$CFG" > "$OUT/mb.jsonl" 2> "$OUT/mb.err" & EPID=$!; PIDS+=($EPID)
( while true; do echo "== $(now)"; vm_stat; sleep 2; done ) > "$OUT/vm.txt" & PIDS+=($!)
( while true; do echo "== $(now)"; "$BIN/smcprobe" | grep '^SMC'; sleep 3; done ) > "$OUT/smc.txt" & PIDS+=($!)
sysctl -n hw.memsize hw.pagesize > "$OUT/mem.txt"
sleep "$REST"
ev cpuload-start; "$BIN/spin" "$NCPU" "$CPUL" & LP=$!; PIDS+=($LP); wait "$LP"; ev cpuload-end
sleep "$COOL1"
ev gpuload-start; "$BIN/gpuload" "$GPUL" & LP=$!; PIDS+=($LP); wait "$LP"; ev gpuload-end
sleep "$COOL2"
ev memload-start; "$BIN/memhog" 2048 "$MEML" & LP=$!; PIDS+=($LP); wait "$LP"; ev memload-end
wait "$EPID"; ev end
echo "done: $OUT ($(wc -l < "$OUT/mb.jsonl") publications)"
