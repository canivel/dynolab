#!/bin/bash
# Sign nested native code before sealing the enclosing app bundle.
set -euo pipefail
APP=${1:?Usage: sign-app.sh path/to/Dyno.app}
IDENTITY=${DYNO_SIGN_IDENTITY:--}
ENTITLEMENTS="$(cd "$(dirname "$0")" && pwd)/entitlements.plist"
if [ "$IDENTITY" = - ]; then
  codesign --force --deep --sign - --entitlements "$ENTITLEMENTS" "$APP"
else
  case "$IDENTITY" in
    'Developer ID Application: '*) ;;
    *) echo 'DYNO_SIGN_IDENTITY must name a Developer ID Application certificate.' >&2; exit 1 ;;
  esac
  while IFS= read -r -d '' binary; do
    # The main executable is signed with its enclosing bundle, after libraries.
    [ "$binary" = "$APP/Contents/MacOS/Dyno" ] && continue
    if /usr/bin/file -b "$binary" | /usr/bin/grep -q 'Mach-O'; then
      codesign --force --sign "$IDENTITY" --timestamp --options runtime "$binary"
    fi
  done < <(find "$APP/Contents" -type f -print0)
  # Sparkle includes an updater app and XPC services. Seal nested bundles
  # inside-out after signing their executable code, then seal the framework.
  while IFS= read -r -d '' bundle; do
    codesign --force --sign "$IDENTITY" --timestamp --options runtime "$bundle"
  done < <(find "$APP/Contents/Frameworks" -depth -type d \( -name '*.xpc' -o -name '*.app' -o -name '*.framework' \) -print0)
  codesign --force --sign "$IDENTITY" --timestamp --options runtime --entitlements "$ENTITLEMENTS" "$APP"
fi
codesign --verify --deep --strict "$APP"
