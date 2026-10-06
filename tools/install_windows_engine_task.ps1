$ErrorActionPreference = "Stop"
$repo = "\\wsl$\Ubuntu\home\josh\ipad-display"
$engine = Join-Path $repo "tools\launch_windows.ps1"
$taskName = "PadDisplay Engine"
$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name

$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $engine + '" -UseSavedSettings')
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)

Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
Write-Host "Installed privileged task '$taskName'."
