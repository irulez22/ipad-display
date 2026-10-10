function ConvertFrom-CloudbookAnnouncement($Text, $Nonce, $Address) {
  $parts = $Text.Split(' ')
  if ($parts.Count -ne 5 -or $parts[0] -ne "PADDISPLAY_RECEIVER_V1" -or
      $parts[1] -cne $Nonce -or $parts[2] -notmatch '^[A-Za-z0-9_.-]{1,255}$' -or
      $parts[3] -ne "4822" -or $parts[4] -ne "4824") { return $null }
  return [pscustomobject]@{ Name=$parts[2]; Address=$Address }
}

function Resolve-CloudbookReceiver($ConfiguredHost) {
  $client = New-Object System.Net.Sockets.UdpClient([System.Net.Sockets.AddressFamily]::InterNetwork)
  $client.EnableBroadcast = $true
  $client.Client.ReceiveTimeout = 150
  $nonce = [Guid]::NewGuid().ToString("N")
  $request = [Text.Encoding]::ASCII.GetBytes("PADDISPLAY_DISCOVER_V1 $nonce")
  $destinations = @("255.255.255.255")
  foreach ($interface in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
    if ($interface.OperationalStatus -ne "Up") { continue }
    foreach ($address in $interface.GetIPProperties().UnicastAddresses) {
      if ($address.Address.AddressFamily -ne "InterNetwork" -or -not $address.IPv4Mask) { continue }
      $ip = $address.Address.GetAddressBytes()
      $mask = $address.IPv4Mask.GetAddressBytes()
      $broadcast = (0..3 | ForEach-Object { $ip[$_] -bor (255 -bxor $mask[$_]) }) -join "."
      $destinations += $broadcast
    }
  }
  if ($ConfiguredHost -and $ConfiguredHost -ne "auto") { $destinations += $ConfiguredHost }
  $found = @{}
  try {
    foreach ($destination in ($destinations | Select-Object -Unique)) {
      try { [void]$client.Send($request, $request.Length, $destination, 4821) } catch {}
    }
    $deadline = [DateTime]::UtcNow.AddMilliseconds(900)
    while ([DateTime]::UtcNow -lt $deadline) {
      $peer = New-Object Net.IPEndPoint([Net.IPAddress]::Any,0)
      try { $reply = $client.Receive([ref]$peer) } catch [Net.Sockets.SocketException] { continue }
      if ($reply.Length -gt 512) { continue }
      $receiver = ConvertFrom-CloudbookAnnouncement ([Text.Encoding]::ASCII.GetString($reply)) $nonce $peer.Address.ToString()
      if ($receiver) { $found[$receiver.Address] = $receiver }
    }
  } finally { $client.Close() }
  if ($ConfiguredHost -and $ConfiguredHost -ne "auto") {
    $match = @($found.Values | Where-Object { $_.Name -eq $ConfiguredHost -or $_.Address -eq $ConfiguredHost })
    if ($match.Count -eq 1) { return $match[0].Address }
    return $ConfiguredHost
  }
  if ($found.Count -eq 1) { return @($found.Values)[0].Address }
  if ($found.Count -gt 1) { Write-Host "Multiple Cloudbooks found; enter the receiver hostname in the launcher." }
  return $null
}

function Get-CloudbookAdapter {
  $devices = @(Get-PnpDevice -Class Display -PresentOnly -ErrorAction Stop |
    Where-Object { $_.FriendlyName -eq "Virtual Display Driver" -and $_.InstanceId -like 'ROOT\DISPLAY\*' })
  if ($devices.Count -ne 1) { throw "Expected exactly one signed Virtual Display Driver; found $($devices.Count)." }
  return $devices[0]
}

function Set-CloudbookAdapterEnabled($Adapter, [bool]$Enabled) {
  if ($Adapter.FriendlyName -ne "Virtual Display Driver" -or $Adapter.InstanceId -notlike 'ROOT\DISPLAY\*') {
    throw "Refusing to change a physical display adapter."
  }

  $problem = (Get-PnpDeviceProperty -InstanceId $Adapter.InstanceId -KeyName "DEVPKEY_Device_ProblemCode" -ErrorAction Stop).Data

  if ($Enabled) {
    if ($problem -eq 22) {
      Enable-PnpDevice -InstanceId $Adapter.InstanceId -Confirm:$false -ErrorAction Stop
      Start-Sleep -Milliseconds 750
    } elseif ($problem -ne 0) {
      throw "Virtual display driver is unavailable (problem $problem)."
    }
  } else {
    if ($problem -eq 0) {
      Disable-PnpDevice -InstanceId $Adapter.InstanceId -Confirm:$false -ErrorAction Stop
      Start-Sleep -Milliseconds 500
    } elseif ($problem -ne 22) {
      throw "Virtual display driver could not be disabled cleanly (problem $problem)."
    }
  }
}

function Set-CloudbookDisplay($Adapter, [bool]$Enabled) {
  if ($Adapter.FriendlyName -ne "Virtual Display Driver" -or $Adapter.InstanceId -notlike 'ROOT\DISPLAY\*') {
    throw "Refusing to change a physical display adapter."
  }
  $hardwareId = @((Get-PnpDeviceProperty -InstanceId $Adapter.InstanceId -KeyName "DEVPKEY_Device_HardwareIds" -ErrorAction Stop).Data)[0]
  if (-not $hardwareId) { throw "Virtual display hardware ID unavailable." }
  if ($Enabled) {
    & $script:targetTool $hardwareId on $mode.W $mode.H $fps
  } else {
    & $script:targetTool $hardwareId off
  }
  if ($LASTEXITCODE -ne 0) { throw "Could not change Cloudbook desktop attachment." }
}

