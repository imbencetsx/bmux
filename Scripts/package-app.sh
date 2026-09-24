#!/bin/sh
# Packages the built executable as a proper macOS app bundle so it gets
# Dock presence, Cmd-Tab, and full foreground behavior without relying on
# the runtime activation-policy override (which remains as a fallback for
# `swift run`).
set -eu
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
BIN=".build/$CONFIG/bmux"
APP="Bmux.app"

[ -x "$BIN" ] || { echo "missing $BIN — run 'swift build' first"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/Bmux"
# WINCH-aware recorder — must sit next to the app binary so PaneLauncher
# can copy it into Application Support on first spawn.
LAUNCH=".build/$CONFIG/bmux-launch"
if [ -x "$LAUNCH" ]; then
    cp "$LAUNCH" "$APP/Contents/MacOS/bmux-launch"
fi

# App icon: Icon Composer source vendored at Assets/bmux.icon, compiled with
# Xcode's actool into Contents/Resources/Assets.car. Info.plist points at it
# via CFBundleIconName (must match the .icon filename).
if [ -d "Assets/bmux.icon" ]; then
    ACTOOL="$(xcrun --find actool 2>/dev/null || command -v actool)"
    ACTOOL_OUT="$("$ACTOOL" --compile "$APP/Contents/Resources" \
        --platform macosx --minimum-deployment-target 14.0 \
        "Assets/bmux.icon" 2>&1)" || {
        echo "$ACTOOL_OUT" >&2
        echo "actool failed to compile Assets/bmux.icon" >&2
        exit 1
    }
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Bmux</string>
    <key>CFBundleDisplayName</key>
    <string>Bmux</string>
    <key>CFBundleIdentifier</key>
    <string>dev.bmux.app</string>
    <key>CFBundleVersion</key>
    <string>0.1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>Bmux</string>
    <key>CFBundleIconName</key>
    <string>bmux</string>
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
for b in .build/"$CONFIG"/*.bundle; do
    [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"
done

# Ad-hoc sign so LaunchServices/Gatekeeper accept the local bundle.
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "Built $APP — open with: open $APP"
