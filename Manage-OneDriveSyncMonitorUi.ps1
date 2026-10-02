[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('SetPreference','SetWebhook','ClearWebhook','TestAlert','StartSync','StopSync','SignIn','VerifyWrite','ResolveLocal','ResolveCloud')][string]$Action,
    [ValidateSet('Email','AutoUpdate','SafeRecovery','ComputerName')][string]$Name='Email',
    [string]$Value='',
    [string]$LibraryId='',
    [string]$RelativePath='',
    [ValidateSet('LocalToCloud','CloudToLocal')][string]$ConfirmDirection='LocalToCloud'
)
$ErrorActionPreference='Stop'
$app=Join-Path $env:LOCALAPPDATA 'OneDriveSyncMonitor'
$configPath=Join-Path $app 'config.json'
$sync=Join-Path $app 'MultiLibrarySync.ps1'
$monitor=Join-Path $app 'OneDriveSyncMonitor.ps1'
$libraries=Join-Path $app 'libraries'

function Save-Preference {
    param($Config)
    $temporary=Join-Path $app ('config.ui-'+[guid]::NewGuid().ToString('N')+'.tmp')
    try {
        $Config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $temporary -Encoding UTF8
        Move-Item -LiteralPath $temporary -Destination $configPath -Force
    } finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
}

function Test-ValidLibraryId {
    param([string]$Id)
    if($Id -cnotmatch '^[a-f0-9]{24}$'){throw 'Choose a library from the dashboard.'}
    $folder=Join-Path $libraries $Id
    if(-not(Test-Path -LiteralPath (Join-Path $folder 'config.json') -PathType Leaf)){throw 'Library configuration is missing.'}
    return $folder
}

