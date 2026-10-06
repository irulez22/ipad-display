$ErrorActionPreference = "Stop"

$ipadIp = "192.168.68.51"
$repo = "\\wsl$\Ubuntu\home\josh\ipad-display"
$streamer = "$repo\tools\stream_windows.py"
$ffmpeg = "C:\Users\Josh\AppData\Local\Microsoft\WinGet\Packages\Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe\ffmpeg-9.0.2-full_build\bin\ffmpeg.exe"
$target = "1280x960"

Set-Location "$env:USERPROFILE"

Write-Host ""
Write-Host "============================================================"
Write-Host "PadDisplay launcher - signed VDD / automatic DXGI detection"
Write-Host "============================================================"
Write-Host ""

$vdd = Get-PnpDevice -ErrorAction SilentlyContinue |
    Where-Object { $_.Status -eq "OK" -and ($_.FriendlyName -eq "Virtual Display Driver" -or $_.InstanceId -match '^ROOT\\DISPLAY\\') } |
    Select-Object -First 1

if (-not $vdd) {
    Write-Host "ERROR: Signed Virtual Display Driver is not active." -ForegroundColor Red
    exit 1
}

Add-Type -AssemblyName System.Windows.Forms
$screens = [System.Windows.Forms.Screen]::AllScreens

Write-Host "Windows displays:"
foreach ($s in $screens) {
    Write-Host ("  {0,-12} {1}x{2} at {3},{4}{5}" -f `
        $s.DeviceName, $s.Bounds.Width, $s.Bounds.Height,
        $s.Bounds.X, $s.Bounds.Y,
        $(if ($s.Primary) { " [primary]" } else { "" }))
}

$targetScreen = $screens | Where-Object {
    $_.Bounds.Width -eq 1280 -and $_.Bounds.Height -eq 960
} | Select-Object -First 1

if (-not $targetScreen) {
    Write-Host ""
    Write-Host "ERROR: The signed virtual monitor is active, but no 1280x960 desktop is enabled." -ForegroundColor Yellow
    Write-Host "Set the Virtual Display Driver monitor to 1280 x 960 @ 60 Hz in Settings > System > Display,"
    Write-Host "then run this launcher again."
    Start-Process "ms-settings:display"
    exit 2
}

Write-Host ""
Write-Host "1280x960 desktop found: $($targetScreen.DeviceName)"
Write-Host "Probing DXGI adapters/outputs..."

$foundAdapter = $null
$foundOutput = $null

# ddagrab indexes outputs per D3D11 adapter, so probe rather than assuming DISPLAY2 == output_idx 2.
for ($adapter = 0; $adapter -lt 6 -and $null -eq $foundAdapter; $adapter++) {
    $adapterHadOutput = $false

    for ($output = 0; $output -lt 8; $output++) {
        $probeArgs = @(
            "-hide_banner",
            "-loglevel", "info",
            "-init_hw_device", "d3d11va=grab:$adapter",
            "-filter_hw_device", "grab",
            "-filter_complex", "ddagrab=output_idx=$output`:framerate=5",
            "-frames:v", "1",
            "-f", "null",
            "NUL"
        )

        $tmp = [System.IO.Path]::GetTempFileName()
        try {
            $p = Start-Process -FilePath $ffmpeg -ArgumentList $probeArgs -NoNewWindow -Wait -PassThru `
                -RedirectStandardError $tmp -RedirectStandardOutput "$tmp.out"
            $log = Get-Content $tmp -Raw -ErrorAction SilentlyContinue

            if ($log -match 'Failed to enumerate DXGI output') {
                if (-not $adapterHadOutput -and $output -eq 0) { break }
                continue
            }

            if ($p.ExitCode -eq 0) {
                $adapterHadOutput = $true
                if ($log -match '(?<!\d)1280x960(?!\d)') {
                    $foundAdapter = $adapter
                    $foundOutput = $output
                    break
                }
            }
        }
        finally {
            Remove-Item $tmp, "$tmp.out" -Force -ErrorAction SilentlyContinue
        }
    }
}

if ($null -eq $foundAdapter) {
    Write-Host ""
    Write-Host "ERROR: Could not identify the 1280x960 monitor through DXGI ddagrab." -ForegroundColor Red
    Write-Host "The Windows monitor exists, but FFmpeg cannot currently see it on the tested D3D11 adapters."
    exit 3
}

Write-Host "Found virtual display: D3D11 adapter $foundAdapter, DXGI output $foundOutput"
Write-Host "Connecting to iPad $ipadIp..."
Write-Host ""

& python $streamer $ipadIp `
    --ffmpeg $ffmpeg `
    --capture ddagrab `
    --adapter $foundAdapter `
    --display $foundOutput `
    --fps 60 `
    --bitrate 6M `
    --size 1280x960

exit $LASTEXITCODE
