[CmdletBinding()]
param(
    [switch]$RemoveFiles,
    [string]$InstallPath = (Join-Path $env:LOCALAPPDATA 'OneDriveSyncMonitor')
)

$ErrorActionPreference = 'Stop'
$taskName = 'OneDrive Sync Monitor'

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Write-Host "Removed scheduled task: $taskName"
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
if (Test-Path -LiteralPath $runKey) {
    Remove-ItemProperty -LiteralPath $runKey -Name 'OneDriveSyncMonitor' -ErrorAction SilentlyContinue
    Remove-ItemProperty -LiteralPath $runKey -Name 'OneDriveCloudBackup' -ErrorAction SilentlyContinue
    Write-Host 'Removed current-user Startup entry (if present).'
}
$cloudStopPath = Join-Path $InstallPath 'cloud-backup.stop'
if (Test-Path -LiteralPath $InstallPath) { Set-Content -LiteralPath $cloudStopPath -Value 'disabled' -Encoding ASCII }

if ($RemoveFiles) {
    if ([string]::IsNullOrWhiteSpace($InstallPath) -or $InstallPath -eq $env:LOCALAPPDATA -or $InstallPath -eq 'C:\') {
        throw 'Refusing to remove an unsafe or broad path.'
    }
    if (Test-Path -LiteralPath $InstallPath) {
        Remove-Item -LiteralPath $InstallPath -Recurse -Force
        Write-Host "Removed monitor files: $InstallPath"
    }
}
else {
    Write-Host "Monitor files were kept at $InstallPath. Use -RemoveFiles only when you are sure the logs are no longer needed."
}
