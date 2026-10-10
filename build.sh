#!/bin/bash
# Builds Kadr.app from the Swift package.
#   ./build.sh           -> build/Kadr.app
#   ./build.sh install   -> also copies to /Applications and launches
# Optional: KADR_SIGN_ID="Kadr Dev" to sign with a stable self-signed certificate,
# so macOS keeps the Screen Recording permission between rebuilds.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/Kadr.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Kadr" "$APP/Contents/MacOS/Kadr"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# App icon generated from an SF Symbol-free drawing script (optional, skipped on failure).
if [ ! -f build/AppIcon.icns ]; then
    swift Resources/make-icon.swift build/AppIcon.iconset >/dev/null 2>&1 \
        && iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns || true
fi
[ -f build/AppIcon.icns ] && cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

SIGN_ID="${KADR_SIGN_ID:--}"
codesign --force --sign "$SIGN_ID" "$APP"
echo "Built $APP (signed with: $SIGN_ID)"

if [ "${1:-}" = "install" ]; then
    pkill -x Kadr 2>/dev/null || true
    rm -rf /Applications/Kadr.app
    cp -R "$APP" /Applications/
    open /Applications/Kadr.app
    echo "Installed to /Applications/Kadr.app"
fi
