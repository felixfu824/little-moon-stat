#!/bin/bash
# Compiles the acceptance helpers into $1 (default ${TMPDIR:-/tmp}/wpt/bin). Needs `swift build -c release`
# for EngineDump/MonitorCore/Samplers/MonitorUI first. Run outside any sandbox.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:-${TMPDIR:-/tmp}/wpt/bin}"; mkdir -p "$OUT"
HERE="$ROOT/Tests/Acceptance"; REL="$ROOT/.build/release"
clang -O2 -o "$OUT/spin" "$HERE/spin.c"
clang -O2 -framework IOKit -framework CoreFoundation -o "$OUT/smcprobe" "$ROOT/docs/research/probe.c"
swiftc -O -o "$OUT/gpuload" "$HERE/gpuload.swift"
swiftc -O -o "$OUT/winq" "$HERE/winq.swift"
swiftc -O -I "$REL" "$REL/MonitorCore.o" "$REL/Samplers.o" "$REL/MonitorUI.o" -o "$OUT/liverender" "$HERE/liverender.swift"
cp "$REL/EngineDump" "$OUT/EngineDump"
ls "$OUT"
