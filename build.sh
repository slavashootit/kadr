#!/bin/bash
# Builds Kadr.app from the Swift package.
#   ./build.sh           -> build/Kadr.app
#   ./build.sh install   -> also copies to /Applications and launches
#   ./build.sh dmg       -> also packs build/Kadr.dmg and build/Kadr.zip for distribution
# The version comes from the VERSION file (single source of truth).
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
VERSION="$(tr -d '[:space:]' < VERSION)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"

# App icon generated from an SF Symbol-free drawing script (optional, skipped on failure).
if [ ! -f build/AppIcon.icns ]; then
    swift Resources/make-icon.swift build/AppIcon.iconset >/dev/null 2>&1 \
        && iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns || true
fi
[ -f build/AppIcon.icns ] && cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

SIGN_ID="${KADR_SIGN_ID:--}"
codesign --force --sign "$SIGN_ID" "$APP"
echo "Built $APP (signed with: $SIGN_ID)"

if [ "${1:-}" = "dmg" ]; then
    rm -rf build/dmg build/Kadr.dmg build/Kadr.zip
    mkdir -p build/dmg
    cp -R "$APP" build/dmg/
    ln -s /Applications build/dmg/Applications
    hdiutil create -volname "Kadr $VERSION" -srcfolder build/dmg -ov -format UDZO build/Kadr.dmg >/dev/null
    ditto -c -k --keepParent "$APP" build/Kadr.zip
    rm -rf build/dmg
    echo "Packed build/Kadr.dmg and build/Kadr.zip (v$VERSION)"
fi

if [ "${1:-}" = "install" ]; then
    pkill -x Kadr 2>/dev/null || true
    # Wait for the old instance to exit, otherwise `open` fails with -600.
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Kadr >/dev/null || break; sleep 0.3; done
    rm -rf /Applications/Kadr.app
    cp -R "$APP" /Applications/
    sleep 0.5
    open /Applications/Kadr.app 2>/dev/null || { sleep 1; open /Applications/Kadr.app; }
    echo "Installed to /Applications/Kadr.app"
fi
