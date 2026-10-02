[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$testRoot = Join-Path $env:TEMP ('OneDriveBidirectionalRepair-' + [guid]::NewGuid().ToString('N'))
$source = Join-Path $testRoot 'source'
$statePath = Join-Path $testRoot 'state.json'
New-Item -ItemType Directory -Path $source -Force | Out-Null

function Assert-RepairTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Host "PASS: $Message"
}

try {
    . (Join-Path $PSScriptRoot 'OneDriveCloudBackup.ps1') -LoadFunctionsOnly -StatePath $statePath
    $config = [pscustomobject]@{ SourceRoot = $source; DriveId = 'drive-test'; SyncMode = 'BidirectionalRepair' }
    $script:remote = @{}
    $script:remoteContent = @{}
    $script:uploadCount = 0
    $script:pullCount = 0

    function Set-RepairRemote {
        param([string]$Path, [string]$Text, [string]$ETag)
        $script:remoteContent[$Path] = $Text
        $script:remote[$Path] = [pscustomobject]@{
            id = 'id-' + $Path.Replace('\', '-'); eTag = $ETag; file = @{}; size = [Text.Encoding]::UTF8.GetByteCount($Text); name = (Split-Path -Leaf $Path)
        }
    }
    function Get-RemoteItem { param([string]$DriveId, [string]$RelativePath) $script:remote[$RelativePath] }
    function Send-CloudFile {
        param([string]$DriveId, [string]$RelativePath, [string]$LocalPath, $RemoteItem, [switch]$CreateOnly)
        if($CreateOnly -and $null -ne $RemoteItem){throw 'Create-only sent an existing item'}
        if($CreateOnly -and ($script:remote.ContainsKey($RelativePath) -or $RelativePath -eq $script:raceCreatePath)){throw 'Cloud name already exists.'}
        $script:lastCreateOnly=[bool]$CreateOnly
        $script:uploadCount++
        Set-RepairRemote -Path $RelativePath -Text ([IO.File]::ReadAllText($LocalPath)) -ETag ('push-' + $script:uploadCount)
        return $script:remote[$RelativePath]
    }
    function Save-CloudRemoteContent {
        param([string]$DriveId, $RemoteItem, [string]$LocalPath)
        if($DriveId -ne 'drive-test'){throw 'Missing or wrong drive ID at download boundary.'}
        $path = @($script:remote.Keys | Where-Object { $script:remote[$_].id -eq $RemoteItem.id })[0]
        [IO.File]::WriteAllText($LocalPath, [string]$script:remoteContent[$path])
        $script:pullCount++
    }
    function Test-RemoteMatchesLocal {
        param([string]$DriveId, $RemoteItem, [string]$LocalPath)
        $path = @($script:remote.Keys | Where-Object { $script:remote[$_].id -eq $RemoteItem.id })[0]
        return [IO.File]::ReadAllText($LocalPath) -ceq [string]$script:remoteContent[$path]
    }
    function Write-CloudLog { param([string]$Message) }

    function Set-RepairBaseline {
        param([string]$Path)
        $file = Get-Item -LiteralPath (Join-Path $source $Path)
        $state = Read-CloudState
        $state.Files[$Path] = New-CloudFileStateEntry -Signature (Get-CloudLocalSignature -Item $file) -RemoteItem $script:remote[$Path] -ContentHash ((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash)
        Save-CloudState -State $state
    }

    [IO.File]::WriteAllText((Join-Path $source 'push.txt'), 'base')
    Set-RepairRemote 'push.txt' 'base' 'etag-push-base'
    Set-RepairBaseline 'push.txt'
    [IO.File]::WriteAllText((Join-Path $source 'push.txt'), 'local-newer')
    $result = Invoke-CloudPathRepair -Config $config -RelativePath 'push.txt'
    Assert-RepairTest ($result.Pushed -eq 1 -and $result.Pulled -eq 0 -and $result.Failed -eq 0) 'Local-only change is pushed to cloud'
    Assert-RepairTest ($script:remoteContent['push.txt'] -eq 'local-newer') 'Push preserves the same relative path and content'

    [IO.File]::WriteAllText((Join-Path $source 'same-size.txt'), 'AAAA')
    Set-RepairRemote 'same-size.txt' 'AAAA' 'etag-size'
    Set-RepairBaseline 'same-size.txt'
    $stamp=(Get-Item (Join-Path $source 'same-size.txt')).LastWriteTimeUtc
    [IO.File]::WriteAllText((Join-Path $source 'same-size.txt'), 'BBBB')
    (Get-Item (Join-Path $source 'same-size.txt')).LastWriteTimeUtc=$stamp
    $result=Invoke-CloudPathRepair -Config $config -RelativePath 'same-size.txt'
    Assert-RepairTest ($result.Pushed -eq 1) 'Content changes with preserved size and timestamp are detected during repair'

    [IO.File]::WriteAllText((Join-Path $source 'pull.txt'), 'base')
    Set-RepairRemote 'pull.txt' 'base' 'etag-pull-base'
    Set-RepairBaseline 'pull.txt'
    Set-RepairRemote 'pull.txt' 'cloud-newer' 'etag-pull-newer'
    $result = Invoke-CloudPathRepair -Config $config -RelativePath 'pull.txt'
    Assert-RepairTest ($result.Pulled -eq 1 -and $result.Pushed -eq 0 -and $result.Failed -eq 0) 'Cloud-only change is pulled to local'
    Assert-RepairTest ([IO.File]::ReadAllText((Join-Path $source 'pull.txt')) -eq 'cloud-newer') 'Pull replaces only a verified unchanged local file'

    [IO.File]::WriteAllText((Join-Path $source 'conflict.txt'), 'base')
    Set-RepairRemote 'conflict.txt' 'base' 'etag-conflict-base'
    Set-RepairBaseline 'conflict.txt'
    [IO.File]::WriteAllText((Join-Path $source 'conflict.txt'), 'local-conflict')
    Set-RepairRemote 'conflict.txt' 'cloud-conflict' 'etag-conflict-newer'
    $uploadsBeforeConflict = $script:uploadCount
    $result = Invoke-CloudPathRepair -Config $config -RelativePath 'conflict.txt'
    Assert-RepairTest ($result.Failed -eq 1 -and $script:uploadCount -eq $uploadsBeforeConflict) 'Both-sided change is never overwritten automatically'
    Assert-RepairTest ([IO.File]::ReadAllText((Join-Path $source 'conflict.txt')) -eq 'local-conflict') 'Conflict keeps local content intact'

    [IO.File]::WriteAllText((Join-Path $source 'native.txt'), 'base')
    Set-RepairRemote 'native.txt' 'base' 'etag-native-base'
    Set-RepairBaseline 'native.txt'
    [IO.File]::WriteAllText((Join-Path $source 'native.txt'), 'same-content')
    Set-RepairRemote 'native.txt' 'same-content' 'etag-native-newer'
    $result = Invoke-CloudPathRepair -Config $config -RelativePath 'native.txt'
    Assert-RepairTest ($result.Adopted -eq 1 -and $result.Failed -eq 0) 'Matching native OneDrive change is adopted without duplicate transfer'

    [IO.File]::WriteAllText((Join-Path $source 'deleted-local.txt'), 'base')
    Set-RepairRemote 'deleted-local.txt' 'base' 'etag-delete-base'
    Set-RepairBaseline 'deleted-local.txt'
    Remove-Item -LiteralPath (Join-Path $source 'deleted-local.txt')
    $result = Invoke-CloudPathRepair -Config $config -RelativePath 'deleted-local.txt'
    Assert-RepairTest ($result.Failed -eq 1 -and -not (Test-Path -LiteralPath (Join-Path $source 'deleted-local.txt'))) 'A local deletion is never silently reversed'
    $deletionPaths = @(Get-CloudReconciliationPaths -Config $config -State (Read-CloudState) -KnownOnly)
    Assert-RepairTest ($deletionPaths -contains 'deleted-local.txt') 'Reconciliation reports a missing known local file for review'

    [IO.File]::WriteAllText((Join-Path $source 'new-local.txt'),'new local content')
    $result=Invoke-CloudPathRepair -Config $config -RelativePath 'new-local.txt' -AutoCreateIfRemoteMissing
    Assert-RepairTest ($result.Pushed -eq 1 -and $result.Failed -eq 0 -and $script:lastCreateOnly -and $script:remoteContent['new-local.txt'] -eq 'new local content') 'A local-only file is created with create-only upload when enabled'
    Assert-RepairTest (Test-CloudVerifiedBaseline -Entry (Read-CloudState).Files['new-local.txt']) 'Created cloud file receives a verified baseline'

    [IO.File]::WriteAllText((Join-Path $source 'race.txt'),'local wins only if cloud remains absent')
    $script:raceCreatePath='race.txt'
    $uploadsBeforeRace=$script:uploadCount
    $result=Invoke-CloudPathRepair -Config $config -RelativePath 'race.txt' -AutoCreateIfRemoteMissing
    Assert-RepairTest ($result.Failed -eq 1 -and $script:uploadCount -eq $uploadsBeforeRace -and -not (Read-CloudState).Files.ContainsKey('race.txt')) 'A cloud creation race fails closed without recording a baseline'
    $script:raceCreatePath=''

    Set-RepairRemote 'unknown-cloud.txt' 'cloud-only' 'etag-unknown'
    $result = Invoke-CloudPathRepair -Config $config -RelativePath 'unknown-cloud.txt'
    Assert-RepairTest ($result.Failed -eq 1 -and -not (Test-Path -LiteralPath (Join-Path $source 'unknown-cloud.txt'))) 'Unknown cloud-only content is not bulk-downloaded'

    [IO.File]::WriteAllText((Join-Path $source 'legacy.txt'), 'legacy-local')
    Set-RepairRemote 'legacy.txt' 'legacy-cloud' 'etag-legacy-newer'
    $legacyFile = Get-Item -LiteralPath (Join-Path $source 'legacy.txt')
    $state = Read-CloudState
    $state.Files['legacy.txt'] = @{ Signature = (Get-CloudLocalSignature -Item $legacyFile); ETag = 'etag-legacy-old' }
    Save-CloudState -State $state
    $result = Invoke-CloudPathRepair -Config $config -RelativePath 'legacy.txt'
    Assert-RepairTest ($result.Failed -eq 1 -and [IO.File]::ReadAllText((Join-Path $source 'legacy.txt')) -eq 'legacy-local') 'A legacy unverified baseline cannot trigger an automatic overwrite'

    [IO.File]::WriteAllText((Join-Path $source 'manual-local.txt'), 'local-authoritative')
    Set-RepairRemote 'manual-local.txt' 'cloud-stale' 'etag-manual-local'
    $result = Invoke-CloudPathRepair -Config $config -RelativePath 'manual-local.txt' -ResolveWith Local
    Assert-RepairTest ($result.Pushed -eq 1 -and $result.Failed -eq 0 -and $script:remoteContent['manual-local.txt'] -eq 'local-authoritative') 'Explicit local resolution pushes one selected unverified file'
    $state = Read-CloudState
    Assert-RepairTest (Test-CloudVerifiedBaseline -Entry $state.Files['manual-local.txt']) 'Explicit local resolution records a verified baseline'

    [IO.File]::WriteAllText((Join-Path $source 'manual-cloud.txt'), 'local-stale')
    Set-RepairRemote 'manual-cloud.txt' 'cloud-authoritative' 'etag-manual-cloud'
    $result = Invoke-CloudPathRepair -Config $config -RelativePath 'manual-cloud.txt' -ResolveWith Cloud
    Assert-RepairTest ($result.Pulled -eq 1 -and $result.Failed -eq 0 -and [IO.File]::ReadAllText((Join-Path $source 'manual-cloud.txt')) -eq 'cloud-authoritative') 'Explicit cloud resolution pulls one selected unverified file'

    function Invoke-CloudGraph {
        param([string]$Method, [string]$Uri)
        return [pscustomobject]@{
            value = @([pscustomobject]@{ id = $script:remote['pull.txt'].id; name = 'pull.txt'; eTag = 'etag-pull-newer'; file = @{}; parentReference = @{ path = '/drives/drive-test/root:' } })
            '@odata.deltaLink' = 'https://graph.example.test/delta-token'
        }
    }
    $paths = @(Get-CloudRemoteChangedPaths -Config $config)
    $state = Read-CloudState
    Assert-RepairTest ($paths -contains 'pull.txt') 'Remote delta finds a changed known file without scanning unknown files'
    Assert-RepairTest ($state.RemoteDeltaLink -eq 'https://graph.example.test/delta-token') 'Remote delta cursor is persisted for the next repair cycle'
    Assert-RepairTest ($state.PendingPaths -contains 'pull.txt') 'Delta cursor and pending work are persisted together'
    Assert-RepairTest (Test-CloudBidirectionalRepairEnabled -Config $config) 'Bidirectional repair requires an explicit configured mode'
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
