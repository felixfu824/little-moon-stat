#!/bin/bash
# Builds MacMonitorPanel.app into build/ and ad-hoc signs it.
# Usage: Scripts/build.sh [debug|release]   (default: release)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/MacMonitorPanel.app"

swift build --package-path "$ROOT" -c "$CONFIG" --product MacMonitorPanel
BIN_DIR="$(swift build --package-path "$ROOT" -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MacMonitorPanel" "$APP/Contents/MacOS/MacMonitorPanel"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
# Stamp the source commit (read by Sensor Report); "-dirty" when the tree has uncommitted changes.
COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
git -C "$ROOT" diff --quiet HEAD 2>/dev/null || COMMIT="$COMMIT-dirty"
/usr/libexec/PlistBuddy -c "Add :MonitorCommit string $COMMIT" "$APP/Contents/Info.plist"
# SwiftPM resource bundles (String Catalog etc.), if any target declares resources.
for b in "$BIN_DIR"/*.bundle; do
  [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"
done

codesign --force --sign - "$APP"
echo "built: $APP"
