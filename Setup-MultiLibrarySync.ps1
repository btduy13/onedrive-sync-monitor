[CmdletBinding()]
param([switch]$PreflightOnly,[switch]$LoadFunctionsOnly)
$ErrorActionPreference='Stop'

function Get-MultiLibraryDisableAutoUpdate {
    param([string]$InstallPath)
    $configPath=Join-Path $InstallPath 'config.json'
    if(-not(Test-Path -LiteralPath $configPath -PathType Leaf)){return $true}
    $config=Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if($null -eq $config.AutoUpdateEnabled){return $true}
    return -not [bool]$config.AutoUpdateEnabled
}

if($LoadFunctionsOnly){return}
foreach($name in @('Install-OneDriveSyncMonitor.ps1','MultiLibrarySync.ps1','Find-CompanyBackupSource.ps1')) {
    if(-not(Test-Path -LiteralPath (Join-Path $PSScriptRoot $name) -PathType Leaf)){throw "Incomplete multi-library installer: $name"}
}
$mappings=@(& (Join-Path $PSScriptRoot 'MultiLibrarySync.ps1') -DiscoverOnly)
if(-not @($mappings | Where-Object Status -eq 'Discovered').Count){throw 'No safe, verified local library mapping was found.'}
$mappings | Select-Object Name,SourceRoot,LibraryWebUrl,Status | Format-Table -AutoSize
if($PreflightOnly){return}
$installed=Join-Path $env:LOCALAPPDATA 'OneDriveSyncMonitor'
$disableAutoUpdate=Get-MultiLibraryDisableAutoUpdate -InstallPath $installed
& (Join-Path $PSScriptRoot 'Install-OneDriveSyncMonitor.ps1') -InstallPath $installed -SkipCloudRestart -DisableAutoUpdate:$disableAutoUpdate
if(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Graph.Authentication.zip') -PathType Leaf){
    if(-not(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Setup-CompanyOneDrive.ps1') -PathType Leaf)){throw 'Dependency initializer is missing.'}
    . (Join-Path $PSScriptRoot 'Setup-CompanyOneDrive.ps1') -LoadFunctionsOnly
    Initialize-CompanyDependency -InstallPath $installed
} else {
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
}
& (Join-Path $installed 'MultiLibrarySync.ps1') -Enable
Write-Host 'Discovery is active. Cloud read/write status is reported per library; sign-in and write probes are separate.'
