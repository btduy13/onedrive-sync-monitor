[CmdletBinding()]
param(
    [switch]$DiscoverOnly, [switch]$Once, [switch]$Enable, [switch]$Disable,
    [switch]$VerifyWrite, [switch]$Authenticate, [switch]$LoadFunctionsOnly,
    [string]$DataRoot = (Join-Path $env:LOCALAPPDATA 'OneDriveSyncMonitor\libraries'),
    [string]$LibraryId = ''
)
$ErrorActionPreference = 'Stop'
$multiArguments = @{DiscoverOnly=$DiscoverOnly; Once=$Once; Enable=$Enable; Disable=$Disable; VerifyWrite=$VerifyWrite; Authenticate=$Authenticate; LoadFunctionsOnly=$LoadFunctionsOnly; DataRoot=$DataRoot; LibraryId=$LibraryId}
. (Join-Path $PSScriptRoot 'Find-CompanyBackupSource.ps1') -LoadFunctionsOnly
. (Join-Path $PSScriptRoot 'OneDriveCloudBackup.ps1') -LoadFunctionsOnly
foreach($argumentName in $multiArguments.Keys){Set-Variable -Name $argumentName -Value $multiArguments[$argumentName]}

function Get-SyncMappings {
    param($Evidence = (Get-CompanyBackupRegistryEvidence))
    $rows = @{}; $roots = @($Evidence.Accounts | ForEach-Object { $_.UserFolder })
    foreach ($provider in $Evidence.Providers) {
        $url = ConvertTo-CompanyBackupUrl $provider.UrlNamespace
        $root = ConvertTo-CompanyBackupPath $provider.MountPoint
        if (-not $url -or -not $root) { continue }
        $owners = @($Evidence.Accounts | Where-Object {
            $_.Scopes.ContainsKey($provider.ScopeId) -and
            (ConvertTo-CompanyBackupPath ([string]$_.Scopes[$provider.ScopeId])) -ieq $root
        })
        $tenantIds = @($owners | ForEach-Object { ConvertTo-CompanyBackupTenant $_.TenantId } | Select-Object -Unique)
        $kind = if (([uri]$url).AbsolutePath -like '/personal/*') { 'OneDriveBusiness' } else { 'SharePoint' }
        $status = 'Discovered'
        if ($owners.Count -eq 0 -or $tenantIds.Count -ne 1 -or -not $tenantIds[0]) { $status = 'MappingUnverified' }
        foreach ($tenant in @($provider.TenantIds)) {
            if ((ConvertTo-CompanyBackupTenant $tenant) -ne $tenantIds[0]) { $status = 'MappingConflict' }
        }
        $blockedRoots = if ($kind -eq 'OneDriveBusiness') { @($roots | Where-Object { $_ -ine $root }) } else { $roots }
        if (-not (Test-CompanyBackupSafePath -Path $root -AccountRoots $blockedRoots)) { $status = 'SourceUnavailable' }
        $key = $url + '|' + $root.ToLowerInvariant()
        if ($rows.ContainsKey($key)) { continue }
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $id = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($key)))).Replace('-','').ToLowerInvariant().Substring(0,24) }
        finally { $sha.Dispose() }
        $rows[$key] = [pscustomobject]@{ Id=$id; Name=(Split-Path $root -Leaf); SourceRoot=$root;
            LibraryWebUrl=$url; TenantId=($tenantIds | Select-Object -First 1);
            Account=($owners | Select-Object -First 1).Account; Kind=$kind; Status=$status }
    }
    $all = @($rows.Values)
    foreach ($row in $all) {
        foreach ($other in $all) {
            if ($row.Id -eq $other.Id) { continue }
            if ($row.SourceRoot -ieq $other.SourceRoot -or $row.SourceRoot.StartsWith($other.SourceRoot+'\',[StringComparison]::OrdinalIgnoreCase) -or
                ($row.LibraryWebUrl -eq $other.LibraryWebUrl -and $row.SourceRoot -ine $other.SourceRoot)) { $row.Status='MappingConflict' }
        }
    }
    return @($all | Sort-Object SourceRoot)
}

