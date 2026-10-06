@echo off
setlocal EnableExtensions

net session >nul 2>&1
if not "%errorlevel%"=="0" (
    echo Requesting Administrator privileges...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

set "VDDROOT=C:\VirtualDisplayDriver"
set "PKGROOT=%LOCALAPPDATA%\Microsoft\WinGet\Packages\VirtualDrivers.Virtual-Display-Driver_Microsoft.Winget.Source_8wekyb3d8bbwe"
set "DEVCON=%PKGROOT%\Dependencies\devcon.exe"
set "ZIP=%TEMP%\Signed-Driver-v24.12.24-x64.zip"
set "TMP=%TEMP%\PadDisplayVDDx64"

echo.
echo ============================================================
echo PadDisplay signed x64 VDD migration
echo ============================================================
echo.

if not exist "%DEVCON%" (
    echo ERROR: devcon.exe was not found at:
    echo %DEVCON%
    pause
    exit /b 1
)

echo [1/7] Removing any old MttVDD root device...
"%DEVCON%" remove "Root\MttVDD" >nul 2>&1

echo.
echo [2/7] Downloading signed x64 Virtual Display Driver...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/VirtualDrivers/Virtual-Display-Driver/releases/download/24.12.24/Signed-Driver-v24.12.24-x64.zip' -OutFile '%ZIP%'"
if errorlevel 1 goto :fail

echo.
echo [3/7] Extracting driver...
if exist "%TMP%" rmdir /s /q "%TMP%"
mkdir "%TMP%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "Expand-Archive -Path '%ZIP%' -DestinationPath '%TMP%' -Force"
if errorlevel 1 goto :fail

echo.
echo [4/7] Locating signed driver files...
for /r "%TMP%" %%F in (MttVDD.inf) do set "INF=%%F"
if not defined INF (
    echo ERROR: MttVDD.inf not found after extraction.
    goto :fail
)
for %%D in ("%INF%\..") do set "DRIVERDIR=%%~fD"

echo Driver directory:
echo %DRIVERDIR%

echo.
echo [5/7] Preparing configuration...
if not exist "%VDDROOT%" mkdir "%VDDROOT%"
copy /Y "%DRIVERDIR%\*" "%VDDROOT%\" >nul

if exist "%PKGROOT%\Dependencies\vdd_settings.xml" (
    copy /Y "%PKGROOT%\Dependencies\vdd_settings.xml" "%VDDROOT%\vdd_settings.xml" >nul
)

if not exist "%VDDROOT%\vdd_settings.xml" (
    echo ERROR: vdd_settings.xml was not found.
    goto :fail
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "$p='%VDDROOT%\vdd_settings.xml'; $x=Get-Content $p -Raw; $x=[regex]::Replace($x,'<count>\d+</count>','<count>1</count>'); Set-Content $p $x -Encoding UTF8"
if errorlevel 1 goto :fail

echo.
echo [6/7] Installing Root\MttVDD using signed x64 driver...
pushd "%VDDROOT%"
"%DEVCON%" install "%VDDROOT%\MttVDD.inf" "Root\MttVDD"
set "RC=%errorlevel%"
popd
if not "%RC%"=="0" goto :fail

echo.
echo [7/7] Verifying device...
timeout /t 3 /nobreak >nul
powershell.exe -NoProfile -Command ^
  "Get-PnpDevice | Where-Object { $_.InstanceId -match 'MttVDD' -or $_.FriendlyName -match 'Virtual Display Driver' } | Format-Table Status,Class,FriendlyName,InstanceId -Auto"

echo.
echo ============================================================
echo Signed x64 VDD migration complete.
echo ============================================================
echo.
echo Check Settings ^> System ^> Display.
echo You should now see the signed virtual monitor.
echo.
echo If it appears, set it to 1280 x 960 at 60 Hz.
echo Then run disable-test-mode.bat and reboot.
echo.
pause
exit /b 0

:fail
echo.
echo ERROR: signed x64 VDD migration failed.
echo.
pause
exit /b 1
