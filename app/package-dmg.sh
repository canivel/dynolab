#!/bin/bash
# Build a self-contained app and a compressed drag-to-Applications disk image.
set -euo pipefail
cd "$(dirname "$0")"
[ "$(uname -m)" = arm64 ] || { echo 'Build releases on Apple Silicon.' >&2; exit 1; }
if [ -n "${DYNO_NOTARY_PROFILE:-}" ] && [ "${DYNO_SIGN_IDENTITY:--}" = - ]; then
  echo "Notarization requires DYNO_SIGN_IDENTITY." >&2
  exit 1
fi
./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/Dyno.app/Contents/Info.plist)
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/dyno-dmg.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
cp -R build/Dyno.app "$STAGING/Dyno.app"
codesign --verify --deep --strict "$STAGING/Dyno.app"
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$STAGING/Dyno.app/Contents/Resources/pylib" \
  "$STAGING/Dyno.app/Contents/Resources/python/bin/python3.12" \
  -c 'import dyno, mlx.core as mx; x = mx.array([1.0, 2.0]); mx.eval(x + 1); assert (x + 1).tolist() == [2.0, 3.0]'
"$STAGING/Dyno.app/Contents/MacOS/dyno-cli" --help >/dev/null
codesign --verify --deep --strict "$STAGING/Dyno.app"
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

Website: https://dynolab.dev
Documentation: https://dynolab.dev/guide.html
Source: https://github.com/canivel/dynolab
TXT
if [ "${DYNO_SIGN_IDENTITY:--}" = - ]; then
  printf '\nThis build is ad-hoc signed and not Apple-notarized.\n' >> "$STAGING/Read Me.txt"
elif [ -z "${DYNO_NOTARY_PROFILE:-}" ]; then
  printf '\nThis build is Developer ID signed but not Apple-notarized.\n' >> "$STAGING/Read Me.txt"
fi
DMG="build/Dyno-${VERSION}-arm64.dmg"
rm -f "$DMG.sha256"
hdiutil create -volname "Dyno ${VERSION}" -srcfolder "$STAGING" -format UDZO -ov "$DMG"
if [ "${DYNO_SIGN_IDENTITY:--}" != - ]; then
  codesign --force --sign "$DYNO_SIGN_IDENTITY" --timestamp "$DMG"
fi
if [ -n "${DYNO_NOTARY_PROFILE:-}" ]; then
  NOTARY_ARGS=(--keychain-profile "$DYNO_NOTARY_PROFILE")
  if [ -n "${DYNO_NOTARY_KEYCHAIN:-}" ]; then
    NOTARY_ARGS+=(--keychain "$DYNO_NOTARY_KEYCHAIN")
  fi
  xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait \
    --output-format json > "$DMG.notary.json"
  python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r); sys.exit(0 if r.get("status") == "Accepted" else 1)' "$DMG.notary.json"
  # Never staple or generate a release checksum unless Apple accepted it.
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
fi
hdiutil verify "$DMG"
(cd build && shasum -a 256 "Dyno-${VERSION}-arm64.dmg" > "Dyno-${VERSION}-arm64.dmg.sha256")
echo "Ready: $DMG"
