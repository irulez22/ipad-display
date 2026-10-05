$ErrorActionPreference = "Stop"
$ipadIp = "192.168.68.51"
$repo = "\\wsl$\Ubuntu\home\josh\ipad-display"
$streamer = "$repo\tools\stream_windows.py"
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
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool EnumDisplaySettings(string d, int n, ref DEVMODE m);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int ChangeDisplaySettingsEx(string d, ref DEVMODE m, IntPtr h, int f, IntPtr p);
}
"@

function Read-Choice($Prompt, $Default, $Min, $Max) {
  while ($true) {
    $v = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($v)) { return [int]$Default }
    $n = 0
    if ([int]::TryParse($v, [ref]$n) -and $n -ge $Min -and $n -le $Max) { return $n }
    Write-Host "Enter $Min-$Max." -ForegroundColor Yellow
  }
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
Write-Host "=== PadDisplay launcher ==="
$vdd = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "OK" -and $_.FriendlyName -eq "Virtual Display Driver" } | Select-Object -First 1
if (-not $vdd) { throw "Signed Virtual Display Driver is not active." }

$screens = @([System.Windows.Forms.Screen]::AllScreens)
for ($i=0; $i -lt $screens.Count; $i++) {
  $s=$screens[$i]; $p=if($s.Primary){" [primary]"}else{""}
  Write-Host ("[{0}] {1} {2}x{3}{4}" -f ($i+1),$s.DeviceName,$s.Bounds.Width,$s.Bounds.Height,$p)
}
$defaultScreen=1
for($i=$screens.Count-1;$i -ge 0;$i--){if(-not $screens[$i].Primary){$defaultScreen=$i+1;break}}
$screen=$screens[(Read-Choice "Virtual display" $defaultScreen 1 $screens.Count)-1]

Write-Host "[1] 1024x768   4M"
Write-Host "[2] 1280x960   6M"
Write-Host "[3] 1600x1200 10M"
Write-Host "[4] 2048x1536 16M (native iPad Air)"
$modes=@(
  @{W=1024;H=768;B="4M"},
  @{W=1280;H=960;B="6M"},
  @{W=1600;H=1200;B="10M"},
  @{W=2048;H=1536;B="16M"}
)
$mode=$modes[(Read-Choice "Resolution" 4 1 4)-1]

Write-Host "[1] 60 fps"
Write-Host "[2] 30 fps"
$fps=if((Read-Choice "Frame rate" 1 1 2)-eq 1){60}else{30}
$custom=Read-Host "Bitrate [$($mode.B)]"
$bitrate=if([string]::IsNullOrWhiteSpace($custom)){$mode.B}else{$custom}

Set-DisplayMode $screen.DeviceName $mode.W $mode.H $fps
Start-Sleep 2
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
& python $streamer $ipadIp --ffmpeg $ffmpeg --capture ddagrab --adapter $foundAdapter --display $foundOutput --fps $fps --bitrate $bitrate --size $size
exit $LASTEXITCODE