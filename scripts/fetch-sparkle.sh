#!/bin/zsh
set -eu
cd "${0:A:h}/.."
version=2.10.0
checksum=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
if [[ -f build/Sparkle/.verified-2.10.0 ]]; then exit 0; fi
mkdir -p build
archive="build/Sparkle-${version}.tar.xz"
curl -fL --retry 3 --silent --show-error "https://github.com/sparkle-project/Sparkle/releases/download/${version}/Sparkle-${version}.tar.xz" -o "$archive"
print -r -- "${checksum}  ${archive}" | shasum -a 256 --check
mkdir -p build/Sparkle
tar -xJf "$archive" -C build/Sparkle
touch build/Sparkle/.verified-2.10.0
