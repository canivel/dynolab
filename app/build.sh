#!/bin/bash
# Builds Dyno.app: a self-contained macOS app with the Swift UI, a bundled
# Python runtime and MLX inside it. No prerequisites for the person who runs
# the finished app -- they drag it to Applications and open it.
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME="Dyno"
BUNDLE_ID="com.canivel.dyno"
VERSION="$(sed -n 's/^version = "\([^"]*\)"/\1/p' ../pyproject.toml | head -1)"
[ -n "$VERSION" ] || { echo "error: missing project version" >&2; exit 1; }
PYTHON_VERSION="3.12"
BUILD_DIR="${DYNO_BUILD_DIR:-build}"
APP="$BUILD_DIR/$APP_NAME.app"
RESOURCES="$APP/Contents/Resources"

command -v uv >/dev/null 2>&1 || {
  echo "error: uv is required to build (it supplies the bundled Python runtime)." >&2
  echo "       install it from https://docs.astral.sh/uv/" >&2
  exit 1
}

SLIM=0
[ "${1:-}" = "--slim" ] && SLIM=1   # skip the runtime, for fast UI iteration

echo "==> Compiling the app"
swift build -c release --product Dyno

echo "==> Rendering the icon"
mkdir -p "$BUILD_DIR"
swift Tools/MakeIcon.swift "$BUILD_DIR" >/dev/null
iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$BUILD_DIR/AppIcon.icns"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$RESOURCES"
cp .build/release/Dyno "$APP/Contents/MacOS/Dyno"
cp "$BUILD_DIR/AppIcon.icns" "$RESOURCES/AppIcon.icns"

if [ "$SLIM" -eq 0 ]; then
  echo "==> Bundling the Python runtime (this is the slow part)"
  # uv ships python-build-standalone, which is relocatable: copied into the
  # bundle it keeps working wherever the app ends up.
  PY_BIN="$(uv python find --managed-python "$PYTHON_VERSION" 2>/dev/null || true)"
  [ -n "$PY_BIN" ] || { uv python install "$PYTHON_VERSION"; PY_BIN="$(uv python find --managed-python "$PYTHON_VERSION")"; }
  PY_ROOT="$(python3 -c "import os,sys;print(os.path.dirname(os.path.dirname(os.path.realpath('$PY_BIN'))))")"

  rm -rf "$RESOURCES/python"
  cp -R "$PY_ROOT" "$RESOURCES/python"
  # Nothing here is reachable from a background server.
  rm -rf "$RESOURCES/python/lib/python$PYTHON_VERSION/test" \
         "$RESOURCES/python/lib/python$PYTHON_VERSION/idlelib" \
         "$RESOURCES/python/lib/python$PYTHON_VERSION/tkinter" \
         "$RESOURCES/python/lib/python$PYTHON_VERSION/lib2to3" \
         "$RESOURCES/python/share" "$RESOURCES/python/include" 2>/dev/null || true

  echo "==> Installing mlx-dyno[serve,mcp,pool] into the bundle"
  rm -rf "$RESOURCES/pylib"
  # The shipped runtime must match the reviewed lockfile, not whatever versions
  # happen to be newest when the release is built.
  LOCKED_REQUIREMENTS=$(mktemp "$PWD/$BUILD_DIR/runtime-requirements.XXXXXX")
  trap 'rm -f "$LOCKED_REQUIREMENTS"' EXIT
  ( cd .. && uv export --locked --extra serve --extra mcp --extra pool --no-dev \
      --no-emit-project --output-file "$LOCKED_REQUIREMENTS" >/dev/null )
  uv pip install --quiet --require-hashes \
      --python "$PWD/$RESOURCES/python/bin/python$PYTHON_VERSION" \
      --target "$PWD/$RESOURCES/pylib" -r "$LOCKED_REQUIREMENTS"
  uv pip install --quiet --no-deps \
      --python "$PWD/$RESOURCES/python/bin/python$PYTHON_VERSION" \
      --target "$PWD/$RESOURCES/pylib" ..
  rm -f "$LOCKED_REQUIREMENTS"
  find "$RESOURCES/pylib" -name "__pycache__" -type d -prune -exec rm -rf {} + 2>/dev/null || true
fi

# Release CI supplies a reviewed, pinned research runtime, including its dylibs.
if [ -n "${DYNO_POOL_RUNTIME_DIR:-}" ]; then
  test -x "$DYNO_POOL_RUNTIME_DIR/llama-server"
  "$DYNO_POOL_RUNTIME_DIR/llama-server" --version 2>&1 | grep -q '5bda51b'
  mkdir -p "$RESOURCES/pool-runtime"
  ditto "$DYNO_POOL_RUNTIME_DIR" "$RESOURCES/pool-runtime"
fi

# Shell entry point for MCP clients; resolves paths after the app is relocated.
cat > "$RESOURCES/dyno-cli" <<'CLI'
#!/bin/sh
DYNO_RESOURCES="$(CDPATH= cd -- "$(dirname -- "$0")/../Resources" && pwd)"
export PYTHONPATH="$DYNO_RESOURCES/pylib"
export PYTHONDONTWRITEBYTECODE=1
exec "$DYNO_RESOURCES/python/bin/python3.12" -m dyno "$@"
CLI
chmod +x "$RESOURCES/dyno-cli"
ln -s ../Resources/dyno-cli "$APP/Contents/MacOS/dyno-cli"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>       <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>        <string>Dyno</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key>           <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <!-- Menu bar plus an on-demand window: no permanent Dock icon. -->
    <key>LSUIElement</key>               <true/>
</dict>
</plist>
PLIST

echo "==> Signing"
./sign-app.sh "$APP"

rm -rf "$BUILD_DIR/AppIcon.iconset" "$BUILD_DIR/AppIcon.icns"
echo
echo "Built $APP  ($(du -sh "$APP" | cut -f1))"
echo "  cp -r '$APP' /Applications/     install it"
[ "$SLIM" -eq 1 ] && echo "  (--slim: no Python runtime bundled; the app will look for a dyno CLI)"
exit 0
