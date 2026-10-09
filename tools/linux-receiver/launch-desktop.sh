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
pkill -f paddisplay-receiver >/dev/null 2>&1 || true

export PADDISPLAY_DISABLE_VAAPI=1
exec sh "$HERE/run.sh"
