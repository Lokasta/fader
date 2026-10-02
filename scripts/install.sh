#!/bin/bash
# Builds Fader in Release, installs it to /Applications and (re)launches it.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate --quiet
xcodebuild -project Fader.xcodeproj -scheme Fader -configuration Release -derivedDataPath build build -quiet

pkill -x Fader 2>/dev/null && sleep 1 || true
rm -rf /Applications/Fader.app
ditto build/Build/Products/Release/Fader.app /Applications/Fader.app
open /Applications/Fader.app
echo "Fader $(defaults read /Applications/Fader.app/Contents/Info.plist CFBundleShortVersionString) instalado e aberto."
