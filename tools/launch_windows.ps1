param(
  [switch]$NonInteractive,
  [switch]$UseSavedSettings,
  [int]$DisplayIndex = -1,
  [string]$Resolution = "1280x960",
  [int]$Fps = 60,
  [string]$Bitrate = "",
  [string]$ReceiverHost = ""
)

$ErrorActionPreference = "Stop"

if ($UseSavedSettings) {
  $saved = Get-ItemProperty -Path "HKCU:\Software\PadDisplay" -ErrorAction SilentlyContinue
  if ($saved) {
    if ($null -ne $saved.DisplayIndex) { $DisplayIndex = [int]$saved.DisplayIndex }
    if ($saved.Resolution) { $Resolution = [string]$saved.Resolution }
    if ($saved.Fps) { $Fps = [int]$saved.Fps }
    if ($saved.Bitrate) { $Bitrate = [string]$saved.Bitrate }
    if ($saved.ReceiverHost) { $ReceiverHost = [string]$saved.ReceiverHost }
    $NonInteractive = $true
  }
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  $arg = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"'
  if ($UseSavedSettings) {
    $arg += ' -UseSavedSettings'
  } elseif ($NonInteractive) {
    $arg += ' -NonInteractive -DisplayIndex ' + $DisplayIndex +
            ' -Resolution "' + $Resolution + '"' +
            ' -Fps ' + $Fps +
            ' -Bitrate "' + $Bitrate + '"' +
            ' -ReceiverHost "' + $ReceiverHost + '"'
  }
  Start-Process powershell.exe -Verb RunAs -ArgumentList $arg
  exit 0
}
$ipadIpFallback = "192.168.68.51"
$statusFile = Join-Path $env:LOCALAPPDATA "PadDisplay\status.json"
$stopFile = Join-Path $env:LOCALAPPDATA "PadDisplay\stop.request"
New-Item -ItemType Directory -Force -Path (Split-Path $statusFile) | Out-Null
Start-Transcript -Path (Join-Path (Split-Path $statusFile) "engine.log") -Append | Out-Null
$preferredDisplayName = "\\.\DISPLAY5"
$preferredDisplayWidth = 1365
$preferredDisplayHeight = 1024
$repo = "\\wsl$\Ubuntu\home\josh\ipad-display"
$streamer = "$repo\tools\stream_windows.py"
$wasapiSource = "$repo\tools\wasapi_loopback.cpp"
$audioBuildDir = Join-Path $env:LOCALAPPDATA "PadDisplay"
$wasapiExe = Join-Path $audioBuildDir "wasapi_loopback.exe"
$ffmpeg = "C:\Users\Josh\AppData\Local\Microsoft\WinGet\Packages\Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe\ffmpeg-9.0.2-full_build\bin\ffmpeg.exe"
Set-Location $env:USERPROFILE
Add-Type -AssemblyName System.Windows.Forms

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class PadDisplayMode {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
    public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
    public int dmFields, dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
    public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
    public short dmLogPixels;
    public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
    public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2;
    public int dmPanningWidth, dmPanningHeight;
  }
  public const int CDS_UPDATEREGISTRY = 1;
  public const int CDS_TEST = 2;
  public const int DM_PELSWIDTH = 0x00080000;
  public const int DM_PELSHEIGHT = 0x00100000;
  public const int DM_DISPLAYFREQUENCY = 0x00400000;
  public const int ENUM_CURRENT_SETTINGS = -1;
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool EnumDisplaySettings(string d, int n, ref DEVMODE m);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int ChangeDisplaySettingsEx(string d, ref DEVMODE m, IntPtr h, int f, IntPtr p);
}
"@

function Get-PhysicalDisplayMode($Device) {
  $dm = New-Object PadDisplayMode+DEVMODE
  $dm.dmSize = [Runtime.InteropServices.Marshal]::SizeOf([type][PadDisplayMode+DEVMODE])
  if (-not [PadDisplayMode]::EnumDisplaySettings($Device, [PadDisplayMode]::ENUM_CURRENT_SETTINGS, [ref]$dm)) {
    return $null
  }
  [pscustomobject]@{
    X = [int]$dm.dmPositionX
    Y = [int]$dm.dmPositionY
    W = [int]$dm.dmPelsWidth
    H = [int]$dm.dmPelsHeight
    Hz = [int]$dm.dmDisplayFrequency
  }
}

