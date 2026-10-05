#!/bin/zsh
set -eu
cd "${0:A:h}/.."
APP="build/ResetCardBar.app"
codesign --verify --deep --strict "$APP"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
mkdir -p dist
archive="dist/ResetCardBar-${version}-$(uname -m).zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$archive"
print -r -- "$archive"
