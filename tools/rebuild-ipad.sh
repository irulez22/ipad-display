#!/usr/bin/env bash
set -euo pipefail

cd ~/ipad-display

echo "==> Restoring packaging control file..."
git restore control 2>/dev/null || git checkout -- control

echo "==> Pulling latest changes..."
git pull --ff-only

echo "==> Normalizing control line endings..."
sed -i 's/\r$//' control

export THEOS=/home/josh/theos
if [ ! -f "$THEOS/makefiles/common.mk" ]; then
  echo "ERROR: Theos was not found at $THEOS" >&2
  exit 1
fi

echo "==> Building PadDisplay package..."
make clean package

echo
echo "==> Done. Packages:"
ls -1t packages/*.deb 2>/dev/null | head -n 5 || true
