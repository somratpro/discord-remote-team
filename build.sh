#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
dest="${1:-$PWD/build}"
mkdir -p "$dest"
dest="$(cd "$dest" && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
bundle="$scratch/Remote Team.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources" "$scratch/App.iconset"
for arch in arm64 x86_64; do
    xcrun swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" Discord.swift State.swift Views.swift MCP.swift main.swift -o "$scratch/$arch"
done
xcrun lipo -create "$scratch/arm64" "$scratch/x86_64" -output "$bundle/Contents/MacOS/TeamCheckin"
cp Info.plist "$bundle/Contents/Info.plist"
xcrun swift Icon.swift "$scratch/App.iconset"
iconutil -c icns "$scratch/App.iconset" -o "$bundle/Contents/Resources/TeamCheckin.icns"
codesign --force --sign - "$bundle"
codesign --verify --strict --verbose=2 "$bundle"
ditto --norsrc --noextattr "$bundle" "$dest/Remote Team.app"
