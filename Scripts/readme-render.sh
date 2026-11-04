#!/bin/bash
# Regenerates the README visuals (docs/readme/hero.png, docs/readme/moon-ramp.png) offline.
# No screen capture: the scene is composed from our own SwiftUI views over a generated wallpaper.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift build --product RenderCards
.build/debug/RenderCards --readme
