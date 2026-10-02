[CmdletBinding()]
param([switch]$PreflightOnly, [switch]$LoadFunctionsOnly)
$ErrorActionPreference = 'Stop'
$script:companyPayloadRoot = $PSScriptRoot

function Get-CompanyBackupProfile {
    [pscustomobject]@{
        TenantId = 'a2f1a70f-1bf7-48c7-9b0f-c0d3f912a76e'
        ClientId = '4f06b4cf-c94e-4eb7-930f-e03daa267193'
        SiteUrl = 'https://aspectengwa.sharepoint.com/sites/Design'
        LibraryWebUrl = 'https://aspectengwa.sharepoint.com/sites/Design/Shared%20Documents'
    }
}

function Test-SameBackupTarget {
    param($Existing, $Target)
    if (-not $Existing -or $Existing.TargetType -ne 'SharePoint') { return $false }
    foreach ($field in @('TenantId', 'SourceRoot', 'SiteId', 'DriveId')) {
        if (-not $Existing.$field -or [string]$Existing.$field -ine [string]$Target.$field) { return $false }
    }
    try {
        return [Uri]::UnescapeDataString([string]$Existing.LibraryWebUrl).TrimEnd('/') -ieq
            [Uri]::UnescapeDataString([string]$Target.LibraryWebUrl).TrimEnd('/')
    } catch { return $false }
}

function Test-CompanyLegacyUnverifiedConfig {
    param($Existing)
    if ($null -eq $Existing) { return $false }
    if ([string]$Existing.TargetType -ne 'SharePoint') { return $true }
    foreach ($field in @('TenantId', 'SourceRoot', 'LibraryWebUrl', 'SiteId', 'DriveId')) {
        if ([string]::IsNullOrWhiteSpace([string]$Existing.$field)) { return $true }
    }
    return $false
}

function Invoke-CompanyInstallFiles {
    param($InstallPath)
    # No prompts, test email or early restart of a potentially wrong backup target.
    & (Join-Path $script:companyPayloadRoot 'Install-OneDriveSyncMonitor.ps1') -InstallPath $InstallPath -SkipCloudRestart -DisableAutoUpdate
}

function Initialize-CompanyDependency {
    param($InstallPath)
    $manifest = Get-Content -LiteralPath (Join-Path $script:companyPayloadRoot 'GraphDependency.json') -Raw | ConvertFrom-Json
    $archivePath = Join-Path $script:companyPayloadRoot 'Graph.Authentication.zip'
    if ($manifest.Version -ne '2.41.0' -or $manifest.Sha256 -notmatch '^[a-fA-F0-9]{64}$' -or
        (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash -ine $manifest.Sha256) {
        throw 'Bundled Graph dependency is missing or corrupt. Download the complete company installer again.'
    }
    $runtime = Join-Path $InstallPath ('GraphRuntime-' + $manifest.Sha256.Substring(0, 16).ToLowerInvariant())
    $relativeManifest = 'Microsoft.Graph.Authentication\2.41.0\Microsoft.Graph.Authentication.psd1'
    $moduleManifest = Join-Path $runtime $relativeManifest
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($archivePath)
    try {
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName.Replace('/', '\')
            if ($name -notlike 'Microsoft.Graph.Authentication\2.41.0\*' -or
                $name -match '(^|\\)\.\.?($|\\)' -or $name.Contains(':') -or [IO.Path]::IsPathRooted($name)) {
                throw 'Unexpected path in bundled Graph dependency.'
            }
        }
        foreach ($entry in $archive.Entries) {
            if ($entry.FullName.EndsWith('/')) { continue }
            $destination = Join-Path $runtime $entry.FullName.Replace('/', '\')
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            # Re-extract the verified archive on repair; never load another globally installed SDK.
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destination, $true)
        }
    } finally { $archive.Dispose() }
    Import-Module $moduleManifest -Force -ErrorAction Stop
    @{ ManifestPath = $moduleManifest; Version = $manifest.Version } | ConvertTo-Json |
        Set-Content -LiteralPath (Join-Path $InstallPath 'graph-runtime.json') -Encoding UTF8
}

function Get-CompanyExistingConfig {
    param($InstallPath)
    $path = Join-Path $InstallPath 'cloud-backup.json'
    if (Test-Path -LiteralPath $path) { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
}

function Get-CompanyCertificate {
    param($InstallPath, $Profile, $Existing)
    if ($Existing -and $Existing.AuthMode -eq 'Certificate' -and $Existing.ClientId -eq $Profile.ClientId -and
        $Existing.TenantId -eq $Profile.TenantId -and $Existing.CertificateThumbprint -match '^[a-fA-F0-9]{40}$') {
        $cert = Get-Item -LiteralPath ('Cert:\CurrentUser\My\' + $Existing.CertificateThumbprint) -ErrorAction SilentlyContinue
        if ($cert -and $cert.HasPrivateKey -and $cert.NotAfter -gt (Get-Date).AddDays(7)) { return $cert }
    }
    $name = 'OneDriveCloudBackup Design ' + $Profile.ClientId
    $found = @(Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -eq ('CN=' + $name) })
    if ($found.Count -gt 1) { throw 'Multiple Design backup certificates exist. IT must resolve the ambiguity; no certificate was removed.' }
    if ($found.Count -eq 1) {
        if (-not $found[0].HasPrivateKey -or $found[0].NotAfter -le (Get-Date).AddDays(7)) {
            throw 'Existing Design certificate is expired or unavailable. IT certificate renewal is required; existing keys were kept.'
        }
        return $found[0]
    }
    $publicPath = Join-Path $InstallPath ('Design-public-' + [guid]::NewGuid().ToString('N') + '.cer')
    $created = & (Join-Path $InstallPath 'New-CloudBackupCertificate.ps1') -CertificateName $name -PublicCertPath $publicPath
    return Get-Item -LiteralPath ('Cert:\CurrentUser\My\' + $created.Thumbprint)
}

function Resolve-CompanyCloudTarget {
    param($Profile, $SourceRoot, $Certificate)
    $location = Get-SharePointLibraryLocation -Url ($Profile.LibraryWebUrl + '/Forms/AllItems.aspx')
    $draft = New-SharePointBackupDraft -Root $SourceRoot -Location $location -TenantId $Profile.TenantId -ClientId $Profile.ClientId -CertificateThumbprint $Certificate.Thumbprint
    try { Connect-CloudGraph -Config $draft }
    catch {
        Write-Host 'Microsoft sign-in is required to enroll this PC. Sign in with an authorized IT administrator.' -ForegroundColor Yellow
        & (Join-Path $script:companyPayloadRoot 'Register-CompanyBackupCredential.ps1') -TenantId $Profile.TenantId -ClientId $Profile.ClientId -CertificateThumbprint $Certificate.Thumbprint -SiteUrl $Profile.SiteUrl | Out-Host
        # Directory changes may take a short time to propagate. Do not loop sign-in prompts.
        $connected = $false
        for ($attempt = 0; $attempt -lt 6; $attempt++) {
            try { Connect-CloudGraph -Config $draft; $connected = $true; break }
            catch { if ($attempt -eq 5) { throw }; Start-Sleep -Seconds 5 }
        }
        if (-not $connected) { throw 'The new PC credential could not be verified.' }
    }
    $resolved = Resolve-SharePointLibraryDrive -Location $location
    $draft.SiteId = $resolved.SiteId; $draft.DriveId = $resolved.DriveId; $draft.LibraryWebUrl = $resolved.LibraryWebUrl
    return $draft
}

function Save-CompanyCloudTarget {
    param($InstallPath, $Existing, $Target)
    $statePath = Join-Path $InstallPath 'cloud-backup-state.json'
    if ((Test-Path -LiteralPath $statePath) -and -not (Test-SameBackupTarget $Existing $Target)) {
        if (-not (Test-CompanyLegacyUnverifiedConfig -Existing $Existing)) {
            throw 'Existing backup state belongs to a different verified SharePoint target. It was kept; backup remains OFF pending IT migration.'
        }
        $archivePath = '{0}.before-company-{1}.bak' -f $statePath, [guid]::NewGuid().ToString('N')
        Move-Item -LiteralPath $statePath -Destination $archivePath -ErrorAction Stop
        Write-Host "Archived legacy unverified cloud state at $archivePath"
    }
    $configPath = Join-Path $InstallPath 'cloud-backup.json'
    if (Test-Path -LiteralPath $configPath) {
        Copy-Item -LiteralPath $configPath -Destination ($configPath + '.before-company-' + [guid]::NewGuid().ToString('N') + '.bak')
    }
    $Target | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath -Encoding UTF8
}

function Test-CompanyDirectUpload {
    param($InstallPath, $Target)
    # Upload from outside the sync root so OneDrive cannot win the race and masquerade as a Graph test.
    $probeName = 'OneDriveMonitor-Verification-' + [guid]::NewGuid().ToString('N') + '.txt'
    $local = Join-Path $InstallPath $probeName
    [IO.File]::WriteAllText($local, ('OneDrive Sync Monitor verification; UTC=' + [DateTime]::UtcNow.ToString('o') + '; nonce=' + [guid]::NewGuid().ToString('N')))
    $remote = Get-RemoteItem -DriveId $Target.DriveId -RelativePath $probeName
    if ($remote) { throw 'Verification filename collision. No remote file was replaced.' }
    # The unique probe is intentionally retained in the library as evidence. No production file is modified.
    $uploaded = Send-CloudFile -DriveId $Target.DriveId -RelativePath $probeName -LocalPath $local -RemoteItem $null
    if (-not $uploaded.id -or -not (Test-RemoteMatchesLocal -DriveId $Target.DriveId -RemoteItem $uploaded -LocalPath $local)) {
        throw 'Direct Graph upload/download verification failed. Automatic backup was NOT enabled.'
    }
    return $probeName
}

function Enable-CompanyBackup {
    param($InstallPath)
    & (Join-Path $InstallPath 'OneDriveCloudBackup.ps1') -Enable
}
function Disable-CompanyBackup {
    param($InstallPath)
    & (Join-Path $InstallPath 'OneDriveCloudBackup.ps1') -Disable
}
function Confirm-CompanyWatcher {
    param($InstallPath, [DateTime]$StartedUtc)
    $deadline = [DateTime]::UtcNow.AddSeconds(45)
    $statePath = Join-Path $InstallPath 'cloud-backup-state.json'
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $state = Get-Content -LiteralPath $statePath -Raw -ErrorAction Stop | ConvertFrom-Json
            # Require a loop heartbeat, not only the initial state write at process startup.
            if ($state.LastSuccessfulCycleUtc -and ([DateTime]$state.LastSuccessfulCycleUtc).ToUniversalTime() -gt $StartedUtc) {
                if ($state.LastFailure) { throw ('Background backup failed: ' + $state.LastFailure) }
                return
            }
        } catch { if ($_.Exception.Message -like 'Background backup failed:*') { throw } }
        Start-Sleep -Seconds 2
    }
    throw 'Backup was started but no fresh loop heartbeat was received. Automatic backup has been disabled; check cloud-backup.log.'
}
function Get-CompanyAlertStatus {
    param($InstallPath)
    $config = Get-Content -LiteralPath (Join-Path $InstallPath 'config.json') -Raw | ConvertFrom-Json
    if (-not $config.WebhookUrlProtected) { return 'NotConfigured' }
    if ($config.NotifyItEmailEnabled -eq $false) { return 'EmailDisabledByUser' }
    return 'ExistingEndpointPreserved_NotDeliveryTested'
}
function Write-CompanySetupResult {
    param($InstallPath, $Result)
    $Result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $InstallPath 'company-setup-result.json') -Encoding UTF8
}

function Invoke-CompanySetup {
    param([string]$InstallPath)
    $profile = Get-CompanyBackupProfile
    $result = [ordered]@{ CompletedUtc=''; BackupVerified=$false; ComputerName=$env:COMPUTERNAME; SourceRoot=''; LibraryWebUrl=$profile.LibraryWebUrl; RemoteAlerts='NotChecked'; ProbeFile=''; Error='' }
    $enabled = $false
    try {
        Invoke-CompanyInstallFiles -InstallPath $InstallPath
        Initialize-CompanyDependency -InstallPath $InstallPath
        $existing = Get-CompanyExistingConfig -InstallPath $InstallPath
        $source = Resolve-CompanyBackupSource -LibraryWebUrl $profile.LibraryWebUrl -TenantId $profile.TenantId -ExistingConfig $existing
        $root = [string]$source.SourceRoot
        if ([string]::IsNullOrWhiteSpace($root)) { throw 'Source discovery did not return a verified local folder.' }
        $result.SourceRoot = $root
        Write-Host "Detected Design library: $root"
        $cert = Get-CompanyCertificate -InstallPath $InstallPath -Profile $profile -Existing $existing
        $target = Resolve-CompanyCloudTarget -Profile $profile -SourceRoot $root -Certificate $cert
        Save-CompanyCloudTarget -InstallPath $InstallPath -Existing $existing -Target $target
        $result.ProbeFile = Test-CompanyDirectUpload -InstallPath $InstallPath -Target $target
        $started = [DateTime]::UtcNow
        $enabled = $true
        Enable-CompanyBackup -InstallPath $InstallPath
        Write-Host 'Cloud upload verified. Checking background heartbeat (up to 45 seconds)...'
        Confirm-CompanyWatcher -InstallPath $InstallPath -StartedUtc $started
        $result.BackupVerified = $true
        $result.RemoteAlerts = Get-CompanyAlertStatus -InstallPath $InstallPath
        $result.OverallReady = $false
        $result.AlertDeliveryVerified = $false
        $result.UpdateStatus = 'DisabledPendingTrustedSignedUpdates'
        $result.CompletedUtc = [DateTime]::UtcNow.ToString('o')
        Write-CompanySetupResult -InstallPath $InstallPath -Result $result
        return [pscustomobject]$result
    } catch {
        $failure = $_
        if ($enabled) { try { Disable-CompanyBackup -InstallPath $InstallPath } catch { Write-Warning 'Could not disable backup; check the tray before retrying.' } }
        $result.BackupVerified = $false
        $result.Error = $failure.Exception.Message
        try { Write-CompanySetupResult -InstallPath $InstallPath -Result $result } catch { }
        throw $failure
    }
}

if ($LoadFunctionsOnly) { return }
try {
    Write-Host 'Aspect Design - automatic setup (no configuration fields)' -ForegroundColor Cyan
    Write-Host 'Run as the Windows user who works in the Design folder. IT sign-in is separate; do not Run as another Windows user.'
    foreach ($name in @('Install-OneDriveSyncMonitor.ps1', 'Find-CompanyBackupSource.ps1', 'Register-CompanyBackupCredential.ps1', 'Graph.Authentication.zip', 'GraphDependency.json')) {
        if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $name) -PathType Leaf)) { throw "Incomplete company installer: $name" }
    }
    if ($PreflightOnly) { Write-Host 'Company payload present; no system or cloud changes made.'; return }
    . (Join-Path $PSScriptRoot 'Find-CompanyBackupSource.ps1') -LoadFunctionsOnly
    . (Join-Path $PSScriptRoot 'OneDriveCloudBackup.ps1') -LoadFunctionsOnly
    $installed = Join-Path $env:LOCALAPPDATA 'OneDriveSyncMonitor'
    $result = Invoke-CompanySetup -InstallPath $installed
    $result | Format-List
    if ($result.RemoteAlerts -eq 'NotConfigured') {
        Write-Warning 'Backup is verified, but this PC has no company alert endpoint. Teams/email delivery is NOT configured. No webhook secret is embedded in this installer.'
    }
    Write-Host "Backup component verified. Full deployment still requires alert delivery verification and trusted update provisioning. Report: $installed\company-setup-result.json" -ForegroundColor Yellow
} catch {
    Write-Host ('Company setup incomplete: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
