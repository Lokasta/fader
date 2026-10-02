#!/bin/bash
# Builds a Developer ID signed, notarized DMG for GitHub Releases: dist/LokastasFader-<version>.dmg
#
# One-time setup:
#   1. Config/Local.xcconfig with your identity (see Config/Signing.xcconfig), plus
#      OTHER_CODE_SIGN_FLAGS = --timestamp
#   2. xcrun notarytool store-credentials lokasta-notary --apple-id <you> --team-id <TEAM>
#      (asks for an app-specific password from account.apple.com)
set -euo pipefail
cd "$(dirname "$0")/.."
PROFILE="${NOTARY_PROFILE:-lokasta-notary}"
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "No notarytool credentials named '$PROFILE'. Run the store-credentials step above." >&2
    exit 1
fi

xcodegen generate --quiet
xcodebuild -project Fader.xcodeproj -scheme Fader -configuration Release -derivedDataPath build build -quiet

APP=build/Build/Products/Release/Fader.app
VERSION=$(defaults read "$PWD/$APP/Contents/Info.plist" CFBundleShortVersionString)
codesign --verify --strict --deep "$APP"
SIGNATURE=$(codesign -dv --verbose=2 "$APP" 2>&1)
if [[ "$SIGNATURE" != *"Authority=Developer ID Application"* ]]; then
    echo "Not signed with Developer ID: set up Config/Local.xcconfig first." >&2
    exit 1
fi

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Fader.app"
ln -s /Applications "$STAGE/Applications"

mkdir -p dist
DMG="dist/LokastasFader-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Lokasta's Fader" -srcfolder "$STAGE" -format UDZO -quiet "$DMG"
codesign --sign "Developer ID Application" --timestamp "$DMG"

xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"

# A stable name too, so ".../releases/latest/download/LokastasFader.dmg" always points at the newest build.
cp "$DMG" dist/LokastasFader.dmg
echo "Ready: $DMG (+ dist/LokastasFader.dmg)"

if [[ "${PUBLISH:-0}" == 1 ]]; then
    NOTES=$(awk -v v="$VERSION" '$0 ~ "^## .* -- "v"$" {f=1; next} /^## / && f {exit} f' CHANGELOG.md)
    gh release create "v$VERSION" "$DMG" dist/LokastasFader.dmg --title "Lokasta's Fader $VERSION" --notes "$NOTES"
fi
