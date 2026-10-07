param([string]$OutputDir = "$env:LOCALAPPDATA\PadDisplayReceiver")
$ErrorActionPreference = "Stop"

$src = Join-Path $PSScriptRoot "PadDisplayReceiver.cpp"

if (-not (Test-Path $src)) { throw "Receiver source not found: $src" }

$vsDev = $null
$programFilesX86 = [Environment]::GetEnvironmentVariable("ProgramFiles(x86)")
$vswhere = if ($programFilesX86) {
  Join-Path $programFilesX86 "Microsoft Visual Studio\Installer\vswhere.exe"
} else {
  Join-Path $env:ProgramFiles "Microsoft Visual Studio\Installer\vswhere.exe"
}
if (Test-Path $vswhere) {
  $install = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
  if ($install) {
    $candidate = Join-Path $install "Common7\Tools\VsDevCmd.bat"
    if (Test-Path $candidate) { $vsDev = $candidate }
  }
}
if (-not $vsDev) {
  $candidate = "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\Tools\VsDevCmd.bat"
  if (Test-Path $candidate) { $vsDev = $candidate }
}
if (-not $vsDev) {
  throw "Visual Studio 2022 C++ tools are required. Install Desktop development with C++."
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$out = Join-Path $OutputDir "PadDisplayReceiver.exe"
Get-Process PadDisplayReceiver -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

$cmd = 'call "' + $vsDev + '" -arch=x64 -host_arch=x64 >nul && cl /nologo /std:c++17 /EHsc /O2 /DUNICODE /D_UNICODE "' + $src + '" /Fe:"' + $out + '" user32.lib gdi32.lib ole32.lib ws2_32.lib mfplat.lib mfuuid.lib mf.lib d3d11.lib dxgi.lib wmcodecdspuuid.lib'
& cmd.exe /c $cmd

if ($LASTEXITCODE -ne 0 -or -not (Test-Path $out)) {
  throw "PadDisplay native receiver build failed."
}

Write-Host "Built native hardware-accelerated receiver: $out"
