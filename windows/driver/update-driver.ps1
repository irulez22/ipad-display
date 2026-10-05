param(
    [string]$WslDistro = "Ubuntu",
    [string]$RepoLinuxPath = "~/ipad-display",
    [string]$BuildRoot = "$env:USERPROFILE\ipad-display-driver-build"
)

$ErrorActionPreference = "Stop"

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "This updater must be run as Administrator."
    }
}

function Invoke-PnpUtil {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    & pnputil.exe @Args
    return $LASTEXITCODE
}

Assert-Administrator

$msbuild = "C:\Program Files\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe"
if (-not (Test-Path $msbuild)) {
    throw "Community MSBuild not found at: $msbuild"
}

Write-Host ""
Write-Host "=== PadDisplay driver updater ===" -ForegroundColor Cyan
Write-Host ""

Write-Host "[1/8] Pulling latest repository changes..."
& wsl.exe -d $WslDistro -- bash -lc "cd $RepoLinuxPath && git pull"
if ($LASTEXITCODE -ne 0) {
    throw "git pull failed."
}

$repoWindowsPath = (& wsl.exe -d $WslDistro -- wslpath -w $RepoLinuxPath).Trim()
if (-not $repoWindowsPath) {
    throw "Could not resolve Windows path for $RepoLinuxPath."
}
$driverSource = Join-Path $repoWindowsPath "windows\driver"

Write-Host "[2/8] Regenerating PadDisplay source from the Microsoft IDD sample..."
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $driverSource "bootstrap-from-microsoft-sample.ps1")
if ($LASTEXITCODE -ne 0) {
    throw "PadDisplay bootstrap failed."
}

Write-Host "[3/8] Refreshing Windows-native build tree..."
if (Test-Path $BuildRoot) {
    Remove-Item $BuildRoot -Recurse -Force
}
Copy-Item $driverSource $BuildRoot -Recurse -Force

Write-Host "[4/8] Building PadDisplay..."
$debugRoot = Join-Path $BuildRoot "x64\Debug"
if (Test-Path $debugRoot) {
    Remove-Item $debugRoot -Recurse -Force
}
$buildLog = Join-Path $BuildRoot "PadDisplay-build.log"
Push-Location $BuildRoot
try {
    & $msbuild ".\PadDisplay.sln" /t:Rebuild /p:Configuration=Debug /p:Platform=x64 2>&1 | Tee-Object -FilePath $buildLog
    $msbuildExit = $LASTEXITCODE
}
finally {
    Pop-Location
}

$packageDir = Join-Path $debugRoot "PadDisplayDriver"
$driverDll = Join-Path $packageDir "PadDisplayDriver.dll"
$driverInf = Join-Path $packageDir "PadDisplayDriver.inf"
$driverCat = Join-Path $packageDir "paddisplaydriver.cat"
$cert = Join-Path $debugRoot "PadDisplayDriver.cer"
$app = Join-Path $debugRoot "PadDisplayApp.exe"

$required = @($driverDll, $driverInf, $driverCat, $cert, $app)
$missing = @($required | Where-Object { -not (Test-Path $_) })
if ($missing.Count -gt 0) {
    Write-Host ""
    Write-Host "Build did not produce all required artifacts:" -ForegroundColor Red
    $missing | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    throw "PadDisplay build failed. See $buildLog"
}

if ($msbuildExit -ne 0) {
    $logText = Get-Content $buildLog -Raw
    if ($logText -match "InfVerif\.dll" -and $logText -match "Catalog generation complete") {
        Write-Warning "MSBuild reported the known missing x86 InfVerif.dll issue, but the fresh driver package, catalog, certificate, and app were produced successfully. Continuing."
    }
    else {
        throw "MSBuild returned exit code $msbuildExit. See $buildLog"
    }
}

Write-Host "[5/8] Stopping the old PadDisplay helper and removing the software device..."
Get-Process PadDisplayApp -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
& pnputil.exe /remove-device "SWD\PadDisplay\PadDisplay" 2>&1 | Out-Host

Write-Host "[6/8] Removing previously staged PadDisplay driver packages..."
$enumText = (& pnputil.exe /enum-drivers /class Display 2>&1) -join "`n"
$blocks = [regex]::Split($enumText, "(?:\r?\n){2,}")
$oldOems = foreach ($block in $blocks) {
    if ($block -match "(?im)^Original Name:\s+paddisplaydriver\.inf\s*$" -and
        $block -match "(?im)^Published Name:\s+(oem\d+\.inf)\s*$") {
        $Matches[1]
    }
}
$oldOems = @($oldOems | Sort-Object -Unique)
foreach ($oem in $oldOems) {
    Write-Host "  Removing $oem"
    & pnputil.exe /delete-driver $oem /uninstall /force 2>&1 | Out-Host
}

Write-Host "[7/8] Trusting and installing the freshly built driver..."
& certutil.exe -addstore -f Root $cert | Out-Host
if ($LASTEXITCODE -ne 0) { throw "Failed to install test certificate into Root." }
& certutil.exe -addstore -f TrustedPublisher $cert | Out-Host
if ($LASTEXITCODE -ne 0) { throw "Failed to install test certificate into TrustedPublisher." }

& pnputil.exe /add-driver $driverInf /install | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw "Failed to stage/install PadDisplayDriver.inf."
}

Write-Host "[8/8] Starting PadDisplay..."
Start-Process -FilePath $app -WorkingDirectory $debugRoot

Start-Sleep -Seconds 2
Write-Host ""
& pnputil.exe /enum-devices /instanceid "SWD\PadDisplay\PadDisplay" /deviceids /drivers | Out-Host

Write-Host ""
Write-Host "PadDisplay update complete." -ForegroundColor Green
Write-Host "Build log: $buildLog"
Write-Host "Leave PadDisplayApp.exe running while using the virtual display."
