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
xattr -dr com.apple.quarantine "$app" 2>/dev/null || true
ln -s /Applications "$scratch/staging/Applications"

# Write a plain-text setup guide with the exact Terminal command to bypass
# Gatekeeper. The user drags the app to Applications, then opens Setup.md
# with TextEdit and copies the command into Terminal.
setup="$scratch/staging/Setup.md"
cat > "$setup" <<'GUIDE'
# Remote Team – Setup

1. Drag **Remote Team.app** into the **Applications** shortcut in this window.

2. Open **Terminal** (press ⌘Space, type Terminal, press Enter) and paste:

   ```
   xattr -dr com.apple.quarantine "/Applications/Remote Team.app" && open "/Applications/Remote Team.app"
   ```

   Press Enter. The app will launch.

You only need to do step 2 once. After that, the app opens normally from
Launchpad or the Applications folder.

---

For full setup instructions (Discord bot, AI client, team directory) see
the README or https://github.com/somratpro/discord-remote-team
GUIDE

image="$scratch/Remote-Team-macOS-arm64.dmg"
hdiutil create -volname "Remote Team" -srcfolder "$scratch/staging" -format UDZO -fs HFS+ "$image"
hdiutil verify "$image"
mv "$image" "$dest/Remote-Team-macOS-arm64.dmg"
