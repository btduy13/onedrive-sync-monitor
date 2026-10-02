[CmdletBinding()]
param([int]$TimeoutSeconds=240,[string]$CleanupProofName='')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'MultiLibrarySync.ps1') -LoadFunctionsOnly
$id='ad3cb41c079b218caaa193a7'
$root=Join-Path $env:LOCALAPPDATA 'OneDriveSyncMonitor\libraries'
$folder=Join-Path $root $id
$config=Get-Content -LiteralPath (Join-Path $folder 'config.json') -Raw | ConvertFrom-Json
if($CleanupProofName){
    if($CleanupProofName -cnotmatch '^OneDriveMonitor-SupervisorProof-[a-f0-9]{32}\.txt$'){throw 'Not an exact supervisor test fixture name.'}
    $cleanupLocal=Join-Path $config.SourceRoot $CleanupProofName
    if(Test-Path -LiteralPath $cleanupLocal){throw 'Test file still exists locally; refusing state cleanup.'}
    Connect-CloudGraph -Config $config -UseCachedAuthentication
    if(Get-RemoteItem -DriveId $config.DriveId -RelativePath $CleanupProofName){throw 'Test file still exists remotely; refusing state cleanup.'}
    $cleanupStatePath=Join-Path $folder 'state.json'
    $cleanupState=Read-CloudState -Path $cleanupStatePath
    $cleanupState.Files.Remove($CleanupProofName)
    $cleanupState.PendingPaths=@($cleanupState.PendingPaths | Where-Object {$_ -ne $CleanupProofName})
    Save-CloudState -State $cleanupState -Path $cleanupStatePath
    Write-Host "PASS: removed only obsolete test baseline $CleanupProofName"
    return
}
$name='OneDriveMonitor-SupervisorProof-'+[guid]::NewGuid().ToString('N')+'.txt'
$local=Join-Path $config.SourceRoot $name
$StatePath=Join-Path $folder 'state.json'
$content='OneDrive monitor automatic sync proof '+[guid]::NewGuid().ToString('N')
$remoteId=''
try{
    Connect-CloudGraph -Config $config -UseCachedAuthentication
    [IO.File]::WriteAllText($local,$content)
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do{
        Start-Sleep -Seconds 10
        $state=Read-CloudState -Path $StatePath
        $entry=$state.Files[$name]
        if(Test-CloudVerifiedBaseline -Entry $entry){
            $item=Get-RemoteItem -DriveId $config.DriveId -RelativePath $name
            if(-not $item -or -not(Test-RemoteMatchesLocal -DriveId $config.DriveId -RemoteItem $item -LocalPath $local)){
                throw 'Supervisor baseline exists, but remote content does not match the test file.'
            }
            $remoteId=[string]$item.id
            Write-Host "PASS: background supervisor recorded and verified automatic cloud sync for $name"
            return
        }
    }while([DateTime]::UtcNow -lt $deadline)
    $status=Get-Content -LiteralPath (Join-Path $folder 'status.json') -Raw | ConvertFrom-Json
    throw "Background supervisor did not sync the test file in $TimeoutSeconds seconds. Status=$($status.Status), Pending=$($status.Pending), Error=$($status.Error)"
}finally{
    if(-not $remoteId){
        try{$item=Get-RemoteItem -DriveId $config.DriveId -RelativePath $name;if($item){$remoteId=[string]$item.id}}catch{}
    }
    if($remoteId){
        $uri='https://graph.microsoft.com/v1.0/drives/{0}/items/{1}' -f [Uri]::EscapeDataString($config.DriveId),[Uri]::EscapeDataString($remoteId)
        try{Invoke-CloudGraph -Method DELETE -Uri $uri | Out-Null}catch{Write-Warning 'Could not remove own remote proof file.'}
    }
    if(Test-Path -LiteralPath $local -PathType Leaf){Remove-Item -LiteralPath $local -Force}
    # The fixture is gone on both sides; remove only its test baseline to avoid
    # reporting this intentional cleanup as a production deletion conflict.
    $state=Read-CloudState -Path $StatePath
    if($state.Files.ContainsKey($name)){$state.Files.Remove($name)}
    $state.PendingPaths=@($state.PendingPaths | Where-Object {$_ -ne $name})
    Save-CloudState -State $state -Path $StatePath
}
