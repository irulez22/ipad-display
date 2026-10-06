$ErrorActionPreference = "Stop"
$repo = "\\wsl$\Ubuntu\home\josh\ipad-display"
$outDir = Join-Path $env:LOCALAPPDATA "PadDisplay"
$src = Join-Path $repo "tools\windows-launcher\PadDisplayLauncher.cs"
$exe = Join-Path $outDir "PadDisplayLauncher.exe"
$manifest = Join-Path $outDir "PadDisplayLauncher.manifest"

New-Item -ItemType Directory -Force -Path $outDir | Out-Null

@'
<?xml version="1.0" encoding="utf-8"?>
<assembly manifestVersion="1.0" xmlns="urn:schemas-microsoft-com:asm.v1">
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3">
    <security>
      <requestedPrivileges>
        <requestedExecutionLevel level="requireAdministrator" uiAccess="false" />
      </requestedPrivileges>
    </security>
  </trustInfo>
</assembly>
'@ | Set-Content -Encoding UTF8 $manifest

$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) {
  $csc = "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
}
if (-not (Test-Path $csc)) {
  throw "C# compiler not found."
}

& $csc /nologo /target:winexe /optimize+ /win32manifest:"$manifest" /reference:System.dll /reference:System.Drawing.dll /reference:System.Windows.Forms.dll /out:"$exe" "$src"
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $exe)) {
  throw "PadDisplay launcher build failed."
}
Write-Host "Built $exe"
