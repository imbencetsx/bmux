#!/bin/sh
# Builds a distributable [bmux].dmg (drag-to-Applications) from a release build.
# Usage: ./Scripts/package-dmg.sh [release|debug]
set -eu
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="[bmux].app"
VOLNAME="[bmux]"

# Prepare toolchain fixes for CommandLineTools manifest & bridging header bugs
FIX_DIR="$(pwd)/.build/manifest-fix"
if [ ! -d "$FIX_DIR/ManifestAPI" ]; then
    mkdir -p "$FIX_DIR/ManifestAPI"
    CLT_MANIFEST_DIR="$(xcode-select -p)/usr/lib/swift/pm/ManifestAPI"
    if [ -d "$CLT_MANIFEST_DIR" ]; then
        cp -R "$CLT_MANIFEST_DIR"/* "$FIX_DIR/ManifestAPI/"
        rm -f "$FIX_DIR/ManifestAPI"/PackageDescription.swiftmodule/*.private.swiftinterface
    fi
fi
if [ ! -f "$FIX_DIR/vfs.yaml" ]; then
    mkdir -p "$FIX_DIR"
    touch "$FIX_DIR/empty.modulemap"
    cat > "$FIX_DIR/vfs.yaml" <<EOF
{
  "version": 0,
  "case-sensitive": "false",
  "roots": [
    {
      "type": "directory",
      "name": "$(xcode-select -p)/usr/include/swift",
      "contents": [
        {
          "type": "file",
          "name": "bridging.modulemap",
          "external-contents": "$FIX_DIR/empty.modulemap"
        }
      ]
    }
  ]
}
EOF
fi

export SWIFTPM_CUSTOM_LIBS_DIR="$FIX_DIR"
EXTRA_SWIFTC_FLAGS=""
if [ -f "$FIX_DIR/vfs.yaml" ]; then
    EXTRA_SWIFTC_FLAGS="-Xswiftc -vfsoverlay -Xswiftc $FIX_DIR/vfs.yaml"
fi

swift build -c "$CONFIG" --triple x86_64-apple-macosx $EXTRA_SWIFTC_FLAGS
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
    rm -rf "$DMG_TOOLS"
    python3 -m venv "$DMG_TOOLS"
    "$DMG_TOOLS/bin/pip" install 'dmgbuild==1.6.5' 'ds-store==1.3.1' 'mac-alias==2.2.2'
fi
if [ -f "$FIX_DIR/vfs.yaml" ]; then
    swift -vfsoverlay "$FIX_DIR/vfs.yaml" Scripts/dmg-background.swift "$WORK_DIR/background.png"
else
    swift Scripts/dmg-background.swift "$WORK_DIR/background.png"
fi
"$DMG_TOOLS/bin/dmgbuild" -s Scripts/dmg-settings.py \
    -D "background=$WORK_DIR/background.png" "$VOLNAME" "$DMG"

echo "Built $DMG"
