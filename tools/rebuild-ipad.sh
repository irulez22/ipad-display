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

echo "==> Building PadDisplay final package..."
make clean
FINALPACKAGE=1 make package

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

  echo "==> Rebasing build commit onto latest origin/$branch..."
  git fetch origin "$branch"
  if ! git rebase "origin/$branch"; then
    echo "ERROR: Auto-sync rebase conflicted; aborting rebase and leaving the build commit intact." >&2
    git rebase --abort >/dev/null 2>&1 || true
    echo "       Resolve manually with: git pull --rebase origin $branch" >&2
    exit 1
  fi

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
  win_build="$(wslpath -w "$PWD/tools/build_windows_launcher.ps1")"
  (
    cd /mnt/c/Users/Josh
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$win_build"
  )

  echo "==> Restarting PadDisplay desktop launcher..."
  (
    cd /mnt/c/Users/Josh
    powershell.exe -NoProfile -Command 'Stop-Process -Name PadDisplayLauncher -Force -ErrorAction SilentlyContinue; $exe = Join-Path $env:LOCALAPPDATA "PadDisplay\PadDisplayLauncher.exe"; if (Test-Path $exe) { Start-Process -FilePath $exe } else { throw "PadDisplay launcher not found: $exe" }'
  )
else
  echo
  echo "==> Desktop launcher rebuild disabled by PADDISPLAY_NO_DESKTOP=1"
fi

if [ "${PADDISPLAY_NO_DEVICE_TRIGGER:-0}" != "1" ]; then
  echo
  echo "==> Staging iPad package over SSH..."
  stage_sha="$(mktemp)"
  sha256sum "$deb" > "$stage_sha"
  scp -q "$deb" ipad:/var/mobile/Library/PadDisplayUpdate.deb
  scp -q "$stage_sha" ipad:/var/mobile/Library/PadDisplayUpdate.deb.sha256
  rm -f "$stage_sha"

  echo "==> Triggering immediate iPad update..."
  ssh ipad 'touch /var/mobile/Library/PadDisplayUpdateNow'
  echo "==> Waiting for iPad to report v$version..."

  installed=""
  for i in $(seq 1 30); do
    sleep 2
    installed="$(ssh ipad 'dpkg-query -W -f="\${Version}" com.ipaddisplay.client 2>/dev/null || true' 2>/dev/null || true)"
    if [ "$installed" = "$version" ]; then
      echo "==> iPad update verified: $installed"
      break
    fi
  done

  if [ "$installed" != "$version" ]; then
    echo "ERROR: iPad did not update to $version (still reports: ${installed:-unknown})." >&2
    echo "If the device is older than 0.7.1, install 0.7.1 once as root so the staged-package updater is present." >&2
    echo "==> Last updater log lines:" >&2
    ssh ipad 'tail -n 40 /var/mobile/Library/PadDisplayUpdater/update.log 2>/dev/null || true' >&2 || true
    exit 1
  fi
else
  echo
  echo "==> Immediate iPad update trigger disabled by PADDISPLAY_NO_DEVICE_TRIGGER=1"
fi

echo
echo "==> All update steps complete and verified."
