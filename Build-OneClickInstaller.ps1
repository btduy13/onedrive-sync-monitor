[CmdletBinding()]
param([string]$OutputDirectory = '', [switch]$Company, [switch]$MultiLibrary)

$ErrorActionPreference = 'Stop'
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $PSScriptRoot 'dist' }
$iexpress = Join-Path $env:WINDIR 'System32\iexpress.exe'
if (-not (Test-Path -LiteralPath $iexpress -PathType Leaf)) { throw 'Windows IExpress is not available on this build machine.' }
$version = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'version.json') -Raw | ConvertFrom-Json).version
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid version.json version.' }
$payload = @(
    'OneClick-Setup.cmd',
    'OneClick-Setup.ps1',
    'OneClick-Uninstall.cmd',
    'Install-OneDriveSyncMonitor.ps1',
    'Uninstall-OneDriveSyncMonitor.ps1',
    'Manage-OneDriveSyncMonitorInstances.ps1',
    'OneDriveSyncMonitor.ps1',
    'OneDriveCloudBackup.ps1',
    'MultiLibrarySync.ps1', 'Manage-OneDriveSyncMonitorUi.ps1', 'Find-CompanyBackupSource.ps1',
    'New-CloudBackupCertificate.ps1',
    'OneDriveSyncMonitorTray.exe',
    'Update-OneDriveSyncMonitor.ps1',
    'version.json'
)
if ($Company) {
    $payload += @('Company-Setup.cmd', 'Setup-CompanyOneDrive.ps1', 'Find-CompanyBackupSource.ps1',
        'Register-CompanyBackupCredential.ps1', 'Graph.Authentication.zip', 'GraphDependency.json')
}
if ($MultiLibrary) {
    $payload += @('Setup-MultiLibrarySync.cmd','Setup-MultiLibrarySync.ps1','Setup-CompanyOneDrive.ps1',
        'Graph.Authentication.zip','GraphDependency.json','README-MultiLibrary.md')
}
$payload = @($payload | Select-Object -Unique)
foreach ($name in $payload) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $name) -PathType Leaf)) { throw "Missing payload file: $name" }
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$label = if ($MultiLibrary) { 'MultiLibrary-AllInOne' } elseif ($Company) { 'AspectDesign-AllInOne' } else { 'OneClick' }
$output = Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) "OneDriveSyncMonitor-$label-v$version.exe"
if (Test-Path -LiteralPath $output) { throw "Refusing to overwrite existing installer: $output" }
$stage = Join-Path $env:TEMP ('OneDriveSyncMonitor-Build-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage -Force | Out-Null
try {
    foreach ($name in $payload) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $stage $name) -ErrorAction Stop }
    $sedPath = Join-Path $stage 'installer.sed'
    $fileStrings = for ($i = 0; $i -lt $payload.Count; $i++) { 'FILE{0}="{1}"' -f $i, $payload[$i] }
    $fileEntries = for ($i = 0; $i -lt $payload.Count; $i++) { '%FILE{0}%=' -f $i }
    $sed = @(
        '[Version]'
        'Class=IEXPRESS'
        'SEDVersion=3'
        '[Options]'
        'PackagePurpose=InstallApp'
        'ShowInstallProgramWindow=1'
        'HideExtractAnimation=1'
        'UseLongFileName=1'
        'InsideCompressed=0'
        'CAB_FixedSize=0'
        'CAB_ResvCodeSigning=0'
        'RebootMode=N'
        'InstallPrompt='
        'DisplayLicense='
        'FinishMessage='
        "TargetName=$output"
        "FriendlyName=OneDrive Sync Monitor $version"
        $(if ($MultiLibrary) { 'AppLaunched=cmd.exe /c Setup-MultiLibrarySync.cmd' } elseif ($Company) { 'AppLaunched=cmd.exe /c Company-Setup.cmd' } else { 'AppLaunched=cmd.exe /c OneClick-Setup.cmd' })
        'PostInstallCmd=<None>'
        'AdminQuietInstCmd='
        'UserQuietInstCmd='
        'SourceFiles=SourceFiles'
        '[Strings]'
    ) + $fileStrings + @(
        '[SourceFiles]'
        "SourceFiles0=$stage"
        '[SourceFiles0]'
    ) + $fileEntries
    [IO.File]::WriteAllLines($sedPath, $sed, [Text.Encoding]::ASCII)
    if ($sedPath.Contains(' ')) { throw 'IExpress requires a temporary SED path without spaces.' }
    $process = Start-Process -FilePath $iexpress -ArgumentList @('/N', $sedPath) -PassThru -WindowStyle Hidden
    if (-not $process.WaitForExit(30000)) {
        Stop-Process -Id $process.Id -ErrorAction SilentlyContinue
        throw 'IExpress did not finish within 30 seconds. Check the SED configuration.'
    }
    if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $output -PathType Leaf)) {
        throw "IExpress failed (exit $($process.ExitCode)). SED: $sedPath"
    }
    $hash = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Host "Created: $output"
    Write-Host "SHA-256: $hash"
    Write-Host "Bytes: $((Get-Item -LiteralPath $output).Length)"
}
finally {
    if ((Test-Path -LiteralPath $stage) -and
        $stage.StartsWith(([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\OneDriveSyncMonitor-Build-'), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}
