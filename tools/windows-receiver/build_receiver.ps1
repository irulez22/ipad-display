param([string]$OutputDir = "$env:LOCALAPPDATA\PadDisplayReceiver")
$ErrorActionPreference = "Stop"
$src = "\\wsl$\Ubuntu\home\josh\ipad-display\tools\windows-receiver\PadDisplayReceiver.cs"
$csc = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { throw "C# compiler not found: $csc" }
if (-not (Test-Path $src)) { throw "Receiver source not found: $src" }
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$out = Join-Path $OutputDir "PadDisplayReceiver.exe"
Get-Process PadDisplayReceiver -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
& $csc /nologo /target:winexe /optimize+ /reference:System.dll /reference:System.Drawing.dll /reference:System.Windows.Forms.dll /out:$out $src
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $out)) { throw "PadDisplay Receiver build failed." }
Write-Host "Built $out"
