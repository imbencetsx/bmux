#!/bin/sh
# Builds a distributable [bmux].dmg (drag-to-Applications) from a release build.
# Usage: ./Scripts/package-dmg.sh [release|debug]
set -eu
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="[bmux].app"
VOLNAME="[bmux]"

swift build -c "$CONFIG"
./Scripts/package-app.sh "$CONFIG"

[ -d "$APP" ] || { echo "missing $APP — package-app.sh failed"; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ARCHITECTURES="$(lipo -archs "$APP/Contents/MacOS/Bmux")"
case "$ARCHITECTURES" in
    arm64) ARCH="arm64" ;;
    x86_64) ARCH="x86_64" ;;
    "arm64 x86_64"|"x86_64 arm64") ARCH="universal" ;;
    *) echo "Unsupported app architectures: $ARCHITECTURES" >&2; exit 1 ;;
esac
DMG="bmux-$VERSION-macos-$ARCH.dmg"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bmux-dmg.XXXXXX")"
cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT HUP INT TERM

DMG_TOOLS=".build/dmg-tools"
if [ ! -x "$DMG_TOOLS/bin/dmgbuild" ]; then
    python3 -m venv "$DMG_TOOLS"
    "$DMG_TOOLS/bin/pip" install 'dmgbuild==1.6.7' 'ds-store==1.3.3' 'mac-alias==2.2.3'
fi
swift Scripts/dmg-background.swift "$WORK_DIR/background.png"
"$DMG_TOOLS/bin/dmgbuild" -s Scripts/dmg-settings.py \
    -D "background=$WORK_DIR/background.png" "$VOLNAME" "$DMG"

echo "Built $DMG"