function Test-TcpPort($HostName, $Port, $TimeoutMs=400) {
  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $iar = $client.BeginConnect($HostName, $Port, $null, $null)
    if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
    $client.EndConnect($iar)
    return $true
  } catch { return $false } finally { $client.Close() }
}

function Resolve-PadDisplayHost {
  try {
    $ptrs = @(Resolve-DnsName -Name "_paddisplay._tcp.local" -Type PTR -ErrorAction Stop)
    foreach ($ptr in $ptrs) {
      if (-not $ptr.NameHost) { continue }
      $srvs = @(Resolve-DnsName -Name $ptr.NameHost -Type SRV -ErrorAction Stop)
      foreach ($srv in $srvs) {
        if (-not $srv.NameTarget) { continue }
        $addresses = @(Resolve-DnsName -Name $srv.NameTarget -Type A -ErrorAction Stop)
        foreach ($address in $addresses) {
          if ($address.IPAddress -and (Test-TcpPort $address.IPAddress 4822 500)) {
            Write-Host ("Discovery: Bonjour found PadDisplay at {0}" -f $address.IPAddress) -ForegroundColor Green
            return [string]$address.IPAddress
          }
        }
      }
    }
  } catch {
    Write-Host "Discovery: Bonjour lookup unavailable; using fallback address." -ForegroundColor DarkGray
  }

  if (Test-TcpPort $ipadIpFallback 4822 500) {
    Write-Host ("Discovery: fallback PadDisplay address {0}" -f $ipadIpFallback) -ForegroundColor DarkGray
  }
  return $ipadIpFallback
}

function Get-UsbDeviceUdid {
  $ideviceId = (Get-Command idevice_id.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
  if (-not $ideviceId) { $ideviceId = (Get-Command idevice_id -ErrorAction SilentlyContinue | Select-Object -First 1).Source }
  if (-not $ideviceId) { return $null }
  try {
    $ids = @(& $ideviceId -l 2>$null | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($ids.Count -gt 0) { return [string]$ids[0] }
  } catch {}
  return $null
}

function Start-UsbProxy {
  $udid = Get-UsbDeviceUdid
  if (-not $udid) { return $null }
  $iproxy = (Get-Command iproxy.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
  if (-not $iproxy) { $iproxy = (Get-Command iproxy -ErrorAction SilentlyContinue | Select-Object -First 1).Source }
  if (-not $iproxy) { return $null }
  Get-Process iproxy -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  $p = Start-Process -FilePath $iproxy -ArgumentList @("-u",$udid,"4823:4822") -WindowStyle Hidden -PassThru
  Start-Sleep -Milliseconds 700
  if ((Get-UsbDeviceUdid) -and (Test-TcpPort "127.0.0.1" 4823 500)) { return $p }
  if ($p -and -not $p.HasExited) { $p | Stop-Process -Force -ErrorAction SilentlyContinue }
  return $null
}
function Ensure-WindowsHelper($Source, $Name, $Libraries) {
  if (-not (Test-Path -LiteralPath $Source)) { throw "Helper source not found: $Source" }
  New-Item -ItemType Directory -Force -Path $audioBuildDir | Out-Null
  $output = Join-Path $audioBuildDir $Name
  if ((Test-Path -LiteralPath $output) -and (Get-Item $output).LastWriteTimeUtc -ge (Get-Item $Source).LastWriteTimeUtc) { return $output }
  $vswhere = Join-Path ([Environment]::GetEnvironmentVariable("ProgramFiles(x86)")) "Microsoft Visual Studio\Installer\vswhere.exe"
  $install = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
  if (-not $install) { throw "Visual Studio C++ build tools are required to compile $Name." }
  $vsDev = Join-Path $install "Common7\Tools\VsDevCmd.bat"
  $localSource = Join-Path $audioBuildDir ([IO.Path]::GetFileName($Source))
  Copy-Item -LiteralPath $Source -Destination $localSource -Force
  $object = [IO.Path]::ChangeExtension($output, ".obj")
  $command = 'call "' + $vsDev + '" -arch=x64 -host_arch=x64 >nul && cl /nologo /EHsc /O2 "' + $localSource + '" /Fo:"' + $object + '" /Fe:"' + $output + '" ' + ($Libraries -join ' ')
  & cmd.exe /c $command | Out-Host
  if ($LASTEXITCODE -ne 0) { throw "Build failed: $Name" }
  return $output
}

function Ensure-WasapiHelper {
  return Ensure-WindowsHelper $wasapiSource "wasapi_loopback.exe" @("ole32.lib")
}

function Register-UsbDeviceEvents {
  Unregister-Event -SourceIdentifier "PadDisplay.DeviceChange" -ErrorAction SilentlyContinue
  Register-WmiEvent -Class Win32_DeviceChangeEvent -SourceIdentifier "PadDisplay.DeviceChange" | Out-Null
}

function Clear-UsbDeviceEvents {
  Unregister-Event -SourceIdentifier "PadDisplay.DeviceChange" -ErrorAction SilentlyContinue
  Remove-Event -SourceIdentifier "PadDisplay.DeviceChange" -ErrorAction SilentlyContinue
}

function Read-Choice($Prompt, $Default, $Min, $Max) {
  while ($true) {
    $v = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($v)) { return [int]$Default }
    $n = 0
    if ([int]::TryParse($v, [ref]$n) -and $n -ge $Min -and $n -le $Max) { return $n }
    Write-Host "Enter $Min-$Max." -ForegroundColor Yellow
  }
}

function Ensure-VddMode($Width, $Height, $Hz, [switch]$DeferRestart) {
  $path = "C:\VirtualDisplayDriver\vdd_settings.xml"
  if (-not (Test-Path $path)) { throw "VDD config not found at $path." }
  [xml]$xml = Get-Content $path
  if (-not $xml.vdd_settings.resolutions) { throw "VDD config has no <resolutions> section." }
  $exists = $false
  foreach ($r in @($xml.vdd_settings.resolutions.resolution)) {
    if ([int]$r.width -eq $Width -and [int]$r.height -eq $Height -and [int]$r.refresh_rate -eq $Hz) { $exists = $true; break }
  }
  if ($exists) { return $false }
  $res = $xml.CreateElement("resolution")
  $w = $xml.CreateElement("width"); $w.InnerText = [string]$Width; [void]$res.AppendChild($w)
  $h = $xml.CreateElement("height"); $h.InnerText = [string]$Height; [void]$res.AppendChild($h)
  $rr = $xml.CreateElement("refresh_rate"); $rr.InnerText = [string]$Hz; [void]$res.AppendChild($rr)
  [void]$xml.vdd_settings.resolutions.AppendChild($res)
  $global = $xml.vdd_settings.global
  if ($global) {
    $haveGlobal = @($global.g_refresh_rate | ForEach-Object { [int]$_."#text" }) -contains $Hz
    if (-not $haveGlobal) { $g = $xml.CreateElement("g_refresh_rate"); $g.InnerText = [string]$Hz; [void]$global.AppendChild($g) }
  }
  Copy-Item $path "$path.launcher.bak" -Force
  $xml.Save($path)
  if ($DeferRestart) { return $true }
  Write-Host ("Added {0}x{1}@{2} to VDD config; restarting signed VDD..." -f $Width,$Height,$Hz)
  Get-PnpDevice | Where-Object { $_.FriendlyName -eq "Virtual Display Driver" } | Disable-PnpDevice -Confirm:$false
  Start-Sleep 2
  Get-PnpDevice | Where-Object { $_.FriendlyName -eq "Virtual Display Driver" } | Enable-PnpDevice -Confirm:$false
  Start-Sleep 4
  return $true
}

function Set-DisplayMode($Device, $Width, $Height, $Hz) {
  $i = 0; $found = $null
  while ($true) {
    $dm = New-Object PadDisplayMode+DEVMODE
    $dm.dmSize = [Runtime.InteropServices.Marshal]::SizeOf([type][PadDisplayMode+DEVMODE])
    if (-not [PadDisplayMode]::EnumDisplaySettings($Device, $i, [ref]$dm)) { break }
    if ($dm.dmPelsWidth -eq $Width -and $dm.dmPelsHeight -eq $Height -and $dm.dmDisplayFrequency -eq $Hz) { $found = $dm; break }
    $i++
  }
  if ($null -eq $found) { throw "$Device does not advertise ${Width}x${Height}@${Hz}." }
  $found.dmFields = [PadDisplayMode]::DM_PELSWIDTH -bor [PadDisplayMode]::DM_PELSHEIGHT -bor [PadDisplayMode]::DM_DISPLAYFREQUENCY
  $test = [PadDisplayMode]::ChangeDisplaySettingsEx($Device,[ref]$found,[IntPtr]::Zero,[PadDisplayMode]::CDS_TEST,[IntPtr]::Zero)
  if ($test -ne 0) { throw "Windows rejected the selected mode (code $test)." }
  $result = [PadDisplayMode]::ChangeDisplaySettingsEx($Device,[ref]$found,[IntPtr]::Zero,[PadDisplayMode]::CDS_UPDATEREGISTRY,[IntPtr]::Zero)
  if ($result -ne 0) { throw "Could not switch display mode (code $result)." }
}

Write-Host ""
function Stop-StreamerTree($Process) {
  if ($Process -and -not $Process.HasExited) {
    & taskkill.exe /PID $Process.Id /T /F 2>$null | Out-Null
  }
}

if (-not [string]::IsNullOrWhiteSpace($ReceiverHost)) {
  if ($Resolution -notmatch '^(\d+)x(\d+)$') { throw "Invalid resolution: $Resolution" }
  $mode = @{ W=[int]$Matches[1]; H=[int]$Matches[2] }
  if ($mode.W -le 0 -or $mode.H -le 0 -or $mode.W % 2 -or $mode.H % 2) { throw "Resolution must have positive even dimensions." }
  if ($Fps -notin @(30,60)) { throw "FPS must be 30 or 60." }
  if ([string]::IsNullOrWhiteSpace($Bitrate)) { $Bitrate = "8M" }
  $fps = $Fps
  $bitrate = $Bitrate
  $pythonExe = (Get-Command python.exe -ErrorAction Stop).Source
  Write-Host "Cloudbook: loading session controller."
  . (Join-Path $PSScriptRoot "cloudbook_session.ps1")
  Write-Host "Cloudbook: checking display mode."
  [void](Ensure-VddMode $mode.W $mode.H $fps)
  Start-CloudbookSessions
  exit
}

Write-Host "=== PadDisplay launcher ==="
$vdd = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "OK" -and $_.FriendlyName -eq "Virtual Display Driver" } | Select-Object -First 1
if (-not $vdd) { throw "Signed Virtual Display Driver is not active." }

$screens = @([System.Windows.Forms.Screen]::AllScreens)
for ($i=0; $i -lt $screens.Count; $i++) {
  $s=$screens[$i]; $p=if($s.Primary){" [primary]"}else{""}
  $physical=Get-PhysicalDisplayMode $s.DeviceName
  $w=if($physical){$physical.W}else{$s.Bounds.Width}
  $h=if($physical){$physical.H}else{$s.Bounds.Height}
  Write-Host ("[{0}] {1} {2}x{3}{4}" -f ($i+1),$s.DeviceName,$w,$h,$p)
}
$defaultScreen=1
$preferredScreenIndex = -1

for ($i=0; $i -lt $screens.Count; $i++) {
  if ($screens[$i].DeviceName -eq $preferredDisplayName) {
    $preferredScreenIndex = $i
    break
  }
}
if ($preferredScreenIndex -lt 0) {
  for ($i=0; $i -lt $screens.Count; $i++) {
    $physical=Get-PhysicalDisplayMode $screens[$i].DeviceName
    $w=if($physical){$physical.W}else{$screens[$i].Bounds.Width}
    $h=if($physical){$physical.H}else{$screens[$i].Bounds.Height}
    if ($w -eq $preferredDisplayWidth -and $h -eq $preferredDisplayHeight) {
      $preferredScreenIndex = $i
      break
    }
  }
}

if ($preferredScreenIndex -ge 0) {
  $defaultScreen = $preferredScreenIndex + 1
  $physical=Get-PhysicalDisplayMode $screens[$preferredScreenIndex].DeviceName
  $w=if($physical){$physical.W}else{$screens[$preferredScreenIndex].Bounds.Width}
  $h=if($physical){$physical.H}else{$screens[$preferredScreenIndex].Bounds.Height}
  Write-Host ("Auto-selected PadDisplay target: {0} {1}x{2}" -f
    $screens[$preferredScreenIndex].DeviceName,$w,$h) -ForegroundColor Green
} else {
  for($i=$screens.Count-1;$i -ge 0;$i--){
    if(-not $screens[$i].Primary){$defaultScreen=$i+1;break}
  }
}

$modes=@(
  @{W=1024;H=768;B="4M"},
  @{W=1280;H=960;B="6M"},
  @{W=1600;H=1200;B="10M"},
  @{W=1366;H=768;B="8M"},
  @{W=1920;H=1080;B="12M"},
  @{W=2048;H=1536;B="16M"}
)

if ($NonInteractive) {
  $savedScreen = if ($UseSavedSettings -and $saved.DisplayDeviceName) {
    $screens | Where-Object { $_.DeviceName -eq $saved.DisplayDeviceName } | Select-Object -First 1
  }
  if ($savedScreen) {
    $screen = $savedScreen
  } elseif ($DisplayIndex -ge 0 -and $DisplayIndex -lt $screens.Count) {
    $screen = $screens[$DisplayIndex]
  } elseif ($preferredScreenIndex -ge 0) {
    $screen = $screens[$preferredScreenIndex]
  } else {
    $screen = $screens[$defaultScreen-1]
  }

  $mode = $null
  foreach ($candidate in $modes) {
    if (("$($candidate.W)x$($candidate.H)") -eq $Resolution) {
      $mode = $candidate
      break
    }
  }
  if ($null -eq $mode) { throw "Unsupported resolution '$Resolution'." }
  $fps = $Fps
  if ($fps -ne 30 -and $fps -ne 60) { throw "Unsupported FPS '$fps'." }
  $bitrate = if ([string]::IsNullOrWhiteSpace($Bitrate)) { $mode.B } else { $Bitrate }
  Write-Host ("Using saved settings: display {0}, {1}x{2}@{3}, {4}" -f $screen.DeviceName,$mode.W,$mode.H,$fps,$bitrate)
} else {
  $screen=$screens[(Read-Choice "Virtual display" $defaultScreen 1 $screens.Count)-1]

  Write-Host "[1] 1024x768   4M"
  Write-Host "[2] 1280x960   6M"
  Write-Host "[3] 1600x1200 10M"
  Write-Host "[4] 1366x768   8M (Windows receiver native)"
  Write-Host "[5] 1920x1080 12M"
  Write-Host "[6] 2048x1536 16M (native iPad Air)"
  $mode=$modes[(Read-Choice "Resolution" $(if ([string]::IsNullOrWhiteSpace($ReceiverHost)) { 2 } else { 4 }) 1 6)-1]

  Write-Host "[1] 60 fps"
  Write-Host "[2] 30 fps"
  $fps=if((Read-Choice "Frame rate" 1 1 2)-eq 1){60}else{30}
  $custom=Read-Host "Bitrate [$($mode.B)]"
  $bitrate=if([string]::IsNullOrWhiteSpace($custom)){$mode.B}else{$custom}
}

$restarted = Ensure-VddMode $mode.W $mode.H $fps
if ($restarted) {
  $screens = @([System.Windows.Forms.Screen]::AllScreens)
  $same = $screens | Where-Object { $_.DeviceName -eq $preferredDisplayName } | Select-Object -First 1
  if (-not $same) {
    $same = $screens | Where-Object {
      $_.Bounds.Width -eq $preferredDisplayWidth -and $_.Bounds.Height -eq $preferredDisplayHeight
    } | Select-Object -First 1
  }
  if (-not $same) {
    $same = $screens | Where-Object { $_.DeviceName -eq $screen.DeviceName } | Select-Object -First 1
  }
  if ($same) { $screen = $same } else { $screen = $screens | Where-Object { -not $_.Primary } | Select-Object -Last 1 }
}
Set-DisplayMode $screen.DeviceName $mode.W $mode.H $fps
Start-Sleep 2
$physicalMode=Get-PhysicalDisplayMode $screen.DeviceName
if($physicalMode){
  Write-Host ("Physical display mode: {0}x{1}@{2}, origin {3},{4}" -f $physicalMode.W,$physicalMode.H,$physicalMode.Hz,$physicalMode.X,$physicalMode.Y) -ForegroundColor DarkGray
}
$size="$($mode.W)x$($mode.H)"
Write-Host "Finding DXGI output for $size..."
$foundAdapter=$null; $foundOutput=$null
for($a=0;$a -lt 8 -and $null -eq $foundAdapter;$a++){
  for($o=0;$o -lt 10;$o++){
    $err=[IO.Path]::GetTempFileName(); $stdout="$err.out"
    try {
      $filter="ddagrab=output_idx=$o`:framerate=5"
      $probe=@("-hide_banner","-loglevel","info","-init_hw_device","d3d11va=grab:$a","-filter_hw_device","grab","-filter_complex",$filter,"-frames:v","1","-f","null","NUL")
      $p=Start-Process -FilePath $ffmpeg -ArgumentList $probe -NoNewWindow -Wait -PassThru -RedirectStandardError $err -RedirectStandardOutput $stdout
      $log=Get-Content $err -Raw -ErrorAction SilentlyContinue
      if($p.ExitCode -eq 0 -and $log -match [regex]::Escape($size)){$foundAdapter=$a;$foundOutput=$o;break}
    } finally { Remove-Item $err,$stdout -Force -ErrorAction SilentlyContinue }
  }
}
if($null -eq $foundAdapter){throw "Could not find $size through DXGI ddagrab."}

Write-Host "Streaming $size @ $fps, $bitrate, DXGI adapter $foundAdapter output $foundOutput"
Write-Host "Touch: native Windows multi-touch"
if (-not $NonInteractive) {
  Write-Host "Controls: press R to change settings, Q to quit." -ForegroundColor DarkGray
}
$pythonExe = (Get-Command python.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $pythonExe) { $pythonExe = (Get-Command python -ErrorAction Stop | Select-Object -First 1).Source }
$usbProxy = $null
$forceWifiNext = $false
Register-UsbDeviceEvents


while (-not (Test-Path -LiteralPath $stopFile)) {
  $usingUsb = $false
  $usingWindowsReceiver = -not [string]::IsNullOrWhiteSpace($ReceiverHost)

  if (-not $usingWindowsReceiver -and -not $forceWifiNext) {
    if (-not $usbProxy -or $usbProxy.HasExited -or -not (Test-TcpPort "127.0.0.1" 4823 250)) {
      $usbProxy = Start-UsbProxy
    }
    if ($usbProxy -and -not $usbProxy.HasExited -and (Get-UsbDeviceUdid) -and (Test-TcpPort "127.0.0.1" 4823 250)) {
      $usingUsb = $true
      $targetHost = "127.0.0.1"
      $targetPort = 4823
      Write-Host "Transport: USB (preferred)" -ForegroundColor Green
    }
  }

  if ($usingWindowsReceiver) {
    $forceWifiNext = $false
    $targetHost = $ReceiverHost
    $targetPort = 4822
    Write-Host "Transport: Windows receiver ($targetHost)" -ForegroundColor Green
    $audioHelper = Ensure-WasapiHelper
    Write-Host "Audio: laptop session mirror enabled" -ForegroundColor Cyan
  } elseif (-not $usingUsb) {
    $forceWifiNext = $false
    $targetHost = Resolve-PadDisplayHost
    $targetPort = 4822
    Write-Host "Transport: Wi-Fi ($targetHost)" -ForegroundColor Cyan
    $audioHelper = Ensure-WasapiHelper
    Write-Host "Audio: Wi-Fi mirror enabled" -ForegroundColor Cyan
  }

  $streamArgs = @(
    "`"$streamer`"", $targetHost,
    "--port", [string]$targetPort,
    "--ffmpeg", "`"$ffmpeg`"",
    "--capture", "ddagrab",
    "--adapter", [string]$foundAdapter,
    "--display", [string]$foundOutput,
    "--fps", [string]$fps,
    "--bitrate", $bitrate,
    "--size", $size,
    "--touch-left", [string]$(if($physicalMode){$physicalMode.X}else{$screen.Bounds.X}),
    "--touch-top", [string]$(if($physicalMode){$physicalMode.Y}else{$screen.Bounds.Y}),
    "--touch-width", [string]$mode.W,
    "--touch-height", [string]$mode.H,
    "--status-file", ("`"" + $statusFile + "`""),
    "--transport", $(if ($usingWindowsReceiver) { "Windows" } elseif ($usingUsb) { "USB" } else { "Wi-Fi" })
  )
  if (-not $usingUsb) {
    $streamArgs += @("--audio-loopback", "`"$audioHelper`"")
  }
  $streamProc = Start-Process -FilePath $pythonExe -ArgumentList $streamArgs -NoNewWindow -PassThru
  $switchToUsb = $false

  while (-not $streamProc.HasExited) {
    if (Test-Path -LiteralPath $stopFile) { Stop-StreamerTree $streamProc; break }
    if (-not $NonInteractive -and [Console]::KeyAvailable) {
      $key = [Console]::ReadKey($true).Key
      if ($key -eq [ConsoleKey]::R) {
        Write-Host ""
        Write-Host "Reopening PadDisplay settings..." -ForegroundColor Cyan
        Stop-StreamerTree $streamProc
        if ($usbProxy -and -not $usbProxy.HasExited) { $usbProxy | Stop-Process -Force -ErrorAction SilentlyContinue }
        Clear-UsbDeviceEvents
        $arg = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"'
        Start-Process powershell.exe -Verb RunAs -ArgumentList $arg
        exit 0
      }
      if ($key -eq [ConsoleKey]::Q) {
        Write-Host ""
        Write-Host "Stopping PadDisplay..." -ForegroundColor Yellow
        Stop-StreamerTree $streamProc
        if ($usbProxy -and -not $usbProxy.HasExited) { $usbProxy | Stop-Process -Force -ErrorAction SilentlyContinue }
        Clear-UsbDeviceEvents
        exit 0
      }
    }

    $evt = Wait-Event -SourceIdentifier "PadDisplay.DeviceChange" -Timeout 1
    if ($evt) {
      Remove-Event -EventIdentifier $evt.EventIdentifier -ErrorAction SilentlyContinue

      if (-not $usingUsb -and -not $usingWindowsReceiver) {
        if ($usbProxy -and -not $usbProxy.HasExited) {
          $usbProxy | Stop-Process -Force -ErrorAction SilentlyContinue
          $usbProxy = $null
        }

        if (Get-UsbDeviceUdid) { $usbProxy = Start-UsbProxy } else { $usbProxy = $null }
        if ($usbProxy -and -not $usbProxy.HasExited -and (Get-UsbDeviceUdid) -and (Test-TcpPort "127.0.0.1" 4823 250)) {
          Write-Host ""
          Write-Host "USB device event detected; switching from Wi-Fi to preferred USB transport..." -ForegroundColor Green
          $switchToUsb = $true
          Stop-StreamerTree $streamProc
          break
        }
      }
    }
  }

  if ($switchToUsb) {
    $forceWifiNext = $false
    Start-Sleep -Milliseconds 500
    continue
  }

  $streamProc.WaitForExit()
  $code = $streamProc.ExitCode
  if ($code -eq 130) {
    if ($usbProxy -and -not $usbProxy.HasExited) { $usbProxy | Stop-Process -Force -ErrorAction SilentlyContinue }
    Clear-UsbDeviceEvents
    exit 0
  }

  if ($usingWindowsReceiver) {
    Write-Host ""
    Write-Host "Windows receiver stream dropped; reconnecting to $ReceiverHost..." -ForegroundColor Yellow
  } elseif ($usingUsb) {
    Write-Host ""
    Write-Host "USB stream dropped; falling back to Wi-Fi..." -ForegroundColor Yellow
    if ($usbProxy -and -not $usbProxy.HasExited) { $usbProxy | Stop-Process -Force -ErrorAction SilentlyContinue }
    $usbProxy = $null
    $forceWifiNext = $true
  } else {
    Write-Host ""
    Write-Host "Wi-Fi stream dropped; USB will be preferred on reconnect..." -ForegroundColor Yellow
  }

  Start-Sleep 1
}
Clear-UsbDeviceEvents
Remove-Item -LiteralPath $stopFile -Force -ErrorAction SilentlyContinue
