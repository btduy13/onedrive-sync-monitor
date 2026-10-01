[CmdletBinding()]
param(
    [string]$WebhookUrl = '',
    [int]$IntervalSeconds = 60,
    [int]$StallMinutes = 15,
    [int]$ReminderMinutes = 60,
    [string]$ComputerName = '',
    [string]$Repository = 'btduy13/onedrive-sync-monitor',
    [int]$UpdateCheckHours = 24,
    [switch]$DisableAutoUpdate,
    [switch]$PromptForWebhook,
    [string]$InstallPath = (Join-Path $env:LOCALAPPDATA 'OneDriveSyncMonitor')
)

$ErrorActionPreference = 'Stop'
$taskName = 'OneDrive Sync Monitor'
$sourceScript = Join-Path $PSScriptRoot 'OneDriveSyncMonitor.ps1'
$sourceUpdater = Join-Path $PSScriptRoot 'Update-OneDriveSyncMonitor.ps1'
$sourceCloudBackup = Join-Path $PSScriptRoot 'OneDriveCloudBackup.ps1'
$sourceVersion = Join-Path $PSScriptRoot 'version.json'

if (-not (Test-Path -LiteralPath $sourceScript)) {
    throw "Cannot find $sourceScript"
}
if (-not (Test-Path -LiteralPath $sourceUpdater)) {
    throw "Cannot find $sourceUpdater"
}
if (-not (Test-Path -LiteralPath $sourceCloudBackup)) {
    throw "Cannot find $sourceCloudBackup"
}
if (-not (Test-Path -LiteralPath $sourceVersion)) {
    throw "Cannot find $sourceVersion"
}

New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
$monitorScript = Join-Path $InstallPath 'OneDriveSyncMonitor.ps1'
$updaterScript = Join-Path $InstallPath 'Update-OneDriveSyncMonitor.ps1'
$versionPath = Join-Path $InstallPath 'version.json'
$configPath = Join-Path $InstallPath 'config.json'
Copy-Item -LiteralPath $sourceScript -Destination $monitorScript -Force
Copy-Item -LiteralPath $sourceUpdater -Destination $updaterScript -Force
Copy-Item -LiteralPath $sourceCloudBackup -Destination (Join-Path $InstallPath 'OneDriveCloudBackup.ps1') -Force
Copy-Item -LiteralPath $sourceVersion -Destination $versionPath -Force

$existing = $null
if (Test-Path -LiteralPath $configPath) {
    try { $existing = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json }
    catch { throw "Existing config cannot be read. Preserve it and investigate: $configPath" }
}

$protectedWebhook = if ($existing) { [string]$existing.WebhookUrlProtected } else { '' }
if ($existing -and $null -ne $existing.Repository -and -not [string]::IsNullOrWhiteSpace([string]$existing.Repository)) {
    $Repository = [string]$existing.Repository
}
if ($existing -and $null -ne $existing.UpdateCheckHours) {
    $UpdateCheckHours = [int]$existing.UpdateCheckHours
}
$autoUpdateEnabled = -not $DisableAutoUpdate
if ($existing -and $null -ne $existing.AutoUpdateEnabled) {
    $autoUpdateEnabled = [bool]$existing.AutoUpdateEnabled
}
if ($DisableAutoUpdate) { $autoUpdateEnabled = $false }
if ($PromptForWebhook) {
    $secureInput = Read-Host 'Paste the Power Automate webhook URL (leave blank to keep existing)' -AsSecureString
    if ($secureInput.Length -gt 0) {
        $protectedWebhook = $secureInput | ConvertFrom-SecureString
    }
}
if (-not [string]::IsNullOrWhiteSpace($WebhookUrl)) {
    $secureWebhook = ConvertTo-SecureString -String $WebhookUrl -AsPlainText -Force
    $protectedWebhook = $secureWebhook | ConvertFrom-SecureString
}
if ([string]::IsNullOrWhiteSpace($ComputerName)) {
    $ComputerName = if ($existing -and -not [string]::IsNullOrWhiteSpace([string]$existing.ComputerName)) { [string]$existing.ComputerName } else { $env:COMPUTERNAME }
}

[ordered]@{
    WebhookUrlProtected     = $protectedWebhook
    ComputerName            = $ComputerName
    DiagnosticsStaleMinutes = 30
    StallMinutes            = $StallMinutes
    ReminderMinutes         = $ReminderMinutes
    AutoUpdateEnabled       = $autoUpdateEnabled
    UpdateCheckHours        = [math]::Max(1, $UpdateCheckHours)
    Repository              = $Repository
} | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8

$powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $powershell)) { throw "Windows PowerShell is missing: $powershell" }
$arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}" -IntervalSeconds {2} -StallMinutes {3} -ReminderMinutes {4}' -f $monitorScript, $configPath, $IntervalSeconds, $StallMinutes, $ReminderMinutes
$action = New-ScheduledTaskAction -Execute $powershell -Argument $arguments -WorkingDirectory $InstallPath
$trigger = New-ScheduledTaskTrigger -AtLogOn
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

$startMethod = 'Task Scheduler'
try {
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
    Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
}
catch {
    Write-Warning "Task Scheduler unavailable ($($_.Exception.Message)). Using the current-user Startup registry entry."
    $startMethod = 'Current-user Startup'
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if (-not (Test-Path -LiteralPath $runKey)) { New-Item -Path $runKey -Force | Out-Null }
    $runCommand = '"{0}" {1}' -f $powershell, $arguments
    Set-ItemProperty -LiteralPath $runKey -Name 'OneDriveSyncMonitor' -Value $runCommand -ErrorAction Stop
    $existingProcess = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like "*$monitorScript*" })
    if ($existingProcess.Count -eq 0) {
        Start-Process -FilePath $powershell -ArgumentList $arguments -WindowStyle Hidden -ErrorAction Stop | Out-Null
    }
}

Write-Host "Installed: $taskName"
Write-Host "Startup method: $startMethod"
Write-Host "Install folder: $InstallPath"
Write-Host "Log: $(Join-Path $InstallPath 'monitor.log')"
Write-Host "State: $(Join-Path $InstallPath 'state.json')"
if ([string]::IsNullOrWhiteSpace($protectedWebhook)) {
    Write-Host 'No webhook configured. Alerts will remain local until a Power Automate webhook URL is provided.' -ForegroundColor Yellow
}
else {
    Write-Host "Alert machine name: $ComputerName"
    Write-Host 'Run the test alert before relying on Teams/email delivery:'
    Write-Host "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$monitorScript`" -TestAlert"
}
