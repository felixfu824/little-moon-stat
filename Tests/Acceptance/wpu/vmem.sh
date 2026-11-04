#!/bin/bash
# WP-U V6: RAM moon vs vm_stat with a bounded incompressible memory load. Usage: vmem.sh <bin> <out> <MiB>
set -uo pipefail
BIN="$1"; OUT="$2"; MIB="$3"; mkdir -p "$OUT"; PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }; trap cleanup EXIT
now() { perl -MTime::HiRes=time -e 'printf "%.2f\n", time'; }
ev() { echo "$(now) $*" >> "$OUT/events.txt"; }
: > "$OUT/events.txt"; ev start
"$BIN/mbdump" 60 closed > "$OUT/mb.jsonl" 2> "$OUT/mb.err" & EPID=$!; PIDS+=($EPID)
( while true; do echo "== $(now)"; vm_stat; sleep 2; done ) > "$OUT/vm.txt" & PIDS+=($!)
sysctl -n hw.memsize hw.pagesize > "$OUT/mem.txt"
sleep 15; ev memload-start; "$BIN/memhog" "$MIB" 20 & LP=$!; PIDS+=($LP); wait "$LP"; ev memload-end
wait "$EPID"; ev end; echo "done $(wc -l < "$OUT/mb.jsonl") publications"
