#!/bin/zsh
set -eu
cd "${0:A:h}/.."
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/ResetCardBar.app/Contents/Info.plist)
mkdir -p build/dmg dist
/usr/bin/ditto build/ResetCardBar.app build/dmg/ResetCardBar.app
ln -sfn /Applications build/dmg/Applications
hdiutil create -quiet -volname "ResetCardBar ${version}" -srcfolder build/dmg -ov -format UDZO "dist/ResetCardBar-${version}-universal.dmg"
