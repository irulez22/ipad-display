#!/bin/sh
set -eu
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
BIN="$HERE/bin/paddisplay-receiver"
if [ ! -x "$BIN" ] || [ "$HERE/PadDisplayReceiverLinux.cpp" -nt "$BIN" ] || [ "$HERE/build.sh" -nt "$BIN" ]; then
  sh "$HERE/build.sh"
fi
exec "$BIN" "$@"
