[CmdletBinding()]
param([string]$CloudConfigPath = (Join-Path $env:LOCALAPPDATA 'OneDriveSyncMonitor\cloud-backup.json'))

$ErrorActionPreference = 'Stop'
$testRoot = Join-Path $env:TEMP ('OneDriveCloudBackup-LiveTest-' + [guid]::NewGuid().ToString('N'))
$testSource = Join-Path $testRoot 'source'
$fileName = 'OneDriveSyncMonitor-Test-' + [guid]::NewGuid().ToString('N') + '.txt'
$statePath = Join-Path $testRoot 'state.json'
$testItemId = ''
$testDriveId = ''

try {
    New-Item -ItemType Directory -Path $testSource -Force | Out-Null
    $filePath = Join-Path $testSource $fileName
    Set-Content -LiteralPath $filePath -Value 'Cloud backup live test: initial content.' -Encoding UTF8
    . (Join-Path $PSScriptRoot 'OneDriveCloudBackup.ps1') -LoadFunctionsOnly -ConfigPath $CloudConfigPath -StatePath $statePath
    $config = Get-CloudConfig
    Connect-CloudGraph -Config $config
    $testDriveId = [string]$config.DriveId
    $testConfig = [pscustomobject]@{ SourceRoot = $testSource; DriveId = $testDriveId; Account = $config.Account; TenantId = $config.TenantId }

    $initial = Invoke-CloudScan -Config $testConfig -Backfill
    if ($initial.Uploaded -ne 1 -or $initial.Failed -ne 0) { throw "Initial upload failed: $($initial.Errors -join '; ')" }
    $firstRemote = Get-RemoteItem -DriveId $testDriveId -RelativePath $fileName
    if (-not $firstRemote.id -or -not $firstRemote.eTag) { throw 'Uploaded file could not be verified on the cloud.' }
    $testItemId = [string]$firstRemote.id
    if (-not (Test-RemoteMatchesLocal -DriveId $testDriveId -RemoteItem $firstRemote -LocalPath $filePath)) {
        throw 'Uploaded cloud content did not match the local test file.'
    }
    Write-Host 'PASS: a test file was uploaded to the matching cloud path.'

    Set-Content -LiteralPath $filePath -Value 'Cloud backup live test: updated content.' -Encoding UTF8
    $updated = Invoke-CloudScan -Config $testConfig
    if ($updated.Uploaded -ne 1 -or $updated.Failed -ne 0) { throw "Update failed (uploaded=$($updated.Uploaded), adopted=$($updated.Adopted), failed=$($updated.Failed)): $($updated.Errors -join '; ')" }
    $secondRemote = Get-RemoteItem -DriveId $testDriveId -RelativePath $fileName
    if ($secondRemote.eTag -eq $firstRemote.eTag) { throw 'Cloud ETag did not change after update.' }
    Write-Host 'PASS: saving the file updated the same cloud item.'

    $sessionFile = 'OneDriveSyncMonitor-SessionTest-' + [guid]::NewGuid().ToString('N') + '.txt'
    $sessionPath = Join-Path $testSource $sessionFile
    Set-Content -LiteralPath $sessionPath -Value 'Cloud backup upload-session test.' -Encoding UTF8
    $sessionUploaded = Send-CloudFile -DriveId $testDriveId -RelativePath $sessionFile -LocalPath $sessionPath -RemoteItem $null -ForceUploadSession
    if (-not $sessionUploaded.id) { throw 'Upload-session test did not complete.' }
    Write-Host 'PASS: upload session completed.'
    Invoke-CloudGraph -Method DELETE -Uri ('https://graph.microsoft.com/v1.0/drives/{0}/items/{1}' -f [Uri]::EscapeDataString($testDriveId), [Uri]::EscapeDataString([string]$sessionUploaded.id)) | Out-Null
}
finally {
    if ($testItemId -and $testDriveId -and $fileName -like 'OneDriveSyncMonitor-Test-*.txt') {
        try { Invoke-CloudGraph -Method DELETE -Uri ('https://graph.microsoft.com/v1.0/drives/{0}/items/{1}' -f [Uri]::EscapeDataString($testDriveId), [Uri]::EscapeDataString($testItemId)) | Out-Null }
        catch { Write-Warning "Could not remove cloud test file $fileName`: $($_.Exception.Message)" }
    }
    if (Test-Path -LiteralPath $testRoot) {
        $resolved = (Resolve-Path -LiteralPath $testRoot).Path
        $resolvedTemp = (Resolve-Path -LiteralPath $env:TEMP).Path.TrimEnd('\')
        if (-not $resolved.StartsWith($resolvedTemp + '\OneDriveCloudBackup-LiveTest-', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to delete unexpected test folder: $resolved"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
