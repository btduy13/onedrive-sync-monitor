[CmdletBinding()]
param([string]$OutputDirectory = '')

$ErrorActionPreference = 'Stop'
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $PSScriptRoot 'dist' }
$version = [string](Get-Content -LiteralPath (Join-Path $PSScriptRoot 'version.json') -Raw | ConvertFrom-Json).version
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid version.json version.' }
$files = @(
    'Setup-OneDriveSyncMonitor.cmd',
    'OneClick-Setup.cmd',
    'OneClick-Setup.ps1',
    'Setup-MultiLibrarySync.cmd', 'Setup-MultiLibrarySync.ps1',
    'OneClick-Uninstall.cmd',
    'Install-OneDriveSyncMonitor.ps1',
    'Uninstall-OneDriveSyncMonitor.ps1',
    'Manage-OneDriveSyncMonitorInstances.ps1',
    'OneDriveSyncMonitor.ps1',
    'OneDriveCloudBackup.ps1',
    'MultiLibrarySync.ps1', 'Find-CompanyBackupSource.ps1', 'Test-MultiLibrarySync.ps1',
    'New-CloudBackupCertificate.ps1',
    'OneDriveSyncMonitorTray.exe',
    'Update-OneDriveSyncMonitor.ps1',
    'Test-OneDriveSyncMonitor.ps1',
    'Test-OneDriveCloudBackup.ps1',
    'Test-CloudBackupCertificate.ps1',
    'Test-OneDriveInstallLifecycle.ps1',
    'Test-OneDriveCloudBackup-Live.ps1',
    'Test-OneDriveCloudWatcher-Live.ps1',
    'README-OneDriveSyncMonitor-vi.md',
    'README-MultiLibrary.md',
    'version.json'
)
$paths = foreach ($name in $files) {
    $path = Join-Path $PSScriptRoot $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing ZIP payload file: $name" }
    $path
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$zipPath = Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) "OneDriveSyncMonitor-Setup-v$version.zip"
if (Test-Path -LiteralPath $zipPath) { throw "Refusing to overwrite existing package: $zipPath" }
Compress-Archive -LiteralPath $paths -DestinationPath $zipPath -CompressionLevel Optimal -ErrorAction Stop
$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath ($zipPath + '.sha256') -Value ("$hash  $(Split-Path -Leaf $zipPath)") -Encoding ASCII
Write-Host "Created: $zipPath"
Write-Host "SHA-256: $hash"
Write-Host "Files: $($files.Count)"
