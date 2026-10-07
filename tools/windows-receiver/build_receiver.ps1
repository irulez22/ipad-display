param([string]$OutputDir = "$env:LOCALAPPDATA\PadDisplayReceiver")
$ErrorActionPreference = "Stop"

$src = Join-Path $PSScriptRoot "PadDisplayReceiver.cpp"
$vsDev = "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\Tools\VsDevCmd.bat"

if (-not (Test-Path $src)) { throw "Receiver source not found: $src" }
if (-not (Test-Path $vsDev)) {
  throw "Visual Studio 2022 Community C++ tools are required. Install Desktop development with C++."
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$out = Join-Path $OutputDir "PadDisplayReceiver.exe"
Get-Process PadDisplayReceiver -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

$cmd = 'call "' + $vsDev + '" -arch=x64 -host_arch=x64 >nul && cl /nologo /std:c++17 /EHsc /O2 /DUNICODE /D_UNICODE "' + $src + '" /Fe:"' + $out + '" user32.lib gdi32.lib ws2_32.lib mfplat.lib mfuuid.lib mf.lib d3d11.lib dxgi.lib wmcodecdspuuid.lib'
& cmd.exe /c $cmd

if ($LASTEXITCODE -ne 0 -or -not (Test-Path $out)) {
  throw "PadDisplay native receiver build failed."
}

Write-Host "Built native hardware-accelerated receiver: $out"
