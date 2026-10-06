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

deb="$(find packages -maxdepth 1 -type f -name '*.deb' -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1 {$1=""; sub(/^ /,""); print; exit}')"
if [ -z "$deb" ] || [ ! -f "$deb" ]; then
  echo "ERROR: No built .deb found." >&2
  exit 1
fi

version="$(dpkg-deb -f "$deb" Version)"
echo
echo "==> Built PadDisplay $version"
echo "    $deb"

if [ "${PADDISPLAY_NO_PUSH:-0}" != "1" ]; then
  echo
  echo "==> Syncing successful build to GitHub..."
  git add -A

  if ! git diff --cached --quiet; then
    git commit -m "Auto-sync successful PadDisplay build $(date '+%Y-%m-%d %H:%M:%S')"
  else
    echo "No new repository changes to commit."
  fi

  branch="$(git rev-parse --abbrev-ref HEAD)"
  git push origin "$branch"
  echo "==> GitHub push complete: origin/$branch"
else
  echo
  echo "==> GitHub auto-push disabled by PADDISPLAY_NO_PUSH=1"
fi

if [ "${PADDISPLAY_NO_RELEASE:-0}" != "1" ]; then
  echo
  echo "==> Publishing GitHub release v$version..."
  if ! command -v gh >/dev/null 2>&1; then
    echo "ERROR: GitHub CLI (gh) is required for automatic release publishing." >&2
    echo "       Install/authenticate gh, or use PADDISPLAY_NO_RELEASE=1." >&2
    exit 1
  fi
  ./tools/prepare_release.sh "$deb" --publish
else
  echo
  echo "==> GitHub release publishing disabled by PADDISPLAY_NO_RELEASE=1"
fi

if [ "${PADDISPLAY_NO_DESKTOP:-0}" != "1" ]; then
  echo
  echo "==> Rebuilding Windows launcher..."
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "\\wsl$\Ubuntu\home\josh\ipad-display\tools\build_windows_launcher.ps1"

  echo "==> Restarting PadDisplay desktop launcher..."
  cmd.exe /c "taskkill /IM PadDisplayLauncher.exe /F >nul 2>&1" || true
  cmd.exe /c "start \"\" \"%LOCALAPPDATA%\PadDisplay\PadDisplayLauncher.exe\""
else
  echo
  echo "==> Desktop launcher rebuild disabled by PADDISPLAY_NO_DESKTOP=1"
fi

if [ "${PADDISPLAY_NO_DEVICE_TRIGGER:-0}" != "1" ]; then
  echo
  echo "==> Triggering immediate iPad update..."
  ssh ipad 'mkdir -p /var/mobile/Library/PadDisplayUpdater && touch /var/mobile/Library/PadDisplayUpdater/check-now'
  echo "==> iPad updater triggered. It will install v$version if the release is newer."
else
  echo
  echo "==> Immediate iPad update trigger disabled by PADDISPLAY_NO_DEVICE_TRIGGER=1"
fi

echo
echo "==> All update steps complete."
