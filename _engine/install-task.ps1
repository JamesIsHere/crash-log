# install-task.ps1 -- registers the "CrashLog" Task Scheduler task that starts crashlog.ps1
# at every logon, hidden, as the current user (no administrator rights needed).
# Run once: pwsh -File install-task.ps1   Remove: Unregister-ScheduledTask -TaskName CrashLog

$script = Join-Path $PSScriptRoot 'crashlog.ps1'
$pwsh   = (Get-Command pwsh).Source
$user   = "$env:USERDOMAIN\$env:USERNAME"

# conhost --headless gives the script no window, even with Windows Terminal as default terminal.
$action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\conhost.exe" `
    -Argument "--headless `"$pwsh`" -NoProfile -ExecutionPolicy Bypass -File `"$script`""
$trigger   = New-ScheduledTaskTrigger -AtLogOn -User $user
$settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName 'CrashLog' -Action $action -Trigger $trigger -Settings $settings `
    -Principal $principal -Description "Rust crash logger: $(Split-Path $PSScriptRoot -Parent)" -Force