function Suspend-SyncForInteractiveAction {
    $run=Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name OneDriveMultiLibrarySync -ErrorAction SilentlyContinue
    $script:resumeSync=[bool]$run.OneDriveMultiLibrarySync
    & $sync -Disable
    $mutexName='Local\OneDriveMultiLibrarySync-'+[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $mutex=New-Object Threading.Mutex($false,$mutexName)
    try {
        $acquired=$false
        try{$acquired=$mutex.WaitOne(45000)}catch [Threading.AbandonedMutexException]{$acquired=$true}
        if(-not $acquired){throw 'The sync supervisor did not stop within 45 seconds.'}
        $mutex.ReleaseMutex()
    } finally {$mutex.Dispose()}
}

if($Action -eq 'SetPreference' -or $Action -eq 'SetWebhook' -or $Action -eq 'ClearWebhook'){
    if(-not(Test-Path -LiteralPath $configPath -PathType Leaf)){throw 'Monitor configuration is missing.'}
    $config=Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    if($Action -eq 'SetPreference'){
        if($Name -eq 'ComputerName'){
            if($Value -notmatch '^[\p{L}\p{N}_.-]{1,64}$'){throw 'Machine label must be 1-64 letters, numbers, dots, hyphens or underscores.'}
            $config | Add-Member -NotePropertyName ComputerName -NotePropertyValue $Value -Force
        } else {
            if($Value -notin @('true','false')){throw 'Expected true or false.'}
            $property=@{Email='NotifyItEmailEnabled';AutoUpdate='AutoUpdateEnabled';SafeRecovery='SafeRecoveryEnabled'}[$Name]
            $config | Add-Member -NotePropertyName $property -NotePropertyValue ([bool]::Parse($Value)) -Force
        }
    } elseif($Action -eq 'SetWebhook'){
        $plain=[Console]::In.ReadLine()
        $uri=$null
        if([string]::IsNullOrWhiteSpace($plain) -or $plain -match '\s' -or
           -not [Uri]::TryCreate($plain,[UriKind]::Absolute,[ref]$uri) -or
           $uri.Scheme -ne 'https' -or $uri.UserInfo -or -not $uri.Host){throw 'Paste one complete HTTPS Power Automate webhook URL.'}
        $secure=ConvertTo-SecureString -String $plain -AsPlainText -Force
        $protected=$secure | ConvertFrom-SecureString
        $config | Add-Member -NotePropertyName WebhookUrlProtected -NotePropertyValue $protected -Force
        if($config.PSObject.Properties['WebhookUrl']){$config.PSObject.Properties.Remove('WebhookUrl')}
        $plain=$null
    } else {
        $config | Add-Member -NotePropertyName WebhookUrlProtected -NotePropertyValue '' -Force
        if($config.PSObject.Properties['WebhookUrl']){$config.PSObject.Properties.Remove('WebhookUrl')}
    }
    Save-Preference $config
    Write-Host 'Setting saved for this Windows account.'
    return
}

if($Action -eq 'TestAlert'){
    & $monitor -TestAlert
    if($LASTEXITCODE -ne 0){throw 'Test alert failed; inspect monitor.log.'}
    return
}
if($Action -eq 'StartSync'){& $sync -Enable;return}
if($Action -eq 'StopSync'){& $sync -Disable;return}

if($Action -in @('SignIn','VerifyWrite','ResolveLocal','ResolveCloud')){
    $requestedLibraryId=$LibraryId
    $requestedRelativePath=$RelativePath
    $requestedAction=$Action
    if($Action -ne 'SignIn'){$folder=Test-ValidLibraryId $LibraryId}
    if($Action -in @('ResolveLocal','ResolveCloud')){
        if([string]::IsNullOrWhiteSpace($RelativePath)){throw 'Select one pending file.'}
        if(($Action -eq 'ResolveLocal' -and $ConfirmDirection -ne 'LocalToCloud') -or
           ($Action -eq 'ResolveCloud' -and $ConfirmDirection -ne 'CloudToLocal')){throw 'Direction confirmation does not match the action.'}
    }
    $script:resumeSync=$false
    try {
        Suspend-SyncForInteractiveAction
        if($Action -eq 'SignIn'){& $sync -Authenticate -Once | Out-Host;return}
        if($Action -eq 'VerifyWrite'){& $sync -Authenticate -VerifyWrite -LibraryId $requestedLibraryId | Out-Host;return}
        . $sync -LoadFunctionsOnly
        . (Join-Path $app 'OneDriveCloudBackup.ps1') -LoadFunctionsOnly -StatePath (Join-Path $folder 'state.json')
        $mapping=@(Get-SyncMappings | Where-Object { $_.Id -eq $requestedLibraryId -and $_.Status -eq 'Discovered' })
        if($mapping.Count -ne 1){throw 'The local/cloud library mapping is no longer verified.'}
        $target=Get-Content -LiteralPath (Join-Path $folder 'config.json') -Raw | ConvertFrom-Json
        $resolved=Resolve-SyncLibrary $mapping[0]
        if($target.DriveId -ne $resolved.DriveId -or $target.SourceRoot -ine $resolved.SourceRoot){throw 'Configured target no longer matches the discovered library.'}
        $permission=Get-Content -LiteralPath (Join-Path $folder 'permission.json') -Raw | ConvertFrom-Json
        if($permission.DriveId -ne $target.DriveId -or $permission.Account -ine $target.Account){throw 'Write permission for this library has not been verified.'}
        $state=Read-CloudState
        if($requestedRelativePath -notin @($state.PendingPaths)){throw 'The file is no longer pending. Refresh the dashboard.'}
        $full=Resolve-CloudLocalFilePath -Config $target -RelativePath $requestedRelativePath
        Confirm-CloudLocalParentPath -Config $target -FullPath $full
        Connect-CloudGraph -Config $target -UseCachedAuthentication
        if($requestedAction -eq 'ResolveLocal' -and -not (Get-RemoteItem -DriveId $target.DriveId -RelativePath $requestedRelativePath)){
            throw 'Cloud file is absent. Use automatic create-only sync, not manual overwrite.'
        }
        $direction=if($requestedAction -eq 'ResolveLocal'){'Local'}else{'Cloud'}
        $result=Invoke-CloudPathRepair -Config $target -RelativePath $requestedRelativePath -ResolveWith $direction
        if($result.Failed){throw ($result.Errors -join '; ')}
        Write-Host ('Manual action completed: '+$direction+' for '+$requestedRelativePath)
    } finally {
        if($script:resumeSync){& $sync -Enable}
    }
    return
}
