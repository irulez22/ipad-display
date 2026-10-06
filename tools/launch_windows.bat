@echo off
setlocal
set "EXE=%LOCALAPPDATA%\PadDisplay\PadDisplayLauncher.exe"
set "SRC=\\wsl$\Ubuntu\home\josh\ipad-display\tools\windows-launcher\PadDisplayLauncher.cs"
set "BUILD=\\wsl$\Ubuntu\home\josh\ipad-display\tools\build_windows_launcher.ps1"
set "NEEDBUILD=0"
if not exist "%EXE%" set "NEEDBUILD=1"
if exist "%EXE%" for %%A in ("%SRC%") do for %%B in ("%EXE%") do if "%%~tA" GTR "%%~tB" set "NEEDBUILD=1"
if "%NEEDBUILD%"=="1" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%BUILD%"
if exist "%EXE%" start "" "%EXE%"
exit /b
