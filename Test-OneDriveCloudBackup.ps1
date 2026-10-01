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
