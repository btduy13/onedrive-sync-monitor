[CmdletBinding()]
param([string]$LibraryId='ad3cb41c079b218caaa193a7')
$ErrorActionPreference='Stop'
$wantedLibraryId=$LibraryId
. (Join-Path $PSScriptRoot 'MultiLibrarySync.ps1') -LoadFunctionsOnly
$mapping=@(Get-SyncMappings | Where-Object Id -eq $wantedLibraryId)
if($mapping.Count -ne 1 -or $mapping[0].Status -ne 'Discovered'){throw 'The requested local library mapping is unavailable.'}
$target=Resolve-SyncLibrary $mapping[0]
$fixture=Join-Path $env:TEMP ('OneDriveMultiLibrary-Live-'+[guid]::NewGuid().ToString('N'))
$name='OneDriveMonitor-BidirectionalTest-'+[guid]::NewGuid().ToString('N')+'.txt'
$remoteId=''
try{
    New-Item -ItemType Directory -Path $fixture -Force | Out-Null
    $source=Join-Path $fixture 'source';New-Item -ItemType Directory -Path $source | Out-Null
    $StatePath=Join-Path $fixture 'state.json'
    $local=Join-Path $source $name
    $target.SourceRoot=$source
    [IO.File]::WriteAllText($local,'initial local test')
    $created=Invoke-CloudPathRepair -Config $target -RelativePath $name -AutoCreateIfRemoteMissing
    if($created.Pushed -ne 1 -or $created.Failed){
        throw "Initial guarded creation failed: $($created.Errors -join '; ')"
    }
    $item=Get-RemoteItem -DriveId $target.DriveId -RelativePath $name
    if(-not $item.id -or -not (Test-RemoteMatchesLocal -DriveId $target.DriveId -RemoteItem $item -LocalPath $local)){throw 'Initial upload verification failed.'}
    $remoteId=[string]$item.id
    Write-Host 'PASS: new local-only file was created on the selected cloud library.'
    [IO.File]::WriteAllText($local,'changed on local')
    $push=Invoke-CloudPathRepair -Config $target -RelativePath $name
    if($push.Pushed -ne 1 -or $push.Failed){throw "Local-to-cloud repair failed: $($push.Errors -join '; ')"}
    $item=Get-RemoteItem -DriveId $target.DriveId -RelativePath $name
    if(-not(Test-RemoteMatchesLocal -DriveId $target.DriveId -RemoteItem $item -LocalPath $local)){throw 'Local-to-cloud readback differs.'}
    Write-Host 'PASS: local change reached the selected Projects cloud library.'
    $cloudFile=Join-Path $fixture 'cloud-edit.txt'
    [IO.File]::WriteAllText($cloudFile,'changed on cloud')
    $item=Send-CloudFile -DriveId $target.DriveId -RelativePath $name -LocalPath $cloudFile -RemoteItem $item
    $pull=Invoke-CloudPathRepair -Config $target -RelativePath $name
    if($pull.Pulled -ne 1 -or $pull.Failed -or [IO.File]::ReadAllText($local) -cne 'changed on cloud'){throw "Cloud-to-local repair failed: $($pull.Errors -join '; ')"}
    Write-Host 'PASS: remote change reached the matching local test path.'
}finally{
    if(-not $remoteId -and $target.DriveId -and $name -like 'OneDriveMonitor-BidirectionalTest-*.txt'){
        try{$orphan=Get-RemoteItem -DriveId $target.DriveId -RelativePath $name;if($orphan){$remoteId=[string]$orphan.id}}catch{}
    }
    if($remoteId){
        $uri='https://graph.microsoft.com/v1.0/drives/{0}/items/{1}' -f [Uri]::EscapeDataString($target.DriveId),[Uri]::EscapeDataString($remoteId)
        try{Invoke-CloudGraph -Method DELETE -Uri $uri | Out-Null}catch{Write-Warning "Could not remove own cloud test item $name"}
    }
    if((Test-Path $fixture) -and $fixture.StartsWith(([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\OneDriveMultiLibrary-Live-'),[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $fixture -Recurse -Force}
}
