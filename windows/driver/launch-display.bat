@echo off
setlocal
cd /d "%USERPROFILE%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0launcher-signed-vdd.ps1"
echo.
if errorlevel 1 (
    echo Launcher exited with error %errorlevel%.
)
pause
