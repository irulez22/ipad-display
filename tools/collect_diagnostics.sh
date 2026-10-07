#!/usr/bin/env bash
set -u

cd ~/ipad-display || exit 1

stamp="$(date '+%Y%m%d-%H%M%S')"
out="diagnostics/PadDisplay-$stamp"
mkdir -p "$out"

section() {
  printf '\n===== %s =====\n' "$1"
}

{
  section "Timestamp"
  date -Is
  section "Git"
  git rev-parse HEAD 2>&1 || true
  git status --short --branch 2>&1 || true
  section "Package metadata"
  grep -E '^(Version|Package|Architecture):' control 2>&1 || true
  section "App metadata"
  grep -E 'CFBundleShortVersionString|CFBundleVersion' Resources/Info.plist 2>&1 || true
} > "$out/repo.txt"

status_win="/mnt/c/Users/Josh/AppData/Local/PadDisplay/status.json"
if [ -f "$status_win" ]; then
  cp "$status_win" "$out/windows-status.json"
fi

powershell.exe -NoProfile -Command '
$ErrorActionPreference="SilentlyContinue"
"=== Windows ==="
Get-ComputerInfo | Select-Object WindowsProductName,WindowsVersion,OsBuildNumber | Format-List
"=== GPU ==="
Get-CimInstance Win32_VideoController | Select-Object Name,DriverVersion | Format-Table -AutoSize
"=== PadDisplay / Virtual display devices ==="
Get-PnpDevice | Where-Object { $_.FriendlyName -match "PadDisplay|Virtual Display" } | Select-Object Status,Class,FriendlyName,InstanceId | Format-Table -AutoSize
"=== PadDisplay scheduled task ==="
schtasks.exe /Query /TN "PadDisplay Engine" /V /FO LIST
"=== Relevant processes ==="
Get-Process PadDisplayLauncher,python,ffmpeg,iproxy,wasapi_loopback -ErrorAction SilentlyContinue | Select-Object ProcessName,Id,StartTime,CPU | Format-Table -AutoSize
' > "$out/windows.txt" 2>&1 || true

{
  section "SSH package/app version"
  ssh ipad 'echo "Package:"; dpkg-query -W -f="${Version}\n" com.ipaddisplay.client 2>/dev/null || true; echo "App:"; defaults read /Applications/PadDisplay.app/Info CFBundleShortVersionString 2>/dev/null || true; defaults read /Applications/PadDisplay.app/Info CFBundleVersion 2>/dev/null || true' 2>&1
  section "Updater daemon"
  ssh ipad 'launchctl list | grep com.ipaddisplay.updater || true' 2>&1
  section "System / uptime"
  ssh ipad 'uname -a; uptime' 2>&1
  section "Battery commands"
  ssh ipad 'echo "UIDevice telemetry is captured in windows-status.json when connected."; if command -v ioreg >/dev/null 2>&1; then ioreg -l -w 0 2>/dev/null | grep -i -E "Battery|Capacity|Voltage|ExternalConnected|IsCharging" | head -n 120; else echo "ioreg unavailable"; fi' 2>&1
} > "$out/ipad-summary.txt"

ssh ipad 'tail -n 300 /var/mobile/Library/PadDisplayUpdater/update.log 2>/dev/null || true' > "$out/ipad-updater.log" 2>&1 || true
ssh ipad 'p="$(find /var/mobile -name PadDisplay.log 2>/dev/null | head -n 1)"; if [ -n "$p" ]; then tail -n 500 "$p"; else echo "PadDisplay.log not found"; fi' > "$out/ipad-app.log" 2>&1 || true

{
  section "Python"
  python.exe --version 2>&1 || python --version 2>&1 || true
  section "FFmpeg"
  ffmpeg.exe -version 2>&1 | head -n 12 || true
  section "USB device"
  idevice_id -l 2>&1 || true
} > "$out/tools.txt"

archive=""
if command -v zip >/dev/null 2>&1; then
  archive="diagnostics/PadDisplay-$stamp.zip"
  (cd diagnostics && zip -qr "PadDisplay-$stamp.zip" "PadDisplay-$stamp")
else
  archive="diagnostics/PadDisplay-$stamp.tar.gz"
  tar -czf "$archive" -C diagnostics "PadDisplay-$stamp"
fi

echo "PadDisplay diagnostics collected:"
echo "  $out"
echo "  $archive"
