#!/bin/bash
# Build a self-contained app and a compressed drag-to-Applications disk image.
set -euo pipefail
cd "$(dirname "$0")"
[ "$(uname -m)" = arm64 ] || { echo 'Build releases on Apple Silicon.' >&2; exit 1; }
./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/Dyno.app/Contents/Info.plist)
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/dyno-dmg.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
cp -R build/Dyno.app "$STAGING/Dyno.app"
codesign --verify --deep --strict "$STAGING/Dyno.app"
PYTHONPATH="$STAGING/Dyno.app/Contents/Resources/pylib" \
  "$STAGING/Dyno.app/Contents/Resources/python/bin/python3.12" \
  -c 'import dyno, importlib.util; assert importlib.util.find_spec("mlx") is not None'
ln -s /Applications "$STAGING/Applications"
cp ../LICENSE "$STAGING/LICENSE.txt"
cat > "$STAGING/Read Me.txt" <<'TXT'
Dyno for Apple Silicon — macOS 14 or later

Drag Dyno into Applications, then open it. Python and MLX are included.
Click Dyno in the menu bar to open the app; right-click for a quick summary.
Download a model in Discover, start it in Models, then open Lab.
Inspect activations, explore token probabilities, train probes and small SAEs,
or compare interventions. Saved history lets you reopen results and settings.
Isolated research methods need a separate model copy and idle GPU capacity.

To share inference: Router > Share on local network > Start the router.
Copy the displayed URL into another computer's OpenAI-compatible client.
Sharing has no authentication; enable it only on trusted networks.

This build is ad-hoc signed, not Apple-notarized. macOS may block its first
launch. See Apple's guidance for opening apps from an unidentified developer:
https://support.apple.com/guide/mac-help/mh40616/mac

Source and documentation: https://github.com/canivel/mlx-dyno
TXT
DMG="build/Dyno-${VERSION}-arm64.dmg"
hdiutil create -volname "Dyno ${VERSION}" -srcfolder "$STAGING" -format UDZO -ov "$DMG"
hdiutil verify "$DMG"
(cd build && shasum -a 256 "Dyno-${VERSION}-arm64.dmg" > "Dyno-${VERSION}-arm64.dmg.sha256")
echo "Ready: $DMG"
