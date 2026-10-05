#!/bin/zsh
set -eu
cd "${0:A:h}/.."
APP="build/ResetCardBar.app"
codesign --verify --deep --strict "$APP"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
mkdir -p dist
arch=$(lipo -archs "$APP/Contents/MacOS/ResetCardBar")
if [[ "$arch" == *arm64* && "$arch" == *x86_64* ]]; then arch=universal; fi
archive="dist/ResetCardBar-${version}-${arch}.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$archive"
print -r -- "$archive"
