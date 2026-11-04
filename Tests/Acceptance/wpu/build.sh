#!/bin/bash
# Builds the WP-U helpers into $1 (needs `swift build -c release` first). Run outside any sandbox.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"; OUT="${1:-${TMPDIR:-/tmp}/wpu/bin}"; mkdir -p "$OUT"
HERE="$ROOT/Tests/Acceptance/wpu"; ACC="$ROOT/Tests/Acceptance"; REL="$ROOT/.build/release"
clang -O2 -o "$OUT/spin" "$ACC/spin.c"
clang -O2 -o "$OUT/memhog" "$HERE/memhog.c"
clang -O2 -framework IOKit -framework CoreFoundation -o "$OUT/smcprobe" "$ROOT/docs/research/probe.c"
swiftc -O -o "$OUT/gpuload" "$ACC/gpuload.swift"
swiftc -O -o "$OUT/winq" "$ACC/winq.swift"
swiftc -O -o "$OUT/statusq" "$HERE/statusq.swift"
swiftc -parse-as-library -O -I "$REL" "$REL/MonitorCore.o" "$REL/MonitorUI.o" -o "$OUT/modelcheck" "$HERE/modelcheck.swift"
swiftc -O -I "$REL" "$REL/MonitorCore.o" "$REL/Samplers.o" -o "$OUT/mbdump" "$HERE/mbdump.swift"
cp "$REL/EngineDump" "$OUT/EngineDump"
ls "$OUT"
