#!/bin/bash
# Builds Soundboard.app into ./build. Pass --install to copy it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/Soundboard.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Soundboard "$APP/Contents/MacOS/Soundboard"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature: nothing leaves your machine, no Apple account needed.
codesign --force --sign - --entitlements Resources/Soundboard.entitlements --options runtime "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    osascript -e 'quit app "Soundboard"' 2>/dev/null || true
    rm -rf /Applications/Soundboard.app
    cp -R "$APP" /Applications/
    echo "Installed /Applications/Soundboard.app"
fi
