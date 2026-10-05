#!/bin/zsh
set -eu
cd "${0:A:h}/.."
APP="build/ResetCardBar.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
ICONSET="build/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" assets/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" assets/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -f "$APP/Contents/Resources/Assets.car"
python3 scripts/build-icon-catalog.py "$APP" "$ICONSET"
xcrun swiftc -target "${RESETCARDBAR_ARCH:-$(uname -m)}-apple-macos13.0" -swift-version 5 -O src/main.swift src/Monitor.swift tests/MonitorTests.swift -o "$APP/Contents/MacOS/ResetCardBar" -framework AppKit -framework UserNotifications -framework ServiceManagement -framework IOKit -framework Network
cp resources/Info.plist "$APP/Contents/Info.plist"
if [[ -f "$APP/Contents/Resources/Assets.car" ]]; then
    /usr/libexec/PlistBuddy -c 'Add :CFBundleIconName string AppIcon' "$APP/Contents/Info.plist"
fi
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
