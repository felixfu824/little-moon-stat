#!/bin/bash
# Invoke from repository root, OUTSIDE the sandbox:
# Scripts/with-lock.sh glass bash Spikes/SpikeGlass/run-evidence.sh [output-directory]
set -euo pipefail
output="${1:-docs/spikes/glass}"
spike_pid=""
cleanup() {
  if [[ -n "$spike_pid" ]]; then
    kill "$spike_pid" 2>/dev/null || true
    wait "$spike_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT
for variant in appkit-clear appkit-tinted swiftui visualeffect; do
  destination="$output/$variant"
  mkdir -p "$destination"
  rm -f "$destination/ready"
  .build/debug/SpikeGlass "$variant" --out "$destination" > "$destination/runtime.log" 2>&1 &
  spike_pid=$!
  for ((attempt=0; attempt<120; attempt++)); do
    if [[ -f "$destination/ready" ]]; then break; fi
    if ! kill -0 "$spike_pid" 2>/dev/null; then
      cat "$destination/runtime.log"
      wait "$spike_pid"
      exit 1
    fi
    sleep 0.5
  done
  if [[ ! -f "$destination/ready" ]]; then
    cat "$destination/runtime.log"
    echo "Timed out waiting for $variant evidence" >&2
    exit 1
  fi
  echo "variant=$variant pid=$spike_pid static backdrop; 10 samples every 2 s"
  echo "elapsed_seconds,cpu_percent" > "$destination/cpu.csv"
  for ((sample=1; sample<=10; sample++)); do
    sleep 2
    cpu=$(ps -o %cpu= -p "$spike_pid" | tr -d ' ')
    [[ -n "$cpu" ]] || { echo "ps returned empty" >&2; exit 1; }
    echo "$((sample * 2)),$cpu" | tee -a "$destination/cpu.csv"
  done
  cleanup
  spike_pid=""
  rm "$destination/ready"
done
