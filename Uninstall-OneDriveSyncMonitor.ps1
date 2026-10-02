[CmdletBinding()]
param(
    [switch]$RemoveFiles,
    [switch]$RemoveProgramFiles,
    [string]$InstallPath = (Join-Path $env:LOCALAPPDATA 'OneDriveSyncMonitor')
)

$ErrorActionPreference = 'Stop'
if ($RemoveFiles -and $RemoveProgramFiles) { throw 'Choose only one file-removal mode.' }
$manager = Join-Path $PSScriptRoot 'Manage-OneDriveSyncMonitorInstances.ps1'
if (-not (Test-Path -LiteralPath $manager -PathType Leaf)) { throw "Missing instance cleanup helper: $manager" }
. $manager
$cleanup = Stop-OneDriveMonitorInstances -InstallPath $InstallPath
Write-Host "Stopped owned processes: $($cleanup.StoppedProcesses)"
Write-Host 'Removed owned scheduled task and Startup entries (if present).'

if ($RemoveFiles) {
    if (-not (Test-SafeMonitorInstallPath -InstallPath $InstallPath)) { throw 'Refusing to remove an unsafe or broad path.' }
    if (Test-Path -LiteralPath $InstallPath) {
        if ((Get-Item -LiteralPath $InstallPath).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'Refusing to recursively remove a reparse-point install folder.'
        }
        Remove-Item -LiteralPath $InstallPath -Recurse -Force
        Write-Host "Removed monitor files: $InstallPath"
    }
}
elseif ($RemoveProgramFiles) {
    $programFiles = @(
        'MultiLibrarySync.ps1', 'Find-CompanyBackupSource.ps1',
        'OneDriveSyncMonitor.ps1', 'OneDriveCloudBackup.ps1', 'OneDriveSyncMonitorTray.exe',
        'Install-OneDriveSyncMonitor.ps1', 'Update-OneDriveSyncMonitor.ps1',
        'Uninstall-OneDriveSyncMonitor.ps1', 'Manage-OneDriveSyncMonitorInstances.ps1',
        'New-CloudBackupCertificate.ps1', 'OneClick-Setup.ps1', 'OneClick-Setup.cmd',
        'OneClick-Uninstall.cmd', 'version.json',
        'Setup-MultiLibrarySync.cmd', 'Setup-MultiLibrarySync.ps1'
    )
    foreach ($name in $programFiles) {
        $path = Join-Path $InstallPath $name
        if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
    }
    # Only this installer's content-addressed SDK directories are app code.
    $resolvedInstall = [IO.Path]::GetFullPath($InstallPath).TrimEnd('\')
    foreach ($runtime in @(Get-ChildItem -LiteralPath $InstallPath -Directory -ErrorAction Stop | Where-Object Name -Match '^GraphRuntime-[a-f0-9]{16}$')) {
        if ([IO.Path]::GetDirectoryName($runtime.FullName) -ine $resolvedInstall -or
            ($runtime.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Refusing to remove an unexpected Graph runtime location.'
        }
        $links = @(Get-ChildItem -LiteralPath $runtime.FullName -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
        if ($links.Count) { throw 'Graph runtime contains reparse points; IT must inspect it before removal.' }
        Remove-Item -LiteralPath $runtime.FullName -Recurse -Force -ErrorAction Stop
    }
    $runtimePointer = Join-Path $InstallPath 'graph-runtime.json'
    if (Test-Path -LiteralPath $runtimePointer -PathType Leaf) { Remove-Item -LiteralPath $runtimePointer -Force }
    Write-Host "Removed known program files from $InstallPath. Config, backup state, and logs were kept."
}
else {
    Write-Host "Monitor files were kept at $InstallPath. Use -RemoveProgramFiles to remove code but keep data."
}
