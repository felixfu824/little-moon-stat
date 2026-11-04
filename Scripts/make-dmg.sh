#!/bin/bash
# Packages the notarized build/release/Little Moon.app into a signed, notarized, stapled DMG
# (same steps as Lamitype's docs/RELEASING.md). Run Scripts/release.sh with NOTARY_PROFILE first.
# Usage: NOTARY_PROFILE=<notarytool keychain profile> Scripts/make-dmg.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Kuang Cheng Fu (8Z5RQYC6M5)}"
OUT="$ROOT/build/release"
APP="$OUT/Little Moon.app"
: "${NOTARY_PROFILE:?Set the notarytool keychain profile name}"

xcrun stapler validate "$APP"            # the app itself must already be notarized + stapled
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$OUT/LittleMoon-v$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Little Moon.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Little Moon" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

codesign --force --sign "$IDENTITY" --timestamp "$DMG"
codesign --verify --verbose=2 "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"
hdiutil verify "$DMG"

# Re-verify the app as a user gets it from the DMG.
MNT="$(mktemp -d)"
hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$DMG" >/dev/null
codesign --verify --deep --strict --verbose=2 "$MNT/Little Moon.app"
xcrun stapler validate "$MNT/Little Moon.app"
spctl --assess --type execute --verbose=2 "$MNT/Little Moon.app"
hdiutil detach "$MNT" >/dev/null
rmdir "$MNT"

shasum -a 256 "$DMG"
echo "dmg: $DMG"
