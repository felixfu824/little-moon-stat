#!/bin/bash
# Builds "Little Moon.app" signed with Developer ID (hardened runtime), notarizes and staples it.
# Usage: NOTARY_PROFILE=<notarytool keychain profile> Scripts/release.sh
# Without NOTARY_PROFILE it stops after signing (signed, not notarized).
# Output: build/release/Little Moon.app and build/release/LittleMoon-<version>.zip
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Kuang Cheng Fu (8Z5RQYC6M5)}"
OUT="$ROOT/build/release"
APP="$OUT/Little Moon.app"

"$ROOT/Scripts/build.sh" release
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
rm -rf "$OUT"; mkdir -p "$OUT"
ditto "$ROOT/build/MacMonitorPanel.app" "$APP"

codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"
ZIP="$OUT/LittleMoon-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

if [ -z "${NOTARY_PROFILE:-}" ]; then
  echo "signed (NOT notarized): $APP"; exit 0
fi
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
rm -f "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"   # re-zip with the stapled ticket
spctl --assess --type execute --verbose=2 "$APP"
echo "notarized: $APP"
echo "zip: $ZIP"
