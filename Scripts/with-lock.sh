#!/bin/bash
# Serializes hardware-bound work on the single M5 Max: screenshots, GUI checks,
# load tests (yes/Metal burn) and perf soaks. Parallel workers MUST wrap those in this.
# Usage: Scripts/with-lock.sh <label> <command...>
set -uo pipefail
LOCK=/tmp/mac-monitor-panel.hwlock
LABEL="$1"; shift
for _ in $(seq 1 600); do
  if mkdir "$LOCK" 2>/dev/null; then
    echo "$LABEL $$ $(date +%T)" > "$LOCK/owner"
    trap 'rm -rf "$LOCK"' EXIT
    "$@"
    exit $?
  fi
  sleep 2
done
echo "with-lock: gave up after 20 min; holder: $(cat "$LOCK/owner" 2>/dev/null)" >&2
exit 75
