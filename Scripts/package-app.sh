#!/bin/sh
# Packages the built executable as a proper macOS app bundle so it gets
# Dock presence, Cmd-Tab, and full foreground behavior without relying on
# the runtime activation-policy override (which remains as a fallback for
# `swift run`).
set -eu
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
BIN=".build/$CONFIG/bmux"
if [ ! -x "$BIN" ] && [ -x ".build/x86_64-apple-macosx/$CONFIG/bmux" ]; then
    BIN=".build/x86_64-apple-macosx/$CONFIG/bmux"
fi
APP="[bmux].app"

[ -x "$BIN" ] || { echo "missing $BIN — run 'swift build' first"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/Bmux"
# WINCH-aware recorder — must sit next to the app binary so PaneLauncher
# can copy it into Application Support on first spawn.
LAUNCH=".build/$CONFIG/bmux-launch"
if [ ! -x "$LAUNCH" ] && [ -x ".build/x86_64-apple-macosx/$CONFIG/bmux-launch" ]; then
    LAUNCH=".build/x86_64-apple-macosx/$CONFIG/bmux-launch"
fi
if [ -x "$LAUNCH" ]; then
    cp "$LAUNCH" "$APP/Contents/MacOS/bmux-launch"
fi

# App icon: If actool is functional (requires full Xcode), compile Assets/bmux2.icon into Assets.car.
# Otherwise, compile Assets/bmux2.icon/Assets/efasaf.png into AppIcon.icns via sips + iconutil.
if [ -d "Assets/bmux2.icon" ]; then
    if actool --version >/dev/null 2>&1; then
        ACTOOL="$(xcrun --find actool 2>/dev/null || command -v actool)"
        "$ACTOOL" --compile "$APP/Contents/Resources" \
            --platform macosx --minimum-deployment-target 14.0 \
            "Assets/bmux2.icon" >/dev/null 2>&1 || true
    fi
    if [ ! -f "$APP/Contents/Resources/Assets.car" ] && [ -f "Assets/bmux2.icon/Assets/efasaf.png" ]; then
        ICONSET_TMP="$(mktemp -d "${TMPDIR:-/tmp}/bmux-iconset.XXXXXX")"
        ICONSET_DIR="$ICONSET_TMP/AppIcon.iconset"
        mkdir -p "$ICONSET_DIR"
        SRC="Assets/bmux2.icon/Assets/efasaf.png"
        for sz in 16 32 128 256 512; do
            sips -z "$sz" "$sz" "$SRC" --out "$ICONSET_DIR/icon_${sz}x${sz}.png" >/dev/null 2>&1
            sips -z "$((sz * 2))" "$((sz * 2))" "$SRC" --out "$ICONSET_DIR/icon_${sz}x${sz}@2x.png" >/dev/null 2>&1
        done
        iconutil -c icns "$ICONSET_DIR" -o "$APP/Contents/Resources/AppIcon.icns"
        rm -rf "$ICONSET_TMP"
    fi
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>[bmux]</string>
    <key>CFBundleDisplayName</key>
    <string>[bmux]</string>
    <key>CFBundleIdentifier</key>
    <string>dev.bmux.app</string>
    <key>CFBundleVersion</key>
    <string>1.3.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.3.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>Bmux</string>
    <key>CFBundleIconName</key>
    <string>bmux2</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
PLIST

# Resource bundles produced by SPM (Ghostty shell-integration + terminfo).
BUNDLE_DIR=".build/$CONFIG"
if [ ! -d "$BUNDLE_DIR" ] && [ -d ".build/x86_64-apple-macosx/$CONFIG" ]; then
    BUNDLE_DIR=".build/x86_64-apple-macosx/$CONFIG"
fi
for b in "$BUNDLE_DIR"/*.bundle; do
    [ -e "$b" ] && cp -Rf "$b" "$APP/Contents/Resources/"
done

# Ad-hoc sign so LaunchServices/Gatekeeper accept the local bundle.
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "Built $APP — open with: open '$APP'"
