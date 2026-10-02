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
    [switch]$EnableAutoUpdate,
    [switch]$PromptForWebhook,
    [switch]$SkipCloudRestart,
    [switch]$EnableMultiLibrary,
    [string]$InstallPath = (Join-Path $env:LOCALAPPDATA 'OneDriveSyncMonitor')
)

$ErrorActionPreference = 'Stop'

function Test-WebhookAddress {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -match '\s') { return $false }
    $parsed = $null
    return [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$parsed) -and
        $parsed.Scheme -eq [Uri]::UriSchemeHttps -and
        -not [string]::IsNullOrWhiteSpace($parsed.Host) -and
        [string]::IsNullOrWhiteSpace($parsed.UserInfo)
}

function Convert-SecureInputToText {
    param([Security.SecureString]$Value)
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

$taskName = 'OneDrive Sync Monitor'
foreach($required in @('MultiLibrarySync.ps1','Find-CompanyBackupSource.ps1')) {
    if(-not(Test-Path -LiteralPath (Join-Path $PSScriptRoot $required) -PathType Leaf)){throw "Missing payload: $required"}
}
$sourceScript = Join-Path $PSScriptRoot 'OneDriveSyncMonitor.ps1'
$sourceUpdater = Join-Path $PSScriptRoot 'Update-OneDriveSyncMonitor.ps1'
$sourceCloudBackup = Join-Path $PSScriptRoot 'OneDriveCloudBackup.ps1'
$sourceCertHelper = Join-Path $PSScriptRoot 'New-CloudBackupCertificate.ps1'
$sourceInstanceManager = Join-Path $PSScriptRoot 'Manage-OneDriveSyncMonitorInstances.ps1'
$sourceTray = Join-Path $PSScriptRoot 'OneDriveSyncMonitorTray.exe'
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
if (-not (Test-Path -LiteralPath $sourceCertHelper)) {
    throw "Cannot find $sourceCertHelper"
}
if (-not (Test-Path -LiteralPath $sourceInstanceManager)) { throw "Cannot find $sourceInstanceManager" }
if (-not (Test-Path -LiteralPath $sourceTray)) {
    throw "Cannot find $sourceTray. Build the tray application before installing."
}
if (-not (Test-Path -LiteralPath $sourceVersion)) {
    throw "Cannot find $sourceVersion"
}

. $sourceInstanceManager
$previousInstances = Stop-OneDriveMonitorInstances -InstallPath $InstallPath
New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
$monitorScript = Join-Path $InstallPath 'OneDriveSyncMonitor.ps1'
$updaterScript = Join-Path $InstallPath 'Update-OneDriveSyncMonitor.ps1'
$installerScript = Join-Path $InstallPath 'Install-OneDriveSyncMonitor.ps1'
$versionPath = Join-Path $InstallPath 'version.json'
$configPath = Join-Path $InstallPath 'config.json'
Copy-Item -LiteralPath $sourceScript -Destination $monitorScript -Force
Copy-Item -LiteralPath $sourceUpdater -Destination $updaterScript -Force
Copy-Item -LiteralPath $PSCommandPath -Destination $installerScript -Force
Copy-Item -LiteralPath $sourceCloudBackup -Destination (Join-Path $InstallPath 'OneDriveCloudBackup.ps1') -Force
foreach($multiFile in @('MultiLibrarySync.ps1','Find-CompanyBackupSource.ps1')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $multiFile) -Destination (Join-Path $InstallPath $multiFile) -Force
}
if(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Manage-OneDriveSyncMonitorUi.ps1') -PathType Leaf){
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Manage-OneDriveSyncMonitorUi.ps1') -Destination (Join-Path $InstallPath 'Manage-OneDriveSyncMonitorUi.ps1') -Force
}
foreach($setupFile in @('Setup-MultiLibrarySync.ps1','Setup-MultiLibrarySync.cmd')) {
    if(Test-Path -LiteralPath (Join-Path $PSScriptRoot $setupFile) -PathType Leaf){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $setupFile) -Destination (Join-Path $InstallPath $setupFile) -Force}
}
Copy-Item -LiteralPath $sourceCertHelper -Destination (Join-Path $InstallPath 'New-CloudBackupCertificate.ps1') -Force
Copy-Item -LiteralPath $sourceInstanceManager -Destination (Join-Path $InstallPath 'Manage-OneDriveSyncMonitorInstances.ps1') -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Uninstall-OneDriveSyncMonitor.ps1') -Destination (Join-Path $InstallPath 'Uninstall-OneDriveSyncMonitor.ps1') -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'OneClick-Uninstall.cmd') -Destination (Join-Path $InstallPath 'OneClick-Uninstall.cmd') -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'OneClick-Setup.ps1') -Destination (Join-Path $InstallPath 'OneClick-Setup.ps1') -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'OneClick-Setup.cmd') -Destination (Join-Path $InstallPath 'OneClick-Setup.cmd') -Force
Get-Process -Name 'OneDriveSyncMonitorTray' -ErrorAction SilentlyContinue | Where-Object {
    try { $_.Path -ieq (Join-Path $InstallPath 'OneDriveSyncMonitorTray.exe') } catch { $false }
} | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 300
Copy-Item -LiteralPath $sourceTray -Destination (Join-Path $InstallPath 'OneDriveSyncMonitorTray.exe') -Force
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
$notifyItEmailEnabled = $true
if ($existing -and $null -ne $existing.NotifyItEmailEnabled) {
    $notifyItEmailEnabled = [bool]$existing.NotifyItEmailEnabled
}
if ($existing -and $null -ne $existing.AutoUpdateEnabled) {
    $autoUpdateEnabled = [bool]$existing.AutoUpdateEnabled
}
if ($DisableAutoUpdate) { $autoUpdateEnabled = $false }
if ($EnableAutoUpdate) { $autoUpdateEnabled = $true }
if ($PromptForWebhook) {
    while ($true) {
        $secureInput = Read-Host 'Paste the complete HTTPS Power Automate webhook URL on one line (blank keeps existing)' -AsSecureString
        if ($secureInput.Length -eq 0) {
            if (-not $protectedWebhook) { break }
            try {
                $savedSecureInput = ConvertTo-SecureString -String $protectedWebhook -ErrorAction Stop
                $savedPlainInput = Convert-SecureInputToText -Value $savedSecureInput
                if (Test-WebhookAddress -Value $savedPlainInput) { break }
            }
            catch { }
            finally { $savedPlainInput = $null }
            Write-Warning 'The saved webhook URL is invalid. Enter a complete HTTPS URL to replace it.'
            continue
        }
        $plainInput = Convert-SecureInputToText -Value $secureInput
        try {
            if (Test-WebhookAddress -Value $plainInput) {
                $protectedWebhook = $secureInput | ConvertFrom-SecureString
                break
            }
        }
        finally { $plainInput = $null }
        Write-Warning 'Webhook URL is invalid. Copy the entire HTTPS URL from the Power Automate flow, with no quotes or spaces.'
    }
}
if (-not [string]::IsNullOrWhiteSpace($WebhookUrl)) {
    if (-not (Test-WebhookAddress -Value $WebhookUrl)) { throw 'Webhook URL is invalid. Use the complete HTTPS URL from the Power Automate flow.' }
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
    NotifyItEmailEnabled    = $notifyItEmailEnabled
    SafeRecoveryEnabled     = if ($existing -and $null -ne $existing.SafeRecoveryEnabled) { [bool]$existing.SafeRecoveryEnabled } else { $true }
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

$trayPath = Join-Path $InstallPath 'OneDriveSyncMonitorTray.exe'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
if (-not (Test-Path -LiteralPath $runKey)) { New-Item -Path $runKey -Force | Out-Null }
Set-ItemProperty -LiteralPath $runKey -Name 'OneDriveSyncMonitorTray' -Value ('"{0}"' -f $trayPath) -ErrorAction Stop
try {
    $trayProcess = @(Get-Process -Name 'OneDriveSyncMonitorTray' -ErrorAction SilentlyContinue)
    if ($trayProcess.Count -eq 0) { Start-Process -FilePath $trayPath -WindowStyle Hidden -ErrorAction Stop | Out-Null }
}
catch { Write-Warning "Tray icon could not be started now ($($_.Exception.Message)); it will start at next logon." }

if ($EnableMultiLibrary -or (-not $SkipCloudRestart -and $previousInstances.MultiWasEnabled)) { & (Join-Path $InstallPath 'MultiLibrarySync.ps1') -Enable }
elseif (-not $SkipCloudRestart -and $previousInstances.BackupWasEnabled -and (Test-Path -LiteralPath (Join-Path $InstallPath 'cloud-backup.json'))) {
    try { & (Join-Path $InstallPath 'OneDriveCloudBackup.ps1') -Enable }
    catch { Write-Warning "Previous cloud backup could not be restarted and remains OFF: $($_.Exception.Message)" }
}

Write-Host "Installed: $taskName"
Write-Host "Startup method: $startMethod"
Write-Host "Install folder: $InstallPath"
Write-Host "Log: $(Join-Path $InstallPath 'monitor.log')"
Write-Host "State: $(Join-Path $InstallPath 'state.json')"
Write-Host "Tray icon: $trayPath"
if ([string]::IsNullOrWhiteSpace($protectedWebhook)) {
    Write-Host 'No webhook configured. Alerts will remain local until a Power Automate webhook URL is provided.' -ForegroundColor Yellow
}
else {
    Write-Host "Alert machine name: $ComputerName"
    Write-Host 'Run the test alert before relying on Teams/email delivery:'
    Write-Host "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$monitorScript`" -TestAlert"
}
