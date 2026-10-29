#!/bin/bash
# Builds Dyno.app from this checkout and installs it over /Applications/Dyno.app, for
# testing what main holds between releases. The installed app keeps the last released
# version number, so the next real release still arrives through the updater.
# The previous app is kept in $DYNO_BACKUP_DIR (default ~/.mlx-dyno/app-backups).
set -euo pipefail

cd "$(dirname "$0")"
APP=/Applications/Dyno.app
BACKUPS="${DYNO_BACKUP_DIR:-$HOME/.mlx-dyno/app-backups}"

echo "==> Building from $(git rev-parse --abbrev-ref HEAD) @ $(git rev-parse --short HEAD)"
[ -z "$(git status --porcelain)" ] || echo "    note: uncommitted changes are included"
./build.sh

# Quitting stops the lab service; a turn the assistant is in the middle of would be cut off.
if find "$HOME/.mlx-dyno/lab/assistant" -name meta.json -mmin -10 2>/dev/null \
     | xargs grep -lE '"status": "(thinking|working)"' 2>/dev/null | grep -q .; then
  echo "error: the assistant is working on something; install again when it's done" >&2
  exit 1
fi

if [ -d "$APP" ]; then
  mkdir -p "$BACKUPS"
  BACKUP="$BACKUPS/Dyno-$(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo unknown)-$(date +%Y%m%d-%H%M%S).app"
  echo "==> Backing up the installed app to $BACKUP"
  ditto "$APP" "$BACKUP"
  ls -1dt "$BACKUPS"/Dyno-*.app 2>/dev/null | tail -n +4 | while read -r old; do rm -rf "$old"; done  # keep the last three
fi

echo "==> Quitting Dyno"
osascript -e 'tell application id "com.canivel.dyno" to quit' 2>/dev/null || true
for _ in $(seq 1 30); do pgrep -f "$APP/Contents" >/dev/null || break; sleep 1; done
if pgrep -f "$APP/Contents" >/dev/null; then echo "error: Dyno is still running; quit it and try again" >&2; exit 1; fi

echo "==> Installing"
rm -rf "$APP"
ditto build/Dyno.app "$APP"
open "$APP"
echo "Installed $(git rev-parse --short HEAD) to $APP"
