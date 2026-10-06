@echo off
setlocal
echo === PadDisplay iPad rebuild ===
wsl -d Ubuntu -- bash -lc "cd ~/ipad-display && ./tools/rebuild-ipad.sh"
set ERR=%ERRORLEVEL%
echo.
if not "%ERR%"=="0" (
  echo Build failed with error %ERR%.
  pause
  exit /b %ERR%
)
echo Build complete.
pause
