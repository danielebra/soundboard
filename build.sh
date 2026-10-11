#!/bin/bash
# Builds Soundboard.app into ./build. Pass --install to copy it to /Applications.
# SOUNDBOARD_VERSION / SOUNDBOARD_BUILD set the version shown in Finder (see the Makefile).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/Soundboard.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Soundboard "$APP/Contents/MacOS/Soundboard"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Download helper (not sandboxed — it's the one piece allowed online, used only for Fetch).
HELPER="$APP/Contents/Helpers/SoundboardFetch.app"
mkdir -p "$HELPER/Contents/MacOS"
cp .build/release/SoundboardFetch "$HELPER/Contents/MacOS/SoundboardFetch"
cp Resources/FetchInfo.plist "$HELPER/Contents/Info.plist"

for plist in "$APP/Contents/Info.plist" "$HELPER/Contents/Info.plist"; do
    if [[ -n "${SOUNDBOARD_VERSION:-}" ]]; then
        plutil -replace CFBundleShortVersionString -string "$SOUNDBOARD_VERSION" "$plist"
    fi
    if [[ -n "${SOUNDBOARD_BUILD:-}" ]]; then
        plutil -replace CFBundleVersion -string "$SOUNDBOARD_BUILD" "$plist"
    fi
done

# Ad-hoc signatures: nothing leaves your machine, no Apple account needed.
codesign --force --sign - --options runtime "$HELPER"
codesign --force --sign - --entitlements Resources/Soundboard.entitlements --options runtime "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    osascript -e 'quit app "Soundboard"' 2>/dev/null || true
    rm -rf /Applications/Soundboard.app
    cp -R "$APP" /Applications/
    echo "Installed /Applications/Soundboard.app"
fi
