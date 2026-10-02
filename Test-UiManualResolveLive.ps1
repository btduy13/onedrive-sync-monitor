[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'MultiLibrarySync.ps1') -LoadFunctionsOnly
$id='ad3cb41c079b218caaa193a7'
$mapping=@(Get-SyncMappings | Where-Object Id -eq $id)[0]
if(-not $mapping -or $mapping.Status -ne 'Discovered'){throw 'Projects library mapping is not available.'}
$target=Resolve-SyncLibrary $mapping
$folder=Join-Path (Join-Path $env:LOCALAPPDATA 'OneDriveSyncMonitor\libraries') $id
$StatePath=Join-Path $folder 'state.json'
$names=@(('OneDriveMonitor-UiLocal-'+[guid]::NewGuid().ToString('N')+'.txt'),
         ('OneDriveMonitor-UiCloud-'+[guid]::NewGuid().ToString('N')+'.txt'))
$fixture=Join-Path $env:TEMP ('OneDriveMonitor-UiResolve-'+[guid]::NewGuid().ToString('N'))
$helper=Join-Path $PSScriptRoot 'Manage-OneDriveSyncMonitorUi.ps1'
$run=Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name OneDriveMultiLibrarySync -ErrorAction SilentlyContinue
$wasEnabled=[bool]$run.OneDriveMultiLibrarySync
try{
    & $helper -Action StopSync
    Start-Sleep -Seconds 2
    New-Item -ItemType Directory -Path $fixture -Force | Out-Null
    $cases=@(
        [pscustomobject]@{Name=$names[0];Local='local is authoritative';Cloud='cloud is old';Action='ResolveLocal';Expected='local is authoritative';Confirmation='LocalToCloud'},
        [pscustomobject]@{Name=$names[1];Local='local is old';Cloud='cloud is authoritative';Action='ResolveCloud';Expected='cloud is authoritative';Confirmation='CloudToLocal'}
    )
    foreach($case in $cases){
        $local=Join-Path $target.SourceRoot $case.Name
        $cloudSource=Join-Path $fixture $case.Name
        [IO.File]::WriteAllText($local,$case.Local)
        [IO.File]::WriteAllText($cloudSource,$case.Cloud)
        $remote=Send-CloudFile -DriveId $target.DriveId -RelativePath $case.Name -LocalPath $cloudSource -RemoteItem $null
        if(-not $remote.id){throw 'Fixture cloud upload failed.'}
        [IO.File]::WriteAllText($local,$case.Local)
        $state=Read-CloudState -Path $StatePath
        $state.PendingPaths=@(@($state.PendingPaths)+@($case.Name)|Select-Object -Unique)
        Save-CloudState -State $state -Path $StatePath
        $oldPreference=$ErrorActionPreference
        $ErrorActionPreference='Continue'
        try{$result=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $helper -Action $case.Action -LibraryId $id -RelativePath $case.Name -ConfirmDirection $case.Confirmation 2>&1}
        finally{$ErrorActionPreference=$oldPreference}
        if($LASTEXITCODE -ne 0){throw ('UI action failed: '+($result -join ' '))}
        $current=Get-RemoteItem -DriveId $target.DriveId -RelativePath $case.Name
        $localText=[IO.File]::ReadAllText($local)
        $state=Read-CloudState -Path $StatePath
        if($localText -cne $case.Expected -or -not (Test-RemoteMatchesLocal -DriveId $target.DriveId -RemoteItem $current -LocalPath $local) -or
           -not(Test-CloudVerifiedBaseline -Entry $state.Files[$case.Name])){throw ('UI manual action did not verify '+$case.Name)}
        Write-Host ('PASS: '+$case.Action+' changed only its own test file and recorded a verified baseline.')
    }
} finally {
    foreach($name in $names){
        try{
            $remote=Get-RemoteItem -DriveId $target.DriveId -RelativePath $name
            if($remote){
                $uri='https://graph.microsoft.com/v1.0/drives/{0}/items/{1}' -f [Uri]::EscapeDataString($target.DriveId),[Uri]::EscapeDataString([string]$remote.id)
                Invoke-CloudGraph -Method DELETE -Uri $uri | Out-Null
            }
        }catch{Write-Warning ('Could not remove own cloud fixture '+$name)}
        $local=Join-Path $target.SourceRoot $name
        if(Test-Path -LiteralPath $local -PathType Leaf){Remove-Item -LiteralPath $local -Force}
    }
    $state=Read-CloudState -Path $StatePath
    foreach($name in $names){$state.Files.Remove($name)}
    $state.PendingPaths=@($state.PendingPaths | Where-Object {$_ -notin $names})
    Save-CloudState -State $state -Path $StatePath
    if((Test-Path -LiteralPath $fixture) -and $fixture.StartsWith(([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\OneDriveMonitor-UiResolve-'),[StringComparison]::OrdinalIgnoreCase)){
        Remove-Item -LiteralPath $fixture -Recurse -Force
    }
    if($wasEnabled){& $helper -Action StartSync}
}
