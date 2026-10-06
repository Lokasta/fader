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

# notarytool exits 0 even when Apple rejects the upload, so check the status it reports.
RESULT=$(xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait 2>&1)
echo "$RESULT"
if [[ "$RESULT" != *"status: Accepted"* ]]; then
    ID=$(echo "$RESULT" | awk '/^  id:/ {print $2; exit}')
    echo "Notarization failed. Details: xcrun notarytool log $ID --keychain-profile $PROFILE" >&2
    exit 1
fi
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"

# A stable name too, so ".../releases/latest/download/LokastasFader.dmg" always points at the newest build.
cp "$DMG" dist/LokastasFader.dmg
(
    cd dist
    shasum -a 256 "LokastasFader-$VERSION.dmg" LokastasFader.dmg > SHA256SUMS
)
echo "Ready: $DMG (+ dist/LokastasFader.dmg and SHA256SUMS)"

if [[ "${PUBLISH:-0}" == 1 ]]; then
    if [[ -n "$(git status --porcelain)" ]] || [[ "$(git rev-parse "v$VERSION^{commit}")" != "$(git rev-parse HEAD)" ]]; then
        echo "Publish requires a clean checkout and v$VERSION tagged at HEAD. Commit and push the release tag first." >&2
        exit 1
    fi
    NOTES="$STAGE/release-notes.md"
    awk -v v="$VERSION" '$0 ~ "^## .* -- "v"$" {f=1; next} /^## / && f {exit} f' CHANGELOG.md > "$NOTES"
    if [[ ! -s "$NOTES" ]]; then
        echo "No changelog entry found for $VERSION." >&2
        exit 1
    fi
    cat >> "$NOTES" <<'INSTALL'

### Install

Download **LokastasFader.dmg**, open it and drag Fader into Applications. Requires macOS 15+. Signed with Developer ID and notarized by Apple. To update, replace the existing app; your app volumes and preferences are kept.

Chrome tab controls are optional: allow Fader to automate Chrome, enable **View > Developer > Allow JavaScript from Apple Events** in Chrome, then enable tab controls in Fader. Web Audio and unsupported players use Chrome's main slider.

Checksums are available in **SHA256SUMS**.

Full history: [CHANGELOG.md](https://github.com/Lokasta/fader/blob/main/CHANGELOG.md)
INSTALL
    gh release create "v$VERSION" "$DMG" dist/LokastasFader.dmg dist/SHA256SUMS --verify-tag --latest --title "Lokasta's Fader $VERSION" --notes-file "$NOTES"
fi
