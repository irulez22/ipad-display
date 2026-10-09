$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\tools\cloudbook_session.ps1")

$virtual = [pscustomobject]@{ FriendlyName="Virtual Display Driver"; InstanceId='ROOT\DISPLAY\0000' }
$physical = [pscustomobject]@{ FriendlyName="NVIDIA GeForce RTX"; InstanceId='PCI\GPU' }
$script:devices = @($physical,$virtual)
$stopFile=Join-Path ([IO.Path]::GetTempPath()) "paddisplay-test-stop-not-present"
function Test-TcpPort { return $false }
$script:changes = @()
function Get-PnpDevice { param($Class,[switch]$PresentOnly,$ErrorAction) return $script:devices }
function Get-PnpDeviceProperty { param($InstanceId,$KeyName,$ErrorAction) return [pscustomobject]@{ Data="Root\MttVDD" } }
function Enable-PnpDevice { throw "Session must not restart the adapter" }
function Disable-PnpDevice { throw "Session must not restart the adapter" }
$mode=@{W=1366;H=768}
$fps=60
$script:targetTool="Invoke-TestTarget"
function Invoke-TestTarget {
  $script:changes += "$($args[1]):$($args[0])"
  $global:LASTEXITCODE=0
}
function Assert($Condition,$Message) { if(-not $Condition) { throw $Message } }

Assert ((Get-CloudbookAdapter).InstanceId -eq $virtual.InstanceId) "Wrong adapter selected"
Invoke-CloudbookDisplaySession $virtual { $script:changes += "stream" }
Assert (($script:changes -join ",") -eq 'on:Root\MttVDD,stream,off:Root\MttVDD') "Incorrect normal lifecycle"
$script:changes = @()
try { Invoke-CloudbookDisplaySession $virtual { throw "capture failed" } } catch {
  Assert ($_.Exception.Message -eq "capture failed") "Unexpected failure"
}
Assert (($script:changes -join ",") -eq 'on:Root\MttVDD,off:Root\MttVDD') "Failure left display enabled"
$script:changes = @()
$rejected = $false
try { Set-CloudbookDisplay $physical $false } catch { $rejected = $true }
Assert $rejected "Physical adapter was accepted"
Assert ($script:changes.Count -eq 0) "Physical adapter was changed"
$script:devices = @($virtual,$virtual)
$rejected = $false
try { Get-CloudbookAdapter | Out-Null } catch { $rejected = $true }
Assert $rejected "Ambiguous virtual adapters were accepted"
$script:devices = @()
$rejected = $false
try { Get-CloudbookAdapter | Out-Null } catch { $rejected = $true }
Assert $rejected "Missing virtual adapter was accepted"
Write-Host "Cloudbook display lifecycle and physical-adapter safety checks passed."

$nonce = "a" * 32
$reply = ConvertFrom-CloudbookAnnouncement "PADDISPLAY_RECEIVER_V1 $nonce cloudbook 4822 4824" $nonce "192.0.2.20"
Assert ($reply.Address -eq "192.0.2.20" -and $reply.Name -eq "cloudbook") "Discovery packet rejected"
Assert ($null -eq (ConvertFrom-CloudbookAnnouncement "PADDISPLAY_RECEIVER_V1 wrong cloudbook 4822 4824" $nonce "192.0.2.20")) "Unsolicited discovery accepted"
Assert ($null -eq (ConvertFrom-CloudbookAnnouncement "PADDISPLAY_RECEIVER_V1 $nonce cloudbook 22 4824" $nonce "192.0.2.20")) "Invalid service port accepted"
Write-Host "Discovery reply checks passed."

$script:changes=@()
function Test-TcpPort { return $true }
Invoke-CloudbookDisplaySession $virtual { $script:changes += "retry" } "192.0.2.20"
Assert (($script:changes -join ",") -eq 'on:Root\MttVDD,retry') "Transient retry changed desktop topology"
Write-Host "Reachable receiver keeps its display attached during retry."
