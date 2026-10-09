$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\tools\cloudbook_session.ps1")

$virtual = [pscustomobject]@{ FriendlyName="Virtual Display Driver"; InstanceId='ROOT\DISPLAY\0000' }
$physical = [pscustomobject]@{ FriendlyName="NVIDIA GeForce RTX"; InstanceId='PCI\GPU' }
$script:devices = @($physical,$virtual)
$script:changes = @()
function Get-PnpDevice { param($Class,[switch]$PresentOnly,$ErrorAction) return $script:devices }
function Get-PnpDeviceProperty { param($InstanceId,$KeyName,$ErrorAction) return [pscustomobject]@{ Data=-1 } }
function Enable-PnpDevice { param($InstanceId,$Confirm,$ErrorAction) $script:changes += "on:$InstanceId" }
function Disable-PnpDevice { param($InstanceId,$Confirm,$ErrorAction) $script:changes += "off:$InstanceId" }
function Assert($Condition,$Message) { if(-not $Condition) { throw $Message } }

Assert ((Get-CloudbookAdapter).InstanceId -eq $virtual.InstanceId) "Wrong adapter selected"
Invoke-CloudbookDisplaySession $virtual { $script:changes += "stream" }
Assert (($script:changes -join ",") -eq 'on:ROOT\DISPLAY\0000,stream,off:ROOT\DISPLAY\0000') "Incorrect normal lifecycle"
$script:changes = @()
try { Invoke-CloudbookDisplaySession $virtual { throw "capture failed" } } catch {
  Assert ($_.Exception.Message -eq "capture failed") "Unexpected failure"
}
Assert (($script:changes -join ",") -eq 'on:ROOT\DISPLAY\0000,off:ROOT\DISPLAY\0000') "Failure left display enabled"
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
