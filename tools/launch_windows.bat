@echo off
setlocal
set "EXE=%LOCALAPPDATA%\PadDisplay\PadDisplayLauncher.exe"
set "BUILD=\\wsl$\Ubuntu\home\josh\ipad-display\tools\build_windows_launcher.ps1"
if not exist "%EXE%" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%BUILD%"
)
if exist "%EXE%" start "" "%EXE%"
exit /b
