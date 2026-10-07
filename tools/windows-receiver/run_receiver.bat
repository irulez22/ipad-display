@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0build_receiver.ps1"
if errorlevel 1 exit /b %errorlevel%
start "" "%LOCALAPPDATA%\PadDisplayReceiver\PadDisplayReceiver.exe"
