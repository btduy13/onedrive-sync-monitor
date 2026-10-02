$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'MultiLibrarySync.ps1') -LoadFunctionsOnly
function Assert-Multi($Ok,$Text){if(-not $Ok){throw "FAIL: $Text"}; Write-Host "PASS: $Text"}
Assert-Multi ((Get-LibraryWorkStatus -ErrorCount 0 -Pending 0 -Tracked 0 -ScanRemainingFolders 5) -eq 'Scanning') 'An unfinished initial scan is not mislabeled as missing baseline'
Assert-Multi ((Get-LibraryWorkStatus -ErrorCount 0 -Pending 0 -Tracked 0 -ScanRemainingFolders 0) -eq 'BaselineRequired') 'No scanned file after a completed pass still needs a baseline'
Assert-Multi ((Get-LibraryWorkStatus -ErrorCount 1 -Pending 3 -Tracked 0 -ScanRemainingFolders 5) -eq 'NeedsReview') 'A real file error takes priority over scan progress'
function Test-CompanyBackupSafePath {param($Path,$AccountRoots) return $true}
$tenant='11111111-1111-1111-1111-111111111111'
$e=[pscustomobject]@{Accounts=@([pscustomobject]@{TenantId=$tenant;Account='a@test';UserFolder='C:\Company';Scopes=@{a='C:\Projects';b='D:\Estimate'}});Providers=@(
    [pscustomobject]@{ScopeId='a';MountPoint='C:\Projects';UrlNamespace='https://test.sharepoint.com/sites/P/Docs';TenantIds=@()},
    [pscustomobject]@{ScopeId='b';MountPoint='D:\Estimate';UrlNamespace='https://test.sharepoint.com/sites/E/Docs';TenantIds=@()})}
$rows=@(Get-SyncMappings -Evidence $e)
Assert-Multi ($rows.Count -eq 2 -and @($rows | Where-Object Status -eq Discovered).Count -eq 2) 'Discovers two arbitrary libraries without Design constants'
Assert-Multi ($rows[0].Id -ne $rows[1].Id) 'Different libraries have different state namespaces'
$again=@(Get-SyncMappings -Evidence $e)
Assert-Multi ($rows[0].Id -eq $again[0].Id) 'Mapping identity remains stable across restarts'
$e.Providers[1].TenantIds=@('22222222-2222-2222-2222-222222222222')
$rows=@(Get-SyncMappings -Evidence $e)
Assert-Multi (@($rows | Where-Object Status -eq MappingConflict).Count -eq 1) 'Conflicting tenant blocks only the affected library'
$e.Providers[1].TenantIds=@(); $e.Providers[1].MountPoint='C:\Wrong'
Assert-Multi (@(Get-SyncMappings -Evidence $e | Where-Object Status -eq MappingUnverified).Count -eq 1) 'Scope ID alone cannot authenticate a different mount'
$testRoot=Join-Path $env:TEMP ('MultiLibraryTest-'+[guid]::NewGuid().ToString('N'))
try {
    function Resolve-SyncLibrary {param($Mapping) throw 'AuthenticationRequired'}
    $r=Invoke-LibraryCycle -Mapping $again[0] -Root $testRoot
    Assert-Multi ($r.Status -eq 'Blocked' -and (Test-Path (Join-Path $testRoot ($r.Id+'\status.json')))) 'Authentication failure is persisted per library'
    function Resolve-SyncLibrary {param($Mapping)
        if($Mapping.Id -eq $again[0].Id){throw 'Denied'}
        return [pscustomobject]@{DriveId='drive-two';Account='a@test';TenantId=$tenant}
    }
    $results=@(foreach($mapping in $again){Invoke-LibraryCycle -Mapping $mapping -Root $testRoot})
    Assert-Multi ($results[0].Status -eq 'Blocked' -and $results[1].Status -eq 'ReadVerified_WriteNotVerified') 'One denied library does not block a readable library'
    $secondStatus=Get-Content (Join-Path $testRoot ($again[1].Id+'\status.json')) -Raw | ConvertFrom-Json
    Assert-Multi ($secondStatus.Status -eq 'ReadVerified_WriteNotVerified') 'Read-only verification status is persisted on early return'
    Assert-Multi (-not(Test-Path (Join-Path $testRoot ($again[1].Id+'\permission.json')))) 'Read access never implies verified write access'
    function Test-LibraryWriteAccess {param($Target,$Folder) return [pscustomobject]@{DriveId=$Target.DriveId;Account=$Target.Account;TenantId=$Target.TenantId}}
    function Get-CloudReconciliationPaths {throw 'Verification must not scan production files'}
    $verified=Invoke-LibraryCycle -Mapping $again[1] -Root $testRoot -CheckWrite
    Assert-Multi ($verified.Status -eq 'WriteVerified') 'Write probe does not trigger a production repair cycle'
    $localRoot=Join-Path $testRoot 'source'
    New-Item -ItemType Directory -Path $localRoot | Out-Null
    $scanFolder=Join-Path $testRoot 'scan-one';New-Item -ItemType Directory -Path $scanFolder | Out-Null
    [IO.File]::WriteAllText((Join-Path $localRoot 'first.txt'),'a')
    [IO.File]::WriteAllText((Join-Path $localRoot 'second.txt'),'b')
    $scanTarget=[pscustomobject]@{SourceRoot=$localRoot}
    $scanState=@{Files=@{}}
    $found=@()
    for($i=0;$i -lt 3;$i++){$found+=@(Get-LibraryLocalChangedPaths -Target $scanTarget -Folder $scanFolder -State $scanState -MaxEntries 1)}
    Assert-Multi ('first.txt' -in $found -and 'second.txt' -in $found) 'Bounded local scan resumes where the previous cycle stopped'
    $watchId='aaaaaaaaaaaaaaaaaaaaaaaa'
    $watchMap=[pscustomobject]@{Id=$watchId;Status='Discovered';SourceRoot=$localRoot}
    $watchers=@{}
    Register-LibraryWatchers -Mappings @($watchMap) -Watchers $watchers
    try{
        [IO.File]::WriteAllText((Join-Path $localRoot 'event.txt'),'new')
        $deadline=[datetime]::UtcNow.AddSeconds(3)
        do{Start-Sleep -Milliseconds 100;Add-LibraryFileEvents -Root $testRoot -Watchers $watchers;$queued=@((Read-CloudState -Path (Join-Path $testRoot "$watchId\state.json")).PendingPaths)}while('event.txt' -notin $queued -and [datetime]::UtcNow -lt $deadline)
        Assert-Multi ($queued.Count -gt 0 -and $queued[0] -eq 'event.txt') 'New file event moves to the front of its library queue'
    }finally{
        foreach($kind in @('Changed','Created','Deleted','Renamed','Error')){Unregister-Event -SourceIdentifier "OneDriveMultiLibrarySync.$watchId.$kind" -ErrorAction SilentlyContinue}
        $watchers[$watchId].Watcher.Dispose()
    }
} finally {
    if(Test-Path $testRoot){
        $resolved=[IO.Path]::GetFullPath($testRoot)
        if(-not $resolved.StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\MultiLibraryTest-')){throw 'Unsafe fixture path'}
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
