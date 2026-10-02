[CmdletBinding()]
param([switch]$PreflightOnly)
$ErrorActionPreference='Stop'
foreach($name in @('Install-OneDriveSyncMonitor.ps1','MultiLibrarySync.ps1','Find-CompanyBackupSource.ps1')) {
    if(-not(Test-Path -LiteralPath (Join-Path $PSScriptRoot $name) -PathType Leaf)){throw "Incomplete multi-library installer: $name"}
}
$mappings=@(& (Join-Path $PSScriptRoot 'MultiLibrarySync.ps1') -DiscoverOnly)
if(-not @($mappings | Where-Object Status -eq 'Discovered').Count){throw 'No safe, verified local library mapping was found.'}
$mappings | Select-Object Name,SourceRoot,LibraryWebUrl,Status | Format-Table -AutoSize
if($PreflightOnly){return}
$installed=Join-Path $env:LOCALAPPDATA 'OneDriveSyncMonitor'
& (Join-Path $PSScriptRoot 'Install-OneDriveSyncMonitor.ps1') -InstallPath $installed -SkipCloudRestart -DisableAutoUpdate
if(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Graph.Authentication.zip') -PathType Leaf){
    if(-not(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Setup-CompanyOneDrive.ps1') -PathType Leaf)){throw 'Dependency initializer is missing.'}
    . (Join-Path $PSScriptRoot 'Setup-CompanyOneDrive.ps1') -LoadFunctionsOnly
    Initialize-CompanyDependency -InstallPath $installed
} else {
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
}
& (Join-Path $installed 'MultiLibrarySync.ps1') -Enable
Write-Host 'Discovery is active. Cloud read/write status is reported per library; sign-in and write probes are separate.'
