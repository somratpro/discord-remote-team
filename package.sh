#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

dest="${1:-$PWD/build}"
mkdir -p "$dest"
dest="$(cd "$dest" && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

./build.sh "$scratch/staging"
app="$scratch/staging/Remote Team.app"
codesign --verify --strict "$app"
[[ "$(xcrun lipo -archs "$app/Contents/MacOS/TeamCheckin")" == arm64 ]]
ln -s /Applications "$scratch/staging/Applications"
cp README.md "$scratch/staging/Setup.md"

image="$scratch/Remote-Team-macOS-arm64.dmg"
hdiutil create -volname "Remote Team" -srcfolder "$scratch/staging" -format UDZO -fs HFS+ "$image"
hdiutil verify "$image"
mv "$image" "$dest/Remote-Team-macOS-arm64.dmg"
