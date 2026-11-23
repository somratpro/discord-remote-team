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
cp README.md "$scratch/staging/Setup.md"

# Write a double-clickable install helper so recipients can bypass Gatekeeper
# without needing to navigate Privacy & Security settings.
install_cmd="$scratch/staging/Install Remote Team.command"
cat > "$install_cmd" <<'SCRIPT'
#!/bin/bash
app="/Applications/Remote Team.app"
if [ ! -d "$app" ]; then
  osascript -e 'display alert "Remote Team not found" message "Drag Remote Team.app to your Applications folder first, then run this script." as warning'
  exit 1
fi
xattr -dr com.apple.quarantine "$app"
open "$app"
SCRIPT
chmod +x "$install_cmd"

image="$scratch/Remote-Team-macOS-arm64.dmg"
hdiutil create -volname "Remote Team" -srcfolder "$scratch/staging" -format UDZO -fs HFS+ "$image"
hdiutil verify "$image"
mv "$image" "$dest/Remote-Team-macOS-arm64.dmg"
