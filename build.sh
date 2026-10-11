#!/bin/bash
# Builds Soundboard.app into ./build.
#   --install  copy it to /Applications
#   --dmg      also package build/Soundboard.dmg (drag-to-Applications disk image)
# SOUNDBOARD_VERSION / SOUNDBOARD_BUILD set the version shown in Finder (CI sets them).
set -euo pipefail
cd "$(dirname "$0")"

INSTALL=0 DMG=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        --dmg) DMG=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

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
    [[ -n "${SOUNDBOARD_VERSION:-}" ]] && plutil -replace CFBundleShortVersionString -string "$SOUNDBOARD_VERSION" "$plist"
    [[ -n "${SOUNDBOARD_BUILD:-}" ]] && plutil -replace CFBundleVersion -string "$SOUNDBOARD_BUILD" "$plist"
done

# Ad-hoc signatures: nothing leaves your machine, no Apple account needed.
codesign --force --sign - --options runtime "$HELPER"
codesign --force --sign - --entitlements Resources/Soundboard.entitlements --options runtime "$APP"
echo "Built $APP"

if [[ $DMG == 1 ]]; then
    STAGE=build/dmg
    rm -rf build/dmg build/Soundboard.dmg
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname Soundboard -srcfolder "$STAGE" -format UDZO -fs HFS+ build/Soundboard.dmg
    rm -rf build/dmg
    echo "Built build/Soundboard.dmg"
fi

if [[ $INSTALL == 1 ]]; then
    osascript -e 'quit app "Soundboard"' 2>/dev/null || true
    rm -rf /Applications/Soundboard.app
    cp -R "$APP" /Applications/
    echo "Installed /Applications/Soundboard.app"
fi
