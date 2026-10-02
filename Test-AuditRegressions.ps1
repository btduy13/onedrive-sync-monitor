[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:TEMP ('MonitorRegression-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
function Assert-Regression($Condition, $Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Host "PASS: $Message"
}
& {
    $source = Join-Path $root 'source'
    New-Item -ItemType Directory -Path $source | Out-Null
    . (Join-Path $PSScriptRoot 'OneDriveCloudBackup.ps1') -LoadFunctionsOnly -StatePath (Join-Path $root 'cloud.json')
    function Write-CloudLog { param($Message) }
    function Get-RemoteItem { param($DriveId,$RelativePath); $script:remote }
    function Test-RemoteMatchesLocal { param($DriveId,$RemoteItem,$LocalPath); $script:compared++; $script:matches }
    function Send-CloudFile { param($DriveId,$RelativePath,$LocalPath,$RemoteItem); $script:uploads++; @{eTag='uploaded'} }
    $config = @{SourceRoot=$source; DriveId='offline'}
    Set-Content (Join-Path $source 'a.txt') 'local edit'
    $script:remote = @{id='remote'; eTag='new'; file=@{}}
    $script:uploads=0; $script:compared=0; $script:matches=$true
    $state=Read-CloudState
    $state.Files['a.txt']=@{Signature='old'; ETag='old'}
    Save-CloudState $state
    $r=Invoke-CloudScan $config -RelativePaths @('a.txt')
    Assert-Regression ($r.Adopted -eq 1 -and $r.Failed -eq 0 -and $script:compared -eq 1 -and $script:uploads -eq 0) 'Native sync of identical content is adopted, not a conflict'
    $state=Read-CloudState
    $state.Files['a.txt']=@{Signature='old'; ETag=''}
    Save-CloudState $state
    $script:matches=$false
    $r=Invoke-CloudScan $config -RelativePaths @('a.txt')
    Assert-Regression ($r.Failed -eq 1 -and $r.Adopted -eq 0 -and $script:uploads -eq 0) 'Blank ETag never silently adopts different content'
    Assert-Regression ((Read-CloudState).Files['a.txt'].Signature -eq 'old') 'Conflict remains pending for review'
    $script:remote=$null
    New-Item -ItemType Directory -Path (Join-Path $source 'moved') | Out-Null
    Set-Content (Join-Path $source 'moved\child.txt') 'child'
    $r=Invoke-CloudScan $config -RelativePaths @('moved')
    Assert-Regression ($r.Uploaded -eq 1 -and $r.Failed -eq 0) 'Directory event scans local children'
    Set-Content (Join-Path $source 'moved\child.txt') 'changed while stopped'
    $paths=@(Get-CloudReconciliationPaths $config (Read-CloudState))
    Assert-Regression ($paths -contains 'moved\child.txt' -and $paths -contains 'a.txt') 'Reconciliation finds offline edits and unresolved files'
    Assert-Regression (-not (Test-LocalContentPresent ([pscustomobject]@{Attributes=0;LinkType='SymbolicLink'}))) 'File symlinks cannot upload content outside source'
}
& {
    . (Join-Path $PSScriptRoot 'OneDriveSyncMonitor.ps1') -LoadFunctionsOnly -StatePath (Join-Path $root 'monitor.json') -LogPath (Join-Path $root 'monitor.log')
    function Test-Path { param($LiteralPath); $true }
    function Get-Item { param($LiteralPath); @{LastWriteTimeUtc=[DateTime]::UtcNow} }
    function Read-KeyValueLog { param($Path); throw 'Unreadable' }
    $snapshot=Get-AccountSnapshot ([pscustomobject]@{Name='Business1';Root='C:\fixture';Properties=@{GetOnlineStatus='Completed';LastSignInResult='0'}})
    $issues=@()
    Add-AccountIssues $snapshot $null 30 15 ([ref]$issues)
    Assert-Regression ((Get-HealthStatus $issues) -ne 'Healthy') 'Unreadable diagnostics cannot report Healthy'
}
& {
    . (Join-Path $PSScriptRoot 'OneDriveSyncMonitor.ps1') -LoadFunctionsOnly -StatePath (Join-Path $root 'recovery-monitor.json') -LogPath (Join-Path $root 'recovery.log')
    function Test-Path {
        param($LiteralPath, $PathType)
        if ($LiteralPath -like '*OneDrive.exe') { return $true }
        Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath
    }
    function Get-AuthenticodeSignature { param($LiteralPath); @{Status=$script:signatureStatus;SignerCertificate=@{Subject='CN=Microsoft Corporation, O=Microsoft Corporation, C=US'}} }
    function Start-Process { param($FilePath,$ArgumentList,$WindowStyle,$ErrorAction); $script:starts++ }
    $script:starts=0; $script:signatureStatus='NotSigned'
    $result=@{Issues=@(@{Code='Process.Stopped'})}
    Invoke-SafeOneDriveRecovery $result @{SafeRecoveryEnabled=$true}
    Assert-Regression ($script:starts -eq 0) 'Recovery rejects unsigned executables'
    $script:signatureStatus='Valid'
    Invoke-SafeOneDriveRecovery $result @{SafeRecoveryEnabled=$true}
    Invoke-SafeOneDriveRecovery $result @{SafeRecoveryEnabled=$true}
    Assert-Regression ($script:starts -eq 1) 'Safe start is limited to once per 30 minutes'
    Invoke-SafeOneDriveRecovery $result @{SafeRecoveryEnabled=$false}
    Assert-Regression ($script:starts -eq 1) 'Disabled recovery never starts OneDrive'
}
Write-Host "Fixtures retained: $root; no network or installed configuration changes."
