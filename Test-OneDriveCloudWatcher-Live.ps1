[CmdletBinding()]
param([string]$CloudConfigPath = (Join-Path $env:LOCALAPPDATA 'OneDriveSyncMonitor\cloud-backup.json'))

$ErrorActionPreference = 'Stop'
$testRoot = Join-Path $env:TEMP ('OneDriveCloudWatcher-LiveTest-' + [guid]::NewGuid().ToString('N'))
$source = Join-Path $testRoot 'source'
$testConfigPath = Join-Path $testRoot 'config.json'
$testStatePath = Join-Path $testRoot 'state.json'
$testStopPath = Join-Path $testRoot 'stop'
$fileName = 'OneDriveSyncMonitor-WatcherTest-' + [guid]::NewGuid().ToString('N') + '.txt'
$testItemId = ''
$testDriveId = ''
$watchProcess = $null

try {
    New-Item -ItemType Directory -Path $source -Force | Out-Null
    . (Join-Path $PSScriptRoot 'OneDriveCloudBackup.ps1') -LoadFunctionsOnly -ConfigPath $CloudConfigPath -StatePath $testStatePath
    $realConfig = Get-CloudConfig
    Connect-CloudGraph -Config $realConfig
    $testDriveId = [string]$realConfig.DriveId
    $testConfig = [ordered]@{ SourceRoot = $source; DriveId = $testDriveId; Account = $realConfig.Account; TenantId = $realConfig.TenantId }
    $testConfig | ConvertTo-Json | Set-Content -LiteralPath $testConfigPath -Encoding UTF8

    $powerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $cloudScript = Join-Path $PSScriptRoot 'OneDriveCloudBackup.ps1'
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $cloudScript,
        '-ConfigPath', $testConfigPath, '-StatePath', $testStatePath, '-StopPath', $testStopPath, '-NoAlerts')
    $stderrPath = Join-Path $testRoot 'watcher.err'
    $stdoutPath = Join-Path $testRoot 'watcher.out'
    $watchProcess = Start-Process -FilePath $powerShell -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardError $stderrPath -RedirectStandardOutput $stdoutPath
    Start-Sleep -Seconds 3
    $watchProcess.Refresh()
    if ($watchProcess.HasExited) { throw "Watcher exited early: $(Get-Content -LiteralPath $stderrPath -Raw)" }

    $filePath = Join-Path $source $fileName
    Set-Content -LiteralPath $filePath -Value 'Created after watcher start.' -Encoding UTF8
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    $firstRemote = $null
    while ([DateTime]::UtcNow -lt $deadline) {
        $watchProcess.Refresh()
        if ($watchProcess.HasExited) { throw "Watcher exited before upload: $(Get-Content -LiteralPath $stderrPath -Raw)" }
        $firstRemote = Get-RemoteItem -DriveId $testDriveId -RelativePath $fileName
        if ($null -ne $firstRemote -and $firstRemote.id) { break }
        Start-Sleep -Seconds 2
    }
    if ($null -eq $firstRemote -or -not $firstRemote.id) { throw 'Watcher did not upload a newly saved file within 60 seconds.' }
    $testItemId = [string]$firstRemote.id
    Write-Host 'PASS: a save event uploaded the new file without a full scan.'

    Set-Content -LiteralPath $filePath -Value 'Updated after watcher start.' -Encoding UTF8
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    $secondRemote = $null
    while ([DateTime]::UtcNow -lt $deadline) {
        $watchProcess.Refresh()
        if ($watchProcess.HasExited) { throw "Watcher exited before update: $(Get-Content -LiteralPath $stderrPath -Raw)" }
        $secondRemote = Get-RemoteItem -DriveId $testDriveId -RelativePath $fileName
        if ($null -ne $secondRemote -and $secondRemote.eTag -ne $firstRemote.eTag) { break }
        Start-Sleep -Seconds 2
    }
    if ($null -eq $secondRemote -or $secondRemote.eTag -eq $firstRemote.eTag) { throw 'Watcher did not update the existing cloud file within 60 seconds.' }
    Write-Host 'PASS: a later save updated the same cloud item.'
}
finally {
    if ($watchProcess) {
        Set-Content -LiteralPath $testStopPath -Value 'stop' -Encoding ASCII
        try { Wait-Process -Id $watchProcess.Id -Timeout 35 -ErrorAction Stop }
        catch { Stop-Process -Id $watchProcess.Id -Force -ErrorAction SilentlyContinue }
    }
    if ($testItemId -and $testDriveId -and $fileName -like 'OneDriveSyncMonitor-WatcherTest-*.txt') {
        try { Invoke-CloudGraph -Method DELETE -Uri ('https://graph.microsoft.com/v1.0/drives/{0}/items/{1}' -f [Uri]::EscapeDataString($testDriveId), [Uri]::EscapeDataString($testItemId)) | Out-Null }
        catch { Write-Warning "Could not remove cloud test file $fileName`: $($_.Exception.Message)" }
    }
    if (Test-Path -LiteralPath $testRoot) {
        $resolved = (Resolve-Path -LiteralPath $testRoot).Path
        $resolvedTemp = (Resolve-Path -LiteralPath $env:TEMP).Path.TrimEnd('\')
        if (-not $resolved.StartsWith($resolvedTemp + '\OneDriveCloudWatcher-LiveTest-', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to delete unexpected test folder: $resolved"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
