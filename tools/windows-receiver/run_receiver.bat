@echo off
setlocal
set "PREBUILT=%~dp0bin\PadDisplayReceiver.exe"
set "LOCAL=%LOCALAPPDATA%\PadDisplayReceiver\PadDisplayReceiver.exe"

if exist "%PREBUILT%" (
  echo Using prebuilt PadDisplayReceiver.exe
  start "" "%PREBUILT%"
  exit /b 0
)

if exist "%LOCAL%" (
  echo Using locally built PadDisplayReceiver.exe
  start "" "%LOCAL%"
  exit /b 0
)

echo Prebuilt receiver not found. Falling back to local C++ build...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0build_receiver.ps1"
if errorlevel 1 exit /b %errorlevel%
start "" "%LOCAL%"
