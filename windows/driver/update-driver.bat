@echo off
setlocal EnableExtensions

net session >nul 2>&1
if not "%errorlevel%"=="0" (
    echo.
    echo ERROR: Run this batch file as Administrator.
    echo.
    pause
    exit /b 1
)

set "REPO_LINUX=/home/josh/ipad-display"
set "REPO_WIN=\\wsl$\Ubuntu\home\josh\ipad-display"
set "DRIVER_SRC=%REPO_WIN%\windows\driver"
set "BUILD_ROOT=C:\Users\Josh\ipad-display-driver-build"
set "MSBUILD=C:\Program Files\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe"

echo.
echo ============================================================
echo PadDisplay driver update
echo ============================================================
echo.

echo [1/7] Pulling latest repo changes...
wsl.exe -d Ubuntu -- bash -lc "cd %REPO_LINUX% && git pull"
if errorlevel 1 goto :fail

echo.
echo [2/7] Regenerating PadDisplay driver source...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%DRIVER_SRC%\bootstrap-from-microsoft-sample.ps1"
if errorlevel 1 goto :fail

echo.
echo [3/7] Refreshing Windows-native build tree...
if exist "%BUILD_ROOT%" rmdir /s /q "%BUILD_ROOT%"
mkdir "%BUILD_ROOT%"
xcopy "%DRIVER_SRC%\*" "%BUILD_ROOT%\" /E /I /H /Y >nul
if errorlevel 1 goto :fail

echo.
echo [4/7] Building PadDisplay...
pushd "%BUILD_ROOT%"
"%MSBUILD%" ".\PadDisplay.sln" /t:Rebuild /p:Configuration=Debug /p:Platform=x64
set "BUILD_EXIT=%errorlevel%"
popd

set "PACKAGE=%BUILD_ROOT%\x64\Debug\PadDisplayDriver"
set "CERT=%BUILD_ROOT%\x64\Debug\PadDisplayDriver.cer"
set "APP=%BUILD_ROOT%\x64\Debug\PadDisplayApp.exe"

if not exist "%PACKAGE%\PadDisplayDriver.dll" goto :buildfail
if not exist "%PACKAGE%\PadDisplayDriver.inf" goto :buildfail
if not exist "%PACKAGE%\paddisplaydriver.cat" goto :buildfail
if not exist "%CERT%" goto :buildfail
if not exist "%APP%" goto :buildfail

if not "%BUILD_EXIT%"=="0" (
    echo.
    echo NOTE: MSBuild returned %BUILD_EXIT%, but all fresh driver artifacts exist.
    echo       This is expected on this machine because of the known x86 InfVerif.dll issue.
)

echo.
echo [5/7] Stopping current PadDisplay instance...
taskkill /IM PadDisplayApp.exe /F >nul 2>&1
pnputil /remove-device "SWD\PadDisplay\PadDisplay" >nul 2>&1

echo.
echo [6/7] Trusting and staging the rebuilt driver...
certutil -addstore -f Root "%CERT%" >nul
if errorlevel 1 goto :fail
certutil -addstore -f TrustedPublisher "%CERT%" >nul
if errorlevel 1 goto :fail
pnputil /add-driver "%PACKAGE%\PadDisplayDriver.inf" /install
if errorlevel 1 goto :fail

echo.
echo [7/7] Starting PadDisplay...
start "PadDisplay" "%APP%"

timeout /t 2 /nobreak >nul
echo.
pnputil /enum-devices /instanceid "SWD\PadDisplay\PadDisplay" /deviceids /drivers

echo.
echo ============================================================
echo PadDisplay update complete.
echo Leave the PadDisplayApp window running while using the display.
echo ============================================================
echo.
pause
exit /b 0

:buildfail
echo.
echo ERROR: Build did not produce all required PadDisplay artifacts.
echo.
pause
exit /b 2

:fail
echo.
echo ERROR: PadDisplay update failed.
echo.
pause
exit /b 1
