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
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos13.0 Discord.swift Directory.swift State.swift Views.swift MCP.swift main.swift -o "$bundle/Contents/MacOS/TeamCheckin"
cp Info.plist "$bundle/Contents/Info.plist"
xcrun swift Icon.swift "$scratch/App.iconset"
iconutil -c icns "$scratch/App.iconset" -o "$bundle/Contents/Resources/TeamCheckin.icns"
codesign --force --sign - "$bundle"
codesign --verify --strict --verbose=2 "$bundle"
ditto --norsrc --noextattr "$bundle" "$dest/Remote Team.app"
