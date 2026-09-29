#!/bin/sh
# Builds a distributable Bmux.dmg (drag-to-Applications) from a release build.
# Usage: ./Scripts/package-dmg.sh [release|debug]
set -eu
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="Bmux.app"
DMG="Bmux.dmg"
VOLNAME="Bmux"

swift build -c "$CONFIG"
./Scripts/package-app.sh "$CONFIG"

[ -d "$APP" ] || { echo "missing $APP — package-app.sh failed"; exit 1; }

rm -rf dmg-staging "$DMG"
mkdir -p dmg-staging
cp -R "$APP" dmg-staging/
ln -s /Applications dmg-staging/Applications
diskutil image create from --format UDZO --volumeName "$VOLNAME" dmg-staging "$DMG" || hdiutil create -volname "$VOLNAME" -srcfolder dmg-staging -ov -format UDZO "$DMG"
rm -rf dmg-staging

echo "Built $DMG"
