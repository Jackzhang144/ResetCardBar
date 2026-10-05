#!/bin/zsh
set -eu
cd "${0:A:h}/.."
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' resources/Info.plist)
if [[ "${GITHUB_REF_NAME:-v${version}}" != "v${version}" ]]; then
    print -u2 'Release tag must match resources/Info.plist'; exit 1
fi
./scripts/package.sh
./scripts/create-dmg.sh
mkdir -p build/feed
cp "dist/ResetCardBar-${version}-universal.zip" build/feed/
cp release-notes.md "build/feed/ResetCardBar-${version}-universal.md"
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    print -r -- "$SPARKLE_PRIVATE_KEY" | build/Sparkle/bin/generate_appcast --ed-key-file - --download-url-prefix "https://github.com/Jackzhang144/ResetCardBar/releases/download/v${version}/" --embed-release-notes --maximum-deltas 0 build/feed
else
    build/Sparkle/bin/generate_appcast --account ResetCardBar --download-url-prefix "https://github.com/Jackzhang144/ResetCardBar/releases/download/v${version}/" --embed-release-notes --maximum-deltas 0 build/feed
fi
cp build/feed/appcast.xml dist/appcast.xml
# Verify feed/package signature and published version before uploading.
python3 scripts/verify-release.py
(cd dist && shasum -a 256 "ResetCardBar-${version}-universal.zip" "ResetCardBar-${version}-universal.dmg" appcast.xml > SHA256SUMS)
