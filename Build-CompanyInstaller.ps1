[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [switch]$MultiLibrary,
    # Build-time only. End users do not install or select a module.
    [string]$GraphModulePath = ''
)
$ErrorActionPreference = 'Stop'
$out = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $out -Force | Out-Null
$stage = Join-Path $out ('company-build-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
$payload = @('OneClick-Setup.cmd','OneClick-Setup.ps1','OneClick-Uninstall.cmd',
    'Install-OneDriveSyncMonitor.ps1','Uninstall-OneDriveSyncMonitor.ps1','Manage-OneDriveSyncMonitorInstances.ps1',
    'OneDriveSyncMonitor.ps1','OneDriveCloudBackup.ps1','MultiLibrarySync.ps1','Manage-OneDriveSyncMonitorUi.ps1','New-CloudBackupCertificate.ps1',
    'OneDriveSyncMonitorTray.exe','Update-OneDriveSyncMonitor.ps1','version.json',
    'Setup-MultiLibrarySync.cmd','Setup-MultiLibrarySync.ps1',
    'Company-Setup.cmd','Setup-CompanyOneDrive.ps1','Find-CompanyBackupSource.ps1',
    'Register-CompanyBackupCredential.ps1','Build-OneClickInstaller.ps1',
    'Test-CompanySetup.ps1','Test-CompanyBackupSource.ps1','Test-CompanyBackupEnrollment.ps1',
    'Test-OneDriveCloudBackup.ps1','Test-BidirectionalRepair.ps1',
    'README-CompanyInstaller.md','README-MultiLibrary.md','Test-MultiLibrarySync.ps1')
foreach ($name in $payload) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $stage $name) -ErrorAction Stop
}
$dependencyRoot = Join-Path $stage 'dependency'
$moduleRoot = Join-Path $dependencyRoot 'Microsoft.Graph.Authentication'
New-Item -ItemType Directory -Path $moduleRoot -Force | Out-Null
if ($GraphModulePath) {
    $metadata = Import-PowerShellDataFile (Join-Path $GraphModulePath 'Microsoft.Graph.Authentication.psd1')
    if ([string]$metadata.ModuleVersion -ne '2.41.0') { throw 'Expected Graph.Authentication 2.41.0 for this package.' }
    Copy-Item -LiteralPath $GraphModulePath -Destination (Join-Path $moduleRoot '2.41.0') -Recurse -Force
} else {
    # Explicit official gallery URL; don't use an arbitrary locally reconfigured repository.
    $gallery = Get-PSRepository -Name PSGallery -ErrorAction Stop
    if ($gallery.SourceLocation.TrimEnd('/') -ne 'https://www.powershellgallery.com/api/v2') { throw 'PSGallery source differs from the official gallery.' }
    Save-Module Microsoft.Graph.Authentication -RequiredVersion '2.41.0' -Repository PSGallery -Path $dependencyRoot -AcceptLicense -Force -ErrorAction Stop
}
$dependencyZip = Join-Path $stage 'Graph.Authentication.zip'
Compress-Archive -LiteralPath $moduleRoot -DestinationPath $dependencyZip -CompressionLevel Optimal
@{ Version='2.41.0'; Sha256=(Get-FileHash -LiteralPath $dependencyZip -Algorithm SHA256).Hash } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stage 'GraphDependency.json') -Encoding UTF8
& (Join-Path $stage 'Build-OneClickInstaller.ps1') -Company:(-not $MultiLibrary) -MultiLibrary:$MultiLibrary -OutputDirectory $out
$version = (Get-Content -LiteralPath (Join-Path $stage 'version.json') -Raw | ConvertFrom-Json).version
$packageBase = if($MultiLibrary){"OneDriveSyncMonitor-MultiLibrary-AllInOne-v$version"}else{"OneDriveSyncMonitor-AspectDesign-AllInOne-v$version"}
$zipPath = Join-Path $out ($packageBase + '.zip')
if (Test-Path -LiteralPath $zipPath) { throw "Refusing to overwrite $zipPath" }
$zipFiles = @($payload | Where-Object { $_ -ne 'Build-OneClickInstaller.ps1' } | ForEach-Object { Join-Path $stage $_ }) +
    @($dependencyZip, (Join-Path $stage 'GraphDependency.json'))
Compress-Archive -LiteralPath $zipFiles -DestinationPath $zipPath -CompressionLevel Optimal
foreach ($extension in @('.exe', '.zip')) {
    $file = Join-Path $out ($packageBase + $extension)
    $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath ($file + '.sha256') -Value ("$hash  $(Split-Path -Leaf $file)") -Encoding ASCII
}
Write-Host "Company installer: $(Join-Path $out ($packageBase + '.exe'))"
Write-Host "Reproducible payload kept for verification: $stage"
