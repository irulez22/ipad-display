#!/bin/sh
set -eu

REPO="$HOME/ipad-display"
HERE="$REPO/tools/linux-receiver"

if [ ! -d "$HERE" ]; then
  command -v notify-send >/dev/null 2>&1 && notify-send "PadDisplay" "Repository not found at $REPO"
  exit 1
fi

cd "$HERE"

STATE="$HOME/.local/state/paddisplay"
mkdir -p "$STATE"
exec >>"$STATE/desktop-launch.log" 2>&1
echo "$(date '+%F %T') desktop launcher starting"

# Avoid duplicate receiver instances fighting over ports 4822/4824.
pkill -f "$HERE/bin/paddisplay-receiver" >/dev/null 2>&1 || true
for attempt in 1 2 3 4 5; do
  pgrep -f "$HERE/bin/paddisplay-receiver" >/dev/null || break
  sleep 1
done

exec sh "$HERE/run.sh"