function Invoke-CloudbookDisplaySession($Adapter, [scriptblock]$Action, $Address) {
  try {
    Set-CloudbookDisplay $Adapter $true
    & $Action
  } finally {
    if ((Test-Path -LiteralPath $stopFile) -or -not (Test-TcpPort $Address 4822 500)) {
      Set-CloudbookDisplay $Adapter $false
    }
  }
}

function Write-EngineState($State, $Message) {
  $data = @{ state=$State; message=$Message; transport="Linux"; host=$ReceiverHost; updated_unix=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
  $temporary = "$statusFile.engine.tmp"
  $data | ConvertTo-Json -Compress | Set-Content -LiteralPath $temporary -Encoding UTF8
  Move-Item -LiteralPath $temporary -Destination $statusFile -Force
}

function Start-CloudbookSessions {
  Write-Host "Cloudbook: finding virtual display adapter."
  $adapter = Get-CloudbookAdapter
  $script:streamProc = $null
  $hardwareId = @((Get-PnpDeviceProperty -InstanceId $adapter.InstanceId -KeyName "DEVPKEY_Device_HardwareIds" -ErrorAction Stop).Data)[0]
  if (-not $hardwareId) { throw "Virtual display hardware ID unavailable." }
  try {
    Write-Host "Cloudbook: preparing desktop display helper."
    $script:targetTool = Ensure-WindowsHelper (Join-Path $PSScriptRoot "display_target.cpp") "display_target.exe" @("user32.lib","dxgi.lib")
    $problem = (Get-PnpDeviceProperty -InstanceId $adapter.InstanceId -KeyName "DEVPKEY_Device_ProblemCode" -ErrorAction Stop).Data
    if ($problem -ne 0 -and $problem -ne 22) {
      throw "Virtual display driver is unavailable (problem $problem)."
    }
    $audioHelper = Ensure-WasapiHelper
    Set-CloudbookAdapterEnabled $adapter $false
    Write-EngineState "waiting" "Waiting for Cloudbook; virtual display adapter is off."
    while (-not (Test-Path -LiteralPath $stopFile)) {
      $targetAddress = Resolve-CloudbookReceiver $ReceiverHost
      if (-not $targetAddress -or -not (Test-TcpPort $targetAddress 4822 500)) {
        Set-CloudbookAdapterEnabled $adapter $false
        Write-EngineState "waiting" "Waiting for Cloudbook; virtual display adapter is off."
        Start-Sleep -Milliseconds 500
        continue
      }
      try {
        Set-CloudbookAdapterEnabled $adapter $true
        Invoke-CloudbookDisplaySession $adapter {
          Write-EngineState "connecting" "Cloudbook found; enabling its virtual display."
          $deadline = [DateTime]::UtcNow.AddSeconds(15)
          $target = @()
          do {
            if (Test-Path -LiteralPath $stopFile) { return }
            $target = @(& $targetTool $hardwareId)
            if ($LASTEXITCODE -eq 0 -and $target.Count -eq 3 -and [int]$target[1] -ge 0) { break }
            Start-Sleep -Milliseconds 250
          } while ([DateTime]::UtcNow -lt $deadline)
          if ($target.Count -ne 3 -or [int]$target[1] -lt 0) { throw "Virtual desktop did not attach to DXGI." }
          $device = [string]$target[0]
          $physical = Get-PhysicalDisplayMode $device
          if (-not $physical) { throw "Virtual desktop coordinates unavailable." }
          $streamArguments = @(
            ('"{0}"' -f $streamer), $targetAddress, "--port","4822",
            "--ffmpeg",('"{0}"' -f $ffmpeg),"--capture","ddagrab",
            "--adapter",[string]$target[1],"--display",[string]$target[2],
            "--fps",[string]$fps,"--bitrate",$bitrate,"--size","$($mode.W)x$($mode.H)",
            "--touch-left",[string]$physical.X,"--touch-top",[string]$physical.Y,
            "--touch-width",[string]$physical.W,"--touch-height",[string]$physical.H,
            "--status-file",('"{0}"' -f $statusFile),"--transport","Linux",
            "--audio-loopback",('"{0}"' -f $audioHelper)
          )
          $script:streamProc = Start-Process -FilePath $pythonExe -ArgumentList $streamArguments -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $audioBuildDir "stream.log") -RedirectStandardError (Join-Path $audioBuildDir "stream-error.log")
          try {
            while (-not $script:streamProc.HasExited -and -not (Test-Path -LiteralPath $stopFile)) {
              Start-Sleep -Milliseconds 250
            }
          } finally {
            Stop-StreamerTree $script:streamProc
            $script:streamProc.WaitForExit()
            $script:streamProc.Dispose()
            $script:streamProc = $null
          }
        } $targetAddress
        Set-CloudbookAdapterEnabled $adapter $false
        Write-EngineState "waiting" "Reconnecting to Cloudbook; virtual display adapter is off."
      } catch {
        try { Set-CloudbookAdapterEnabled $adapter $false } catch {}
        Write-Host ("Cloudbook connection: " + $_.Exception.Message)
        Write-EngineState "waiting" ("Connection failed; virtual display adapter is off: " + $_.Exception.Message)
      }
      Start-Sleep -Milliseconds 500
    }
  } finally {
    Stop-StreamerTree $script:streamProc
    if ($script:targetTool) {
      try { Set-CloudbookDisplay $adapter $false } catch {}
    }
    try { Set-CloudbookAdapterEnabled $adapter $false } catch {}
    Write-EngineState "stopped" "Stopped; virtual display adapter is off."
    Remove-Item -LiteralPath $stopFile -Force -ErrorAction SilentlyContinue
  }
}
