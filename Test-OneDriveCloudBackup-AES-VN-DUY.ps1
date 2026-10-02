[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$testRoot = Join-Path $env:TEMP ('OneDriveCloudBackup-Test-' + [guid]::NewGuid().ToString('N'))
$source = Join-Path $testRoot 'source'
New-Item -ItemType Directory -Path $source -Force | Out-Null
$StatePath = Join-Path $testRoot 'state.json'
$ConfigPath = Join-Path $testRoot 'cloud-backup.json'

try {
    . (Join-Path $PSScriptRoot 'OneDriveCloudBackup.ps1') -LoadFunctionsOnly -StatePath $StatePath -ConfigPath $ConfigPath
    Set-Content -LiteralPath (Join-Path $source 'existing.txt') -Value 'original' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $source 'new.txt') -Value 'new' -Encoding UTF8
    $config = [pscustomobject]@{ SourceRoot = $source; DriveId = 'drive-test'; Account = 'test@example.com'; TenantId = 'tenant-test' }
    $script:remote = @{
        'existing.txt' = [pscustomobject]@{ id = 'id-existing'; eTag = 'etag-1'; file = @{} }
    }
    $script:uploads = New-Object 'System.Collections.Generic.List[string]'

    function Get-RemoteItem {
        param([string]$DriveId, [string]$RelativePath)
        return $script:remote[$RelativePath]
    }
    function Send-CloudFile {
        param([string]$DriveId, [string]$RelativePath, [string]$LocalPath, $RemoteItem)
        $script:uploads.Add($RelativePath)
        $etag = 'uploaded-' + $script:uploads.Count
        $script:remote[$RelativePath] = [pscustomobject]@{ id = 'id-uploaded'; eTag = $etag; file = @{} }
        return $script:remote[$RelativePath]
    }
    function Assert-CloudTest {
        param([bool]$Condition, [string]$Message)
        if (-not $Condition) { throw "FAIL: $Message" }
        Write-Host "PASS: $Message"
    }

    $now = [DateTime]::UtcNow
    Assert-CloudTest (Test-CloudAuthCheckDue -Config ([pscustomobject]@{ AuthMode = 'Certificate' }) -LastCheckUtc ([DateTime]::MinValue) -NowUtc $now) 'Certificate authentication is checked on the first idle cycle'
    Assert-CloudTest (-not (Test-CloudAuthCheckDue -Config ([pscustomobject]@{ AuthMode = 'Certificate' }) -LastCheckUtc $now.AddMinutes(-9) -NowUtc $now)) 'Certificate authentication checks are throttled after failure'
    Assert-CloudTest (Test-CloudAuthCheckDue -Config ([pscustomobject]@{ AuthMode = 'Certificate' }) -LastCheckUtc $now.AddMinutes(-31) -NowUtc $now) 'Certificate authentication is rechecked while idle'
    Assert-CloudTest (-not (Test-CloudAuthCheckDue -Config ([pscustomobject]@{ AuthMode = 'Delegated' }) -LastCheckUtc ([DateTime]::MinValue) -NowUtc $now)) 'Delegated watcher is not changed by certificate health check'

    & {
        function Get-MgContext {
            return [pscustomobject]@{
                Account = 'archive@warramali.au'
                TenantId = 'tenant-test'
                Scopes = @('Files.ReadWrite.All', 'Sites.Read.All')
            }
        }
        function Invoke-MgGraphRequest {
            throw 'DeviceCodeCredential authentication failed: Bearer TEST_SECRET_DO_NOT_LOG'
        }
        $authRejected = $false
        $reportedError = ''
        try {
            Connect-CloudGraph -Config ([pscustomobject]@{
                TargetType = 'SharePoint'
                Account = 'archive@warramali.au'
                TenantId = 'tenant-test'
                LibraryWebUrl = 'https://aspectengwa.sharepoint.com/sites/Design/Shared%20Documents'
            })
        }
        catch { $authRejected = $true; $reportedError = $_.Exception.Message }
        Assert-CloudTest $authRejected 'A Graph context is not considered ready when token acquisition fails'
        Assert-CloudTest ($reportedError -notlike '*TEST_SECRET_DO_NOT_LOG*') 'Authentication errors do not expose SDK exception details to alerts'
    }
    & {
        function Get-MgContext {
            return [pscustomobject]@{
                Account = 'archive@warramali.au'
                TenantId = 'tenant-test'
                Scopes = @('Files.ReadWrite.All', 'Sites.Read.All')
            }
        }
        function Invoke-MgGraphRequest {
            param([string]$Method, [string]$Uri)
            if ($Method -ne 'GET' -or $Uri -ne 'https://graph.microsoft.com/v1.0/sites/aspectengwa.sharepoint.com:/sites/Design') {
                throw "Unexpected authentication probe: $Method $Uri"
            }
            return [pscustomobject]@{ id = 'site-test' }
        }
        Connect-CloudGraph -Config ([pscustomobject]@{
            TargetType = 'SharePoint'
            Account = 'archive@warramali.au'
            TenantId = 'tenant-test'
            LibraryWebUrl = 'https://aspectengwa.sharepoint.com/sites/Design/Shared%20Documents'
        })
        Assert-CloudTest $true 'SharePoint authentication performs a read-only site probe'
    }
    & {
        $script:appConnect = $null
        $thumbprint = 'AABBCCDDEEFF00112233445566778899AABBCCDD'
        function Get-MgContext {
            if ($script:appConnect) {
                return [pscustomobject]@{
                    AuthType = 'AppOnly'; ClientId = '11111111-1111-1111-1111-111111111111'
                    TenantId = 'tenant-test'; CertificateThumbprint = 'AABBCCDDEEFF00112233445566778899AABBCCDD'
                }
            }
            return [pscustomobject]@{ AuthType = 'Delegated'; Account = 'duy@example.com'; TenantId = 'tenant-test'; Scopes = @('Files.ReadWrite.All') }
        }
        function Get-Item {
            param([string]$LiteralPath)
            if ($LiteralPath -ne 'Cert:\CurrentUser\My\AABBCCDDEEFF00112233445566778899AABBCCDD') { throw "Unexpected certificate: $LiteralPath" }
            return [pscustomobject]@{ HasPrivateKey = $true; NotAfter = (Get-Date).AddYears(1) }
        }
        function Connect-MgGraph {
            [CmdletBinding()]
            param([string]$ClientId, [string]$TenantId, [string]$CertificateThumbprint,
                [string]$ContextScope, [switch]$NoWelcome)
            $script:appConnect = [pscustomobject]@{
                ClientId = $ClientId; TenantId = $TenantId
                CertificateThumbprint = $CertificateThumbprint; ContextScope = $ContextScope
            }
        }
        function Invoke-MgGraphRequest {
            param([string]$Method, [string]$Uri)
            return [pscustomobject]@{ id = 'site-test' }
        }
        Connect-CloudGraph -Config ([pscustomobject]@{
            AuthMode = 'Certificate'; TargetType = 'SharePoint'
            Account = 'archive@warramali.au'; TenantId = 'tenant-test'
            ClientId = '11111111-1111-1111-1111-111111111111'
            CertificateThumbprint = $thumbprint
            LibraryWebUrl = 'https://aspectengwa.sharepoint.com/sites/Design/Shared%20Documents'
        })
        Assert-CloudTest ($script:appConnect.ClientId -eq '11111111-1111-1111-1111-111111111111' -and
            $script:appConnect.CertificateThumbprint -eq $thumbprint -and
            $script:appConnect.ContextScope -eq 'Process') 'Certificate mode connects app-only without delegated account or device code'
    }
    & {
        function Get-MgContext { return $null }
        function Get-Item { return [pscustomobject]@{ HasPrivateKey = $false; NotAfter = (Get-Date).AddYears(1) } }
        function Connect-MgGraph { throw 'Must not connect with a certificate that has no private key.' }
        $rejected = $false
        try {
            Connect-CloudGraph -Config ([pscustomobject]@{
                AuthMode = 'Certificate'; TargetType = 'SharePoint'; TenantId = 'tenant-test'
                ClientId = '11111111-1111-1111-1111-111111111111'
                CertificateThumbprint = 'AABBCCDDEEFF00112233445566778899AABBCCDD'
                LibraryWebUrl = 'https://aspectengwa.sharepoint.com/sites/Design/Shared%20Documents'
            })
        }
        catch { $rejected = $_.Exception.Message -like '*no valid private key*' }
        Assert-CloudTest $rejected 'Certificate mode refuses a missing private key before Graph sign-in'
    }
    $appLocation = Get-SharePointLibraryLocation -Url 'https://aspectengwa.sharepoint.com/sites/Design/Shared%20Documents/Forms/AllItems.aspx'
    $appDraft = New-SharePointBackupDraft -Root $source -Location $appLocation `
        -TenantId '22222222-2222-2222-2222-222222222222' `
        -ClientId '11111111-1111-1111-1111-111111111111' `
        -CertificateThumbprint 'AABBCCDDEEFF00112233445566778899AABBCCDD'
    Assert-CloudTest ($appDraft.AuthMode -eq 'Certificate' -and
        $appDraft.SourceRoot -eq $source -and $appDraft.Account -eq 'App:11111111-1111-1111-1111-111111111111') `
        'Certificate SharePoint setup does not require a delegated OneDrive account'

    $libraryUrl = 'https://aspectengwa.sharepoint.com/sites/Design/Shared%20Documents/Forms/AllItems.aspx'
    $location = Get-SharePointLibraryLocation -Url $libraryUrl
    Assert-CloudTest ($location.SitePath -eq 'sites/Design' -and
        $location.LibraryPath -eq 'sites/Design/Shared Documents') 'SharePoint URL identifies the site and document library'
    $rejected = $false
    try { Get-SharePointLibraryLocation -Url 'https://aspectengwa.sharepoint.com/sites/Design/' | Out-Null }
    catch { $rejected = $true }
    Assert-CloudTest $rejected 'A site URL without a document library is rejected'

    function Invoke-CloudGraph {
        param([string]$Method, [string]$Uri)
        if ($Uri -like '*sites/aspectengwa.sharepoint.com:/sites/Design') {
            return [pscustomobject]@{ id = 'site-test' }
        }
        if ($Uri -like '*/sites/site-test/drives') {
            return [pscustomobject]@{ value = @(
                [pscustomobject]@{ id = 'wrong-drive'; driveType = 'documentLibrary'; webUrl = 'https://aspectengwa.sharepoint.com/sites/Design/Other' },
                [pscustomobject]@{ id = 'design-drive'; driveType = 'documentLibrary'; webUrl = 'https://aspectengwa.sharepoint.com/sites/Design/Shared%20Documents' }
            ) }
        }
        throw "Unexpected Graph test request: $Uri"
    }
    $resolved = Resolve-SharePointLibraryDrive -Location $location
    Assert-CloudTest ($resolved.SiteId -eq 'site-test' -and $resolved.DriveId -eq 'design-drive') 'SharePoint target matches the exact document-library URL'
    $wrongLocation = [pscustomobject]@{ Host = $location.Host; SitePath = $location.SitePath; LibraryPath = 'sites/Design/Missing'; LibraryWebUrl = 'https://aspectengwa.sharepoint.com/sites/Design/Missing' }
    $rejected = $false
    try { Resolve-SharePointLibraryDrive -Location $wrongLocation | Out-Null }
    catch { $rejected = $true }
    Assert-CloudTest $rejected 'Missing document library is rejected instead of selecting another drive'
    Assert-CloudTest (-not (Test-LocalContentPresent -Item ([pscustomobject]@{ Attributes = 0x00400000 }))) 'Cloud-only placeholder is not read or hydrated'

    $baseline = Invoke-CloudScan -Config $config
    Assert-CloudTest ($baseline.Adopted -eq 2 -and $baseline.Uploaded -eq 0 -and $baseline.Failed -eq 0) 'First scan establishes a baseline without bulk uploading'

    $first = Invoke-CloudScan -Config $config -Backfill
    Assert-CloudTest ($first.Uploaded -eq 1 -and $first.Failed -eq 0) 'Backfill uploads the file missing on the cloud'
    Assert-CloudTest ($script:uploads.Count -eq 1 -and $script:uploads[0] -eq 'new.txt') 'Initial scan does not overwrite existing cloud content'

    $second = Invoke-CloudScan -Config $config
    Assert-CloudTest ($second.Uploaded -eq 0 -and $second.Failed -eq 0) 'Unchanged local files are not uploaded again'

    Set-Content -LiteralPath (Join-Path $source 'existing.txt') -Value 'updated locally' -Encoding UTF8
    $third = Invoke-CloudScan -Config $config
    Assert-CloudTest ($third.Uploaded -eq 1 -and $third.Failed -eq 0) 'Saved local file updates the same cloud path'

    $script:remote['existing.txt'] = [pscustomobject]@{ id = 'id-existing'; eTag = 'edited-elsewhere'; file = @{} }
    Set-Content -LiteralPath (Join-Path $source 'existing.txt') -Value 'second local edit' -Encoding UTF8
    $fourth = Invoke-CloudScan -Config $config
    Assert-CloudTest ($fourth.Failed -eq 1 -and $script:uploads.Count -eq 2) 'Independent cloud edit blocks overwrite and reports conflict'

    $nested = Join-Path $source 'nested'
    New-Item -ItemType Directory -Path $nested -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $nested 'event.txt') -Value 'saved' -Encoding UTF8
    $eventResult = Invoke-CloudScan -Config $config -RelativePaths @('nested\event.txt')
    Assert-CloudTest ($eventResult.Uploaded -eq 1 -and $script:uploads[2] -eq 'nested\event.txt') 'Save event uploads only its relative cloud path'
    $unsafeRejected = $false
    try { Invoke-CloudScan -Config $config -RelativePaths @('..\outside.txt') | Out-Null }
    catch { $unsafeRejected = $true }
    Assert-CloudTest $unsafeRejected 'Relative path cannot escape the source folder'

    $fakeMonitor = Join-Path $testRoot 'FakeMonitor.ps1'
    @'
param([switch]$LoadFunctionsOnly, [string]$ConfigPath)
$StatePath = Join-Path $PSScriptRoot 'wrong-state.json'
function Get-MonitorConfig { return [pscustomobject]@{ WebhookUrl = 'fake'; ComputerName = 'TEST-PC' } }
function Send-WebhookAlert { param($Url, $Result, $Reason) return $true }
'@ | Set-Content -LiteralPath $fakeMonitor -Encoding UTF8
    Send-CloudStatus -Config $config -Result ([pscustomobject]@{ Failed = 1; Errors = @('TEST ONLY: simulated failure') }) -MonitorPath $fakeMonitor
    $alertState = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    Assert-CloudTest ($alertState.LastDeliveredFailure -like '*TEST ONLY*' -and -not (Test-Path -LiteralPath (Join-Path $testRoot 'wrong-state.json'))) 'Cloud alert state does not overwrite monitor state'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolved = (Resolve-Path -LiteralPath $testRoot).Path
        $resolvedTemp = (Resolve-Path -LiteralPath $env:TEMP).Path.TrimEnd('\')
        if (-not $resolved.StartsWith($resolvedTemp + '\OneDriveCloudBackup-Test-', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to delete unexpected test folder: $resolved"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
