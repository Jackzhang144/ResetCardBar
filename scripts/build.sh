#!/bin/zsh
set -eu
cd "${0:A:h}/.."
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
./scripts/fetch-sparkle.sh
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
arch="${RESETCARDBAR_ARCH:-$(uname -m)}"
architectures=($arch)
if [[ "$arch" == universal ]]; then architectures=(arm64 x86_64); fi
for architecture in $architectures; do
    xcrun swiftc -target "${architecture}-apple-macos13.0" -swift-version 5 -O src/main.swift src/Monitor.swift src/Updates.swift src/Login.swift tests/MonitorTests.swift -o "build/ResetCardBar-${architecture}" -F build/Sparkle -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks -framework AppKit -framework UserNotifications -framework ServiceManagement -framework IOKit -framework Network
done
if [[ "$arch" == universal ]]; then
    lipo -create build/ResetCardBar-arm64 build/ResetCardBar-x86_64 -output "$APP/Contents/MacOS/ResetCardBar"
else
    cp "build/ResetCardBar-${arch}" "$APP/Contents/MacOS/ResetCardBar"
fi
mkdir -p "$APP/Contents/Frameworks"
/usr/bin/ditto build/Sparkle/Sparkle.framework "$APP/Contents/Frameworks/Sparkle.framework"
cp build/Sparkle/LICENSE "$APP/Contents/Resources/Sparkle-LICENSE.txt"

cp resources/Info.plist "$APP/Contents/Info.plist"
if [[ -f "$APP/Contents/Resources/Assets.car" ]]; then
    /usr/libexec/PlistBuddy -c 'Add :CFBundleIconName string AppIcon' "$APP/Contents/Info.plist"
fi
if [[ "${RESETCARDBAR_BUNDLE_CODEX:-0}" == 1 ]]; then
    rm -rf "$APP/Contents/Helpers"
    python3 scripts/bundle-codex.py "$APP"
fi
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
