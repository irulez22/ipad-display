@echo off
setlocal
cd /d "%USERPROFILE%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "\\wsl$\Ubuntu\home\josh\ipad-display\tools\launch_windows.ps1"
echo.
if errorlevel 1 echo Launcher exited with error %errorlevel%.
pause