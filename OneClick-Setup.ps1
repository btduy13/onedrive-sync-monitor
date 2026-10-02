[CmdletBinding()]
param([switch]$PreflightOnly)

$ErrorActionPreference = 'Stop'
$installPath = Join-Path $env:LOCALAPPDATA 'OneDriveSyncMonitor'

function Ask-YesNo {
    param([string]$Question, [bool]$DefaultYes = $false)
    $hint = if ($DefaultYes) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $answer = (Read-Host "$Question $hint").Trim()
        if (-not $answer) { return $DefaultYes }
        if ($answer -match '^(y|yes)$') { return $true }
        if ($answer -match '^(n|no)$') { return $false }
        Write-Host 'Please enter Y or N.'
    }
}

function Confirm-Payload {
    $required = @('Install-OneDriveSyncMonitor.ps1', 'Uninstall-OneDriveSyncMonitor.ps1',
        'Manage-OneDriveSyncMonitorInstances.ps1', 'OneClick-Uninstall.cmd',
        'OneDriveSyncMonitor.ps1', 'OneDriveCloudBackup.ps1', 'OneDriveSyncMonitorTray.exe',
        'Update-OneDriveSyncMonitor.ps1', 'version.json')
    foreach ($name in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $name) -PathType Leaf)) {
            throw "Installer payload is missing $name"
        }
    }
    if (-not $env:LOCALAPPDATA -or -not (Test-Path -LiteralPath $env:LOCALAPPDATA -PathType Container)) {
        throw 'LOCALAPPDATA is unavailable.'
    }
    if ($PSVersionTable.PSVersion.Major -lt 5) { throw 'Windows PowerShell 5.1 or later is required.' }
    $oneDriveAccount = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\OneDrive\Accounts\Business1' -ErrorAction SilentlyContinue
    Write-Host "Windows account: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    Write-Host "Computer name: $env:COMPUTERNAME"
    if ($oneDriveAccount -and $oneDriveAccount.UserFolder) {
        Write-Host "OneDrive folder: $($oneDriveAccount.UserFolder)"
    }
    else {
        Write-Warning 'OneDrive Business1 is not configured for this Windows user. Monitoring and certificate-based SharePoint backup can still be configured; delegated backup needs this account.'
    }
    return $oneDriveAccount
}

function Resolve-CloudTestFile {
    param([string]$SourceRoot, [string]$RelativePath)
    if ([string]::IsNullOrWhiteSpace($RelativePath)) { throw 'Enter a file path or press Enter to skip.' }
    if ([IO.Path]::IsPathRooted($RelativePath) -or $RelativePath -match '^[A-Za-z]:' -or $RelativePath.Contains(':')) {
        throw 'Enter a file path relative to the selected source folder, for example Documents\test.txt; do not enter a drive such as Z:\.'
    }
    $root = [IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
    $candidate = [IO.Path]::GetFullPath((Join-Path $root $RelativePath))
    if (-not $candidate.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw 'This file does not exist inside the selected source folder.'
    }
    return $candidate
}

try {
    Write-Host 'OneDrive Sync Monitor - one-click setup' -ForegroundColor Cyan
    $oneDriveAccount = Confirm-Payload
    if ($PreflightOnly) { Write-Host 'Preflight passed.'; return }

    Write-Host ''
    Write-Host 'The webhook URL is NOT included in this installer. Paste your Power Automate URL when prompted.'
    Write-Host 'Without a webhook, alerts stay on this computer and are NOT sent to IT.' -ForegroundColor Yellow
    & (Join-Path $PSScriptRoot 'Install-OneDriveSyncMonitor.ps1') -PromptForWebhook
    if (-not (Test-Path -LiteralPath (Join-Path $installPath 'config.json'))) {
        throw 'Monitor installation did not create its configuration.'
    }
    $monitorConfig = Get-Content -LiteralPath (Join-Path $installPath 'config.json') -Raw | ConvertFrom-Json
    if ($monitorConfig.WebhookUrlProtected) {
        Write-Host ''
        Write-Host 'Sending one TEST ONLY alert to verify delivery...'
        try {
            & (Join-Path $installPath 'OneDriveSyncMonitor.ps1') -TestAlert
            Write-Host 'The webhook accepted the test. Confirm the Teams post AND the email to IT in Power Automate.' -ForegroundColor Green
        }
        catch {
            Write-Warning "Test alert failed: $($_.Exception.Message)"
            Write-Warning 'Installation remains active, but remote alert delivery is NOT verified. Contact IT.'
        }
    }
    else {
        Write-Warning 'No webhook configured. Remote IT alerting is OFF on this machine.'
    }

    Write-Host ''
    if (Ask-YesNo 'Set up direct Graph backup for changed files now?') {
        if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
            if (-not (Ask-YesNo 'Microsoft.Graph.Authentication is missing. Install it for this Windows user from PSGallery?')) {
                Write-Host 'Graph backup skipped. Monitoring remains installed.'
                return
            }
            Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force -ErrorAction Stop
        }
        $backup = Join-Path $installPath 'OneDriveCloudBackup.ps1'
        if (Ask-YesNo 'Is the source a SharePoint document library (for example Design - Documents)?') {
            $libraryUrl = (Read-Host 'Paste the SharePoint library AllItems.aspx URL').Trim().Trim('"')
            $sourceRoot = (Read-Host 'Enter the LOCAL folder of that library (for example D:\Users\qqqq\aspectengineering.com.au\Design - Documents)').Trim().Trim('"')
            if (Ask-YesNo 'Use an IT-provisioned Entra app and this computer''s certificate (recommended for background backup)?') {
                Write-Host 'IT must first grant the app Sites.Selected on the exact site and register this machine''s PUBLIC certificate.'
                $tenantId = (Read-Host 'Enter tenant ID').Trim()
                $clientId = (Read-Host 'Enter app (client) ID').Trim()
                $thumbprint = (Read-Host 'Enter this machine''s certificate thumbprint').Trim()
                & $backup -SetupSharePoint -SharePointLibraryUrl $libraryUrl -SourceRoot $sourceRoot `
                    -TenantId $tenantId -ClientId $clientId -CertificateThumbprint $thumbprint
            }
            else {
                if (-not $oneDriveAccount -or -not $oneDriveAccount.UserFolder) {
                    throw 'Delegated Graph backup needs OneDrive Business1; use an IT-provisioned app/certificate or configure that account first.'
                }
                & $backup -SetupSharePoint -SharePointLibraryUrl $libraryUrl -SourceRoot $sourceRoot
            }
        }
        else {
            if (-not $oneDriveAccount -or -not $oneDriveAccount.UserFolder) {
                throw 'Personal OneDrive Graph backup needs OneDrive Business1 for this Windows user.'
            }
            & $backup -Setup
        }
        $cloudConfig = Get-Content -LiteralPath (Join-Path $installPath 'cloud-backup.json') -Raw | ConvertFrom-Json
        $directUploadVerified = $false
        while ($true) {
            $testPath = (Read-Host 'Enter one NEW test file path relative to the selected source folder (blank = skip)').Trim().Trim('"')
            if (-not $testPath) { break }
            try {
                $null = Resolve-CloudTestFile -SourceRoot ([string]$cloudConfig.SourceRoot) -RelativePath $testPath
            }
            catch {
                Write-Warning $_.Exception.Message
                Write-Host 'Try another file, or press Enter to skip cloud upload testing.'
                continue
            }
            $testOutput = & $backup -Once -RelativePath $testPath -NoAlerts
            if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) {
                throw 'Test upload failed. Graph backup was not enabled.'
            }
            $testResult = ($testOutput | Out-String) | ConvertFrom-Json
            Write-Host "Test result: uploaded=$($testResult.Uploaded), adopted=$($testResult.Adopted), failed=$($testResult.Failed)"
            if ([int]$testResult.Uploaded -ne 1 -or [int]$testResult.Failed -ne 0) {
                Write-Warning 'Graph did not upload this file. It may already have synced through OneDrive. Try another new file or press Enter to leave automatic backup OFF.'
                continue
            }
            $directUploadVerified = $true
            break
        }
        if (-not $directUploadVerified) {
            Write-Warning 'Graph backup is configured but NOT enabled. After a new direct-upload test, run OneDriveCloudBackup.ps1 -Enable.'
        }
        else {
            if (Ask-YesNo 'Did the test file appear at the exact expected cloud library/path? Enable automatic backup now?') {
                & $backup -Enable
                Write-Host 'Automatic Graph backup enabled for this Windows user.' -ForegroundColor Green
            }
            else {
                Write-Host 'Automatic Graph backup remains OFF.'
            }
        }
    }

    Write-Host ''
    Write-Host "Installed files and logs: $installPath"
    Write-Host 'Setup complete. Each computer needs its own Graph credential (local certificate for app-only backup).' -ForegroundColor Green
}
catch {
    Write-Error "Setup failed: $($_.Exception.Message)"
    exit 1
}