function Save-LibraryJson {
    param($Value,[string]$Path)
    New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
    $tmp = $Path + '.tmp'
    $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Resolve-SyncLibrary {
    param($Mapping)
    $target = [pscustomobject]@{ TargetType=$Mapping.Kind; AuthMode='Delegated'; Account=$Mapping.Account;
        TenantId=$Mapping.TenantId; SourceRoot=$Mapping.SourceRoot; LibraryWebUrl=$Mapping.LibraryWebUrl;
        SyncMode='BidirectionalRepair'; DriveId=''; SiteId='' }
    Connect-CloudGraph -Config $target -UseCachedAuthentication
    if ($Mapping.Kind -eq 'SharePoint') {
        $location = Get-SharePointLibraryLocation -Url ($Mapping.LibraryWebUrl+'/Forms/AllItems.aspx')
        $drive = Resolve-SharePointLibraryDrive -Location $location
        $target.DriveId=$drive.DriveId; $target.SiteId=$drive.SiteId
    } else {
        $drive = Invoke-CloudGraph -Method GET -Uri 'https://graph.microsoft.com/v1.0/me/drive'
        if ((ConvertTo-CompanyBackupUrl $drive.webUrl) -ne $Mapping.LibraryWebUrl) { throw 'Cloud drive URL differs from the registered local mapping.' }
        $target.DriveId=$drive.id
    }
    if (-not $target.DriveId) { throw 'No verified cloud drive.' }
    return $target
}

function Test-LibraryWriteAccess {
    param($Target,[string]$Folder)
    # A unique non-sensitive probe is the evidence of actual write access, not token scope alone.
    $name = 'OneDriveMonitor-PermissionProbe-'+[guid]::NewGuid().ToString('N')+'.txt'
    $file = Join-Path $Folder $name
    [IO.File]::WriteAllText($file,('OneDrive Monitor permission check '+[DateTime]::UtcNow.ToString('o')))
    $result=Send-CloudFile -DriveId $Target.DriveId -RelativePath $name -LocalPath $file -RemoteItem $null
    if (-not (Test-RemoteMatchesLocal -DriveId $Target.DriveId -RemoteItem $result -LocalPath $file)) { throw 'Write/readback probe failed.' }
    return [pscustomobject]@{ DriveId=$Target.DriveId; Account=$Target.Account; TenantId=$Target.TenantId; Probe=$name; VerifiedUtc=[DateTime]::UtcNow.ToString('o') }
}

function Test-LibraryIgnoredPath {
    param([string]$Path)
    $leaf=Split-Path $Path -Leaf
    return ($leaf -ieq 'desktop.ini' -or $leaf -match '^\.[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
}

function Get-LibraryLocalChangedPaths {
    param($Target,[string]$Folder,$State,[int]$MaxEntries=100,[int]$MaxSeconds=8)
    $scanFile=Join-Path $Folder 'scan.json'
    $scan=if(Test-Path $scanFile){Get-Content $scanFile -Raw | ConvertFrom-Json}else{[pscustomobject]@{Queue=@('');Index=0;KnownIndex=0}}
    $queue=New-Object 'System.Collections.Generic.List[string]'
    foreach($part in @($scan.Queue)){$queue.Add([string]$part)}
    if($queue.Count -eq 0){$queue.Add('');$scan.Index=0}
    $changed=New-Object 'System.Collections.Generic.List[string]'
    $count=0; $until=[DateTime]::UtcNow.AddSeconds($MaxSeconds)
    $cachedRelative=$null;$cachedEntries=@()
    while($queue.Count -gt 0 -and $count -lt $MaxEntries -and [DateTime]::UtcNow -lt $until){
        $relative=[string]$queue[0]
        $directory=if($relative){Resolve-CloudLocalFilePath -Config $Target -RelativePath $relative}else{$Target.SourceRoot}
        if(-not(Test-Path -LiteralPath $directory -PathType Container)){$queue.RemoveAt(0);$scan.Index=0;continue}
        if($relative){Confirm-CloudLocalParentPath -Config $Target -FullPath $directory}
        if($cachedRelative -cne $relative){$cachedEntries=@(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop | Sort-Object Name);$cachedRelative=$relative}
        if([int]$scan.Index -ge $cachedEntries.Count){$queue.RemoveAt(0);$scan.Index=0;$cachedRelative=$null;continue}
        $entry=$cachedEntries[[int]$scan.Index];$scan.Index=[int]$scan.Index+1;$count++
        $path=if($relative){$relative+'\'+$entry.Name}else{$entry.Name}
        if($entry.PSIsContainer){
            if(($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -or [string]::IsNullOrWhiteSpace([string]$entry.LinkType)){$queue.Add($path)}
            continue
        }
        if(-not(Test-LocalContentPresent -Item $entry) -or $entry.Name.StartsWith('~$') -or $entry.Name.EndsWith('.tmp') -or $entry.Name.StartsWith('.onedrive-sync-monitor') -or (Test-LibraryIgnoredPath $path)){continue}
        $previous=$State.Files[$path]
        $signature=Get-CloudLocalSignature -Item $entry
        if(-not $previous -or [string]$previous.Signature -ne $signature -or -not $previous.ETag){$changed.Add($path)}
    }
    $known=@($State.Files.Keys | Sort-Object)
    for($i=0;$i -lt [Math]::Min(5,$known.Count);$i++){
        $index=([int]$scan.KnownIndex+$i)%$known.Count
        $path=[string]$known[$index]
        $local=Resolve-CloudLocalFilePath -Config $Target -RelativePath $path
        if(-not(Test-Path -LiteralPath $local -PathType Leaf)){$changed.Add($path)}
        elseif(Test-LocalContentPresent -Item (Get-Item -LiteralPath $local -Force)){$changed.Add($path)}
    }
    if($known.Count){$scan.KnownIndex=([int]$scan.KnownIndex+[Math]::Min(5,$known.Count))%$known.Count}
    $scan.Queue=@($queue.ToArray());Save-LibraryJson $scan $scanFile
    return @($changed.ToArray() | Select-Object -Unique)
}

function Register-LibraryWatchers {
    param($Mappings,$Watchers)
    $active=@($Mappings | Where-Object Status -eq 'Discovered' | ForEach-Object Id)
    foreach($oldId in @($Watchers.Keys)){
        if($oldId -in $active){continue}
        foreach($kind in @('Changed','Created','Deleted','Renamed','Error')){Unregister-Event -SourceIdentifier ('OneDriveMultiLibrarySync.'+$oldId+'.'+$kind) -ErrorAction SilentlyContinue}
        $Watchers[$oldId].Watcher.Dispose();$Watchers.Remove($oldId) | Out-Null
    }
    foreach($mapping in @($Mappings | Where-Object Status -eq 'Discovered')){
        if($Watchers.ContainsKey($mapping.Id)){continue}
        $watcher=New-Object IO.FileSystemWatcher($mapping.SourceRoot)
        $watcher.IncludeSubdirectories=$true
        $watcher.NotifyFilter=[IO.NotifyFilters]'FileName, DirectoryName, LastWrite, Size'
        foreach($kind in @('Changed','Created','Deleted','Renamed','Error')){
            Register-ObjectEvent -InputObject $watcher -EventName $kind -SourceIdentifier ('OneDriveMultiLibrarySync.'+$mapping.Id+'.'+$kind) | Out-Null
        }
        $watcher.EnableRaisingEvents=$true
        $Watchers[$mapping.Id]=[pscustomobject]@{Watcher=$watcher;Root=$mapping.SourceRoot}
    }
}

function Add-LibraryFileEvents {
    param([string]$Root,$Watchers)
    foreach($event in @(Get-Event | Where-Object SourceIdentifier -Like 'OneDriveMultiLibrarySync.*')){
        try{
            $parts=$event.SourceIdentifier -split '\.'
            $id=$parts[1]
            if(-not $Watchers.ContainsKey($id)){continue}
            $source=$Watchers[$id].Root
            $stateFile=Join-Path (Join-Path $Root $id) 'state.json'
            $state=Read-CloudState -Path $stateFile
            if($parts[2] -eq 'Error'){
                $state.WatcherOverflow=$true
            }else{
                foreach($full in @($event.SourceEventArgs.FullPath,$event.SourceEventArgs.OldFullPath)){
                    if(-not $full -or -not $full.StartsWith($source+'\',[StringComparison]::OrdinalIgnoreCase)){continue}
                    $relative=$full.Substring($source.Length).TrimStart('\')
                    if(-not $relative -or (Test-LibraryIgnoredPath $relative)){continue}
                    if((Test-Path -LiteralPath $full -PathType Container) -and -not $state.Files.ContainsKey($relative)){continue}
                    $state.PendingPaths=@(@($state.PendingPaths)+@($relative)|Select-Object -Unique)
                }
            }
            Save-CloudState -State $state -Path $stateFile
        }finally{Remove-Event -EventIdentifier $event.EventIdentifier -ErrorAction SilentlyContinue}
    }
}

function Invoke-LibraryCycle {
    param($Mapping,[string]$Root,[switch]$CheckWrite)
    $folder=Join-Path $Root $Mapping.Id
    $report=[ordered]@{Id=$Mapping.Id; Name=$Mapping.Name; SourceRoot=$Mapping.SourceRoot; LibraryWebUrl=$Mapping.LibraryWebUrl;
        Status=$Mapping.Status; CheckedUtc=[DateTime]::UtcNow.ToString('o'); FilesTracked=0; Pending=0; Pushed=0; Pulled=0; Error=''}
    try {
        if($Mapping.Status -ne 'Discovered'){ return [pscustomobject]$report }
        $target=Resolve-SyncLibrary $Mapping
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        $configFile=Join-Path $folder 'config.json'
        if(Test-Path $configFile){
            $old=Get-Content $configFile -Raw | ConvertFrom-Json
            if($old.DriveId -ne $target.DriveId -or $old.TenantId -ne $target.TenantId){throw 'Resolved target changed; previous state retained for review.'}
        }
        Save-LibraryJson $target $configFile
        $permissionFile=Join-Path $folder 'permission.json'
        if($CheckWrite){
            Save-LibraryJson (Test-LibraryWriteAccess $target $folder) $permissionFile
            $report.Status='WriteVerified'; return [pscustomobject]$report
        }
        $permission=if(Test-Path $permissionFile){Get-Content $permissionFile -Raw | ConvertFrom-Json}else{$null}
        if(-not $permission -or $permission.DriveId -ne $target.DriveId -or $permission.Account -ne $target.Account -or $permission.TenantId -ne $target.TenantId){
            $report.Status='ReadVerified_WriteNotVerified'; return [pscustomobject]$report
        }
        # Dynamic scope isolates all existing repair/delta functions to this library's state file.
        $StatePath=Join-Path $folder 'state.json'
        $state=Read-CloudState
        # Discover local files for equality-only baseline acquisition; different copies stay conflicts.
        $paths=if(@($state.PendingPaths).Count -lt 100){@(Get-LibraryLocalChangedPaths -Target $target -Folder $folder -State $state -MaxEntries 30)}else{@()}
        $paths+=@(Get-CloudRemoteChangedPaths -Config $target -MaxPages 1)
        $state=Read-CloudState
        $paths=@(@($state.PendingPaths)+$paths | Select-Object -Unique)
        $state.PendingPaths=$paths; Save-CloudState $state
        $errors=New-Object 'System.Collections.Generic.List[string]'
        foreach($path in @($paths | Select-Object -First 10)){
            if(Test-LibraryIgnoredPath $path){$state=Read-CloudState;$state.PendingPaths=@($state.PendingPaths | Where-Object {$_ -ne $path});Save-CloudState $state;continue}
            try{
                $local=Resolve-CloudLocalFilePath $target $path
                if(Test-Path -LiteralPath $local -PathType Leaf){
                    $localItem=Get-Item -LiteralPath $local -Force -ErrorAction Stop
                    if(-not(Test-LocalContentPresent -Item $localItem)){$state=Read-CloudState;$state.PendingPaths=@($state.PendingPaths | Where-Object {$_ -ne $path});Save-CloudState $state;continue}
                    if(([DateTime]::UtcNow-$localItem.LastWriteTimeUtc).TotalSeconds -lt 60){continue}
                }
                $r=Invoke-CloudPathRepair -Config $target -RelativePath $path -AutoCreateIfRemoteMissing
                $report.Pushed+=$r.Pushed; $report.Pulled+=$r.Pulled
                if($r.Failed){foreach($e in $r.Errors){$errors.Add($e)}}
                else{$state=Read-CloudState; $state.PendingPaths=@($state.PendingPaths | Where-Object {$_ -ne $path}); Save-CloudState $state;continue}
            }catch{$errors.Add("$path`: $($_.Exception.Message)")}
            # Rotate failures so one conflict cannot starve unprocessed files.
            $state=Read-CloudState; $state.PendingPaths=@($state.PendingPaths | Where-Object {$_ -ne $path})+@($path); Save-CloudState $state
        }
        $state=Read-CloudState; $state.LastCycleUtc=[DateTime]::UtcNow.ToString('o'); $state.LastFailure=($errors -join '; ')
        if(-not $errors.Count){$state.LastSuccessfulCycleUtc=$state.LastCycleUtc}
        Save-CloudState $state
        $report.FilesTracked=$state.Files.Count; $report.Pending=@($state.PendingPaths).Count
        $report.Error=$state.LastFailure
        $report.Status=if($errors.Count){'NeedsReview'}elseif($report.Pending){'Pending'}elseif($state.Files.Count -eq 0){'BaselineRequired'}else{'Monitoring'}
    } catch { $report.Status='Blocked'; $report.Error=$_.Exception.Message }
    finally { Save-LibraryJson ([pscustomobject]$report) (Join-Path $folder 'status.json') }
    return [pscustomobject]$report
}

if($LoadFunctionsOnly){return}
if($VerifyWrite -and -not $LibraryId){throw 'Specify -LibraryId when verifying write access; only that library receives a test file.'}
if($Authenticate){
    if($Enable -or $Disable -or $DiscoverOnly){throw '-Authenticate is only valid with a foreground check.'}
    $available=@(Get-SyncMappings | Where-Object Status -eq 'Discovered')
    if(-not $available.Count){throw 'No verified local mapping is available for Graph sign-in.'}
    $accounts=@($available.Account | Select-Object -Unique)
    $tenants=@($available.TenantId | Select-Object -Unique)
    if($accounts.Count -ne 1 -or $tenants.Count -ne 1){throw 'Multiple Graph accounts or tenants need separate interactive sessions.'}
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    Connect-MgGraph -TenantId $tenants[0] -Scopes 'Files.ReadWrite.All','Sites.Read.All','Files.ReadWrite' -UseDeviceAuthentication -ContextScope CurrentUser -NoWelcome -ErrorAction Stop
    if((Get-MgContext).Account -ine $accounts[0]){throw 'Signed-in Graph account differs from the mapped Windows OneDrive account.'}
    $Once=$true
}
$runKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$stop=Join-Path $DataRoot 'supervisor.stop'
if($Disable){New-Item -ItemType Directory -Path $DataRoot -Force | Out-Null; Set-Content -LiteralPath $stop -Value 'disabled'; Remove-ItemProperty $runKey -Name OneDriveMultiLibrarySync -ErrorAction SilentlyContinue; return}
if($DiscoverOnly){Get-SyncMappings; return}
if($Enable){
    New-Item -ItemType Directory -Path $DataRoot -Force | Out-Null
    Remove-Item -LiteralPath $stop -ErrorAction SilentlyContinue
    $command='-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -DataRoot "'+$DataRoot+'"'
    $exe=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Set-ItemProperty $runKey -Name OneDriveMultiLibrarySync -Value ('"'+$exe+'" '+$command)
    Start-Process $exe -ArgumentList $command -WindowStyle Hidden
    return
}
$mutex=New-Object Threading.Mutex($false,('Local\OneDriveMultiLibrarySync-'+[Security.Principal.WindowsIdentity]::GetCurrent().User.Value))
if(-not $mutex.WaitOne(0)){ $mutex.Dispose(); throw 'Multi-library supervisor is already running. Stop it before manual verification.' }
$watchers=@{}
try{
    do{
        $mappings=@(Get-SyncMappings)
        if($LibraryId -and $LibraryId -notin @($mappings.Id)){throw 'Requested library is not currently mapped.'}
        if($VerifyWrite){$mappings=@($mappings | Where-Object Id -eq $LibraryId)}
        if(-not $Once -and -not $VerifyWrite){Register-LibraryWatchers -Mappings $mappings -Watchers $watchers;Add-LibraryFileEvents -Root $DataRoot -Watchers $watchers}
        $reports=@(foreach($mapping in $mappings){ Invoke-LibraryCycle -Mapping $mapping -Root $DataRoot -CheckWrite:($VerifyWrite -and $mapping.Id -eq $LibraryId) })
        $priorStatus=Join-Path $DataRoot 'status.json'
        if(-not $VerifyWrite -and (Test-Path -LiteralPath $priorStatus)){
            $prior=Get-Content -LiteralPath $priorStatus -Raw | ConvertFrom-Json
            foreach($old in @($prior.Libraries)){
                if($old.Id -in @($mappings.Id)){continue}
                $reports+=([pscustomobject]@{Id=$old.Id;Name=$old.Name;SourceRoot=$old.SourceRoot;LibraryWebUrl=$old.LibraryWebUrl;
                    Status='MappingMissing';CheckedUtc=[DateTime]::UtcNow.ToString('o');FilesTracked=$old.FilesTracked;Pending=$old.Pending;Pushed=0;Pulled=0;Error='Local mapping is no longer reported by OneDrive.'})
            }
        }
        if(-not $VerifyWrite){Save-LibraryJson ([pscustomobject]@{CheckedUtc=[DateTime]::UtcNow.ToString('o'); Libraries=$reports}) $priorStatus}
        if($Once -or $VerifyWrite){$reports; break}
        for($i=0;$i -lt 30 -and -not(Test-Path $stop);$i++){Start-Sleep -Seconds 1}
    }while(-not(Test-Path $stop))
} finally{
    foreach($id in @($watchers.Keys)){
        foreach($eventName in @('Changed','Created','Deleted','Renamed','Error')){Unregister-Event -SourceIdentifier ('OneDriveMultiLibrarySync.'+$id+'.'+$eventName) -ErrorAction SilentlyContinue}
        $watchers[$id].Watcher.Dispose()
    }
    $mutex.ReleaseMutex();$mutex.Dispose()
}
