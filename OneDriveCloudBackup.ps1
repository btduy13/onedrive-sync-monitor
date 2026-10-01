[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $env:LOCALAPPDATA 'OneDriveSyncMonitor\cloud-backup.json'),
    [string]$StatePath = (Join-Path $env:LOCALAPPDATA 'OneDriveSyncMonitor\cloud-backup-state.json'),
    [string]$StopPath = (Join-Path $env:LOCALAPPDATA 'OneDriveSyncMonitor\cloud-backup.stop'),
    [switch]$Setup,
    [switch]$Once,
    [switch]$Enable,
    [switch]$Disable,
    [switch]$Backfill,
    [switch]$BaselineAll,
    [switch]$NoAlerts,
    [string[]]$RelativePath = @(),
    [switch]$LoadFunctionsOnly
)

$ErrorActionPreference = 'Stop'

function Write-CloudLog {
    param([string]$Message)
    $path = Join-Path $env:LOCALAPPDATA 'OneDriveSyncMonitor\cloud-backup.log'
    try {
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        Add-Content -LiteralPath $path -Value ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8
    }
    catch { }
}

function Get-CloudConfig {
    if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Cloud backup is not configured: $ConfigPath" }
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    if (-not $config.SourceRoot -or -not $config.DriveId -or -not $config.Account -or -not $config.TenantId) {
        throw 'Cloud backup config is incomplete.'
    }
    $config.SourceRoot = [IO.Path]::GetFullPath([string]$config.SourceRoot).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $config.SourceRoot -PathType Container)) { throw "Source folder is unavailable: $($config.SourceRoot)" }
    return $config
}

function Connect-CloudGraph {
    param($Config, [switch]$Interactive)
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    $context = Get-MgContext
    if ($null -eq $context -or $context.TenantId -ne $Config.TenantId -or
        $context.Account -ine $Config.Account -or 'Files.ReadWrite' -notin @($context.Scopes)) {
        $parameters = @{
            TenantId = [string]$Config.TenantId
            Scopes = @('Files.ReadWrite')
            ContextScope = 'CurrentUser'
            NoWelcome = $true
            ErrorAction = 'Stop'
        }
        if ($Interactive) { $parameters.UseDeviceAuthentication = $true }
        Connect-MgGraph @parameters
        $context = Get-MgContext
    }
    if ($null -eq $context -or $context.Account -ine $Config.Account -or
        $context.TenantId -ne $Config.TenantId -or 'Files.ReadWrite' -notin @($context.Scopes)) {
        throw "Graph signed in as the wrong account. Expected $($Config.Account)."
    }
}

function Invoke-CloudGraph {
    param([string]$Method, [string]$Uri, $Body = $null, [hashtable]$Headers = @{}, [string]$InputFilePath = '')
    $args = @{ Method = $Method; Uri = $Uri; OutputType = 'PSObject'; ErrorAction = 'Stop' }
    if ($null -ne $Body) { $args.Body = $Body; $args.ContentType = 'application/json' }
    if ($Headers.Count -gt 0) { $args.Headers = $Headers }
    if ($InputFilePath) { $args.InputFilePath = $InputFilePath; $args.ContentType = 'application/octet-stream' }
    return Invoke-MgGraphRequest @args
}

function Get-EncodedPath {
    param([string]$RelativePath)
    return (@($RelativePath -split '\\' | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/')
}

function Get-RemoteItem {
    param([string]$DriveId, [string]$RelativePath)
    $uri = 'https://graph.microsoft.com/v1.0/drives/{0}/root:/{1}' -f
        [Uri]::EscapeDataString($DriveId), (Get-EncodedPath -RelativePath $RelativePath)
    try { return Invoke-CloudGraph -Method GET -Uri $uri }
    catch {
        $status = $_.Exception.ResponseStatusCode
        if ($null -eq $status -and $_.Exception.Response) { $status = $_.Exception.Response.StatusCode }
        if ([int]$status -eq 404) { return $null }
        throw
    }
}

function Test-RemoteMatchesLocal {
    param([string]$DriveId, $RemoteItem, [string]$LocalPath)
    $localLength = (Get-Item -LiteralPath $LocalPath).Length
    if ([long]$RemoteItem.size -ne [long]$localLength -or $localLength -gt 250MB) { return $false }
    $temporary = Join-Path $env:TEMP ('OneDriveCloudCompare-' + [guid]::NewGuid().ToString('N'))
    try {
        $uri = 'https://graph.microsoft.com/v1.0/drives/{0}/items/{1}/content' -f
            [Uri]::EscapeDataString($DriveId), [Uri]::EscapeDataString([string]$RemoteItem.id)
        Invoke-MgGraphRequest -Method GET -Uri $uri -OutputFilePath $temporary -ErrorAction Stop | Out-Null
        $localHash = (Get-FileHash -LiteralPath $LocalPath -Algorithm SHA256).Hash
        $remoteHash = (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash
        return $localHash -eq $remoteHash
    }
    finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}

function Ensure-RemoteFolder {
    param([string]$DriveId, [string]$RelativeFolder)
    $root = Invoke-CloudGraph -Method GET -Uri ('https://graph.microsoft.com/v1.0/drives/{0}/root' -f [Uri]::EscapeDataString($DriveId))
    $parentId = [string]$root.id
    if (-not $RelativeFolder) { return $parentId }
    $current = ''
    foreach ($segment in ($RelativeFolder -split '\\')) {
        $current = if ($current) { "$current\$segment" } else { $segment }
        $existing = Get-RemoteItem -DriveId $DriveId -RelativePath $current
        if ($null -ne $existing) {
            if ($null -eq $existing.folder) { throw "Cloud path is not a folder: $current" }
            $parentId = [string]$existing.id
            continue
        }
        $uri = 'https://graph.microsoft.com/v1.0/drives/{0}/items/{1}/children' -f
            [Uri]::EscapeDataString($DriveId), [Uri]::EscapeDataString($parentId)
        $body = @{ name = $segment; folder = @{}; '@microsoft.graph.conflictBehavior' = 'fail' } | ConvertTo-Json -Depth 4
        $created = Invoke-CloudGraph -Method POST -Uri $uri -Body $body
        $parentId = [string]$created.id
    }
    return $parentId
}

function Send-CloudChunk {
    param([string]$UploadUrl, [byte[]]$Buffer, [int]$Count, [long]$Offset, [long]$Total)
    $request = [Net.HttpWebRequest]::Create($UploadUrl)
    $request.Method = 'PUT'
    $request.ContentType = 'application/octet-stream'
    $request.ContentLength = $Count
    $request.Timeout = 120000
    $request.Headers['Content-Range'] = 'bytes {0}-{1}/{2}' -f $Offset, ($Offset + $Count - 1), $Total
    $stream = $request.GetRequestStream()
    try { $stream.Write($Buffer, 0, $Count) }
    finally { $stream.Dispose() }
    $response = $request.GetResponse()
    try {
        $reader = New-Object IO.StreamReader($response.GetResponseStream())
        try { return ($reader.ReadToEnd() | ConvertFrom-Json) }
        finally { $reader.Dispose() }
    }
    finally { $response.Dispose() }
}

function Send-CloudFile {
    param([string]$DriveId, [string]$RelativePath, [string]$LocalPath, $RemoteItem, [switch]$ForceUploadSession)
    $parent = Split-Path -Parent $RelativePath
    $parentId = Ensure-RemoteFolder -DriveId $DriveId -RelativeFolder $parent
    $encoded = Get-EncodedPath -RelativePath $RelativePath
    $base = 'https://graph.microsoft.com/v1.0/drives/{0}/root:/{1}' -f [Uri]::EscapeDataString($DriveId), $encoded
    $length = (Get-Item -LiteralPath $LocalPath).Length
    if ($length -le 250MB -and -not $ForceUploadSession) {
        $headers = @{}
        if ($null -ne $RemoteItem) { $headers['If-Match'] = [string]$RemoteItem.eTag }
        return Invoke-CloudGraph -Method PUT -Uri ($base + ':/content') -InputFilePath $LocalPath -Headers $headers
    }

    $body = if ($null -ne $RemoteItem) { $null } else { @{ item = @{ name = (Split-Path -Leaf $RelativePath) } } | ConvertTo-Json -Depth 5 }
    $headers = @{}
    if ($null -ne $RemoteItem) { $headers['If-Match'] = [string]$RemoteItem.eTag }
    $sessionUri = if ($null -ne $RemoteItem) {
        'https://graph.microsoft.com/v1.0/drives/{0}/items/{1}/createUploadSession' -f [Uri]::EscapeDataString($DriveId), [Uri]::EscapeDataString([string]$RemoteItem.id)
    }
    else {
        'https://graph.microsoft.com/v1.0/drives/{0}/items/{1}:/{2}:/createUploadSession' -f [Uri]::EscapeDataString($DriveId), [Uri]::EscapeDataString($parentId), [Uri]::EscapeDataString((Split-Path -Leaf $RelativePath))
    }
    $session = Invoke-CloudGraph -Method POST -Uri $sessionUri -Body $body -Headers $headers
    if (-not $session.uploadUrl) { throw 'Graph did not return an upload URL.' }
    $file = [IO.File]::Open($LocalPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $buffer = New-Object byte[] (10MB)
        $offset = [long]0
        $response = $null
        while ($offset -lt $length) {
            $count = $file.Read($buffer, 0, [int][Math]::Min($buffer.Length, $length - $offset))
            if ($count -le 0) { throw 'Unexpected end of local file during upload.' }
            $response = Send-CloudChunk -UploadUrl ([string]$session.uploadUrl) -Buffer $buffer -Count $count -Offset $offset -Total $length
            $offset += $count
        }
        if (-not $response.id) { throw 'Cloud upload did not return a completed file.' }
        return $response
    }
    finally { $file.Dispose() }
}

function Read-CloudState {
    param([string]$Path = $StatePath)
    $state = @{ Files = @{}; PendingPaths = @(); WatcherOverflow = $false; Initialized = $false; LastCycleUtc = ''; LastFailure = ''; LastDeliveredFailure = '' }
    if (-not (Test-Path -LiteralPath $Path)) { return $state }
    $raw = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($raw.Files) {
        foreach ($property in $raw.Files.PSObject.Properties) { $state.Files[$property.Name] = $property.Value }
    }
    if ($raw.PendingPaths) { $state.PendingPaths = @($raw.PendingPaths) }
    if ($null -ne $raw.WatcherOverflow) { $state.WatcherOverflow = [bool]$raw.WatcherOverflow }
    if ($raw.LastCycleUtc) { $state.LastCycleUtc = [string]$raw.LastCycleUtc }
    if ($null -ne $raw.Initialized) { $state.Initialized = [bool]$raw.Initialized }
    if ($raw.LastFailure) { $state.LastFailure = [string]$raw.LastFailure }
    if ($raw.LastDeliveredFailure) { $state.LastDeliveredFailure = [string]$raw.LastDeliveredFailure }
    return $state
}

function Save-CloudState {
    param($State, [string]$Path = $StatePath)
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporary = "$Path.tmp"
    $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Get-LocalFiles {
    param([string]$Root)
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($Root)
    while ($stack.Count -gt 0) {
        $directory = $stack.Pop()
        foreach ($item in (Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)) {
            if ($item.PSIsContainer) {
                # OneDrive Files On-Demand directories are reparse points with no LinkType.
                # Skip actual junctions and symbolic links so they cannot escape the source tree.
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -or
                    [string]::IsNullOrWhiteSpace([string]$item.LinkType)) { $stack.Push($item.FullName) }
                continue
            }
            if (($item.Attributes -band [IO.FileAttributes]::Offline) -ne 0) { continue }
            if ($item.Name.StartsWith('~$') -or $item.Name.EndsWith('.tmp')) { continue }
            $item
        }
    }
}

function Invoke-CloudScan {
    param($Config, [switch]$Backfill, [string[]]$RelativePaths = $null)
    $state = Read-CloudState
    $changed = 0
    $adopted = 0
    $failures = New-Object 'System.Collections.Generic.List[string]'
    $targeted = $null -ne $RelativePaths
    $files = if ($targeted) {
        foreach ($relativePath in $RelativePaths) {
            if ([IO.Path]::IsPathRooted($relativePath) -or $relativePath -match '(^|[\\/])\.\.([\\/]|$)') {
                throw "Unsafe relative path: $relativePath"
            }
            $fullPath = [IO.Path]::GetFullPath((Join-Path $Config.SourceRoot $relativePath))
            if (-not $fullPath.StartsWith($Config.SourceRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
                throw "Path escapes source root: $relativePath"
            }
            if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { continue }
            $item = Get-Item -LiteralPath $fullPath -Force
            if (($item.Attributes -band [IO.FileAttributes]::Offline) -ne 0) { continue }
            if ($item.Name.StartsWith('~$') -or $item.Name.EndsWith('.tmp')) { continue }
            $item
        }
    }
    else { Get-LocalFiles -Root $Config.SourceRoot }
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($Config.SourceRoot.Length).TrimStart('\')
        $signature = '{0}|{1}' -f $file.Length, $file.LastWriteTimeUtc.Ticks
        $previous = $state.Files[$relative]
        if ($null -ne $previous -and $previous.Signature -eq $signature -and
            (-not $Backfill -or -not [string]::IsNullOrWhiteSpace([string]$previous.ETag))) { continue }
        try {
            $remote = Get-RemoteItem -DriveId ([string]$Config.DriveId) -RelativePath $relative
            if ($null -ne $remote -and $null -eq $remote.file) { throw 'Cloud path is a folder.' }
            if ($targeted -and $null -eq $previous -and $null -ne $remote) {
                $remoteTime = [DateTime]::MinValue
                if ($remote.lastModifiedDateTime) { $remoteTime = ([DateTime]$remote.lastModifiedDateTime).ToUniversalTime() }
                if ($remoteTime -ge $file.LastWriteTimeUtc.AddSeconds(-2)) {
                    if (Test-RemoteMatchesLocal -DriveId ([string]$Config.DriveId) -RemoteItem $remote -LocalPath $file.FullName) {
                        $state.Files[$relative] = @{ Signature = $signature; ETag = [string]$remote.eTag }
                        $adopted++
                        continue
                    }
                    throw 'Cloud file is newer than the local edit; manual conflict review required.'
                }
            }
            if (-not $targeted -and $null -eq $previous -and ($null -ne $remote -or -not $Backfill)) {
                # First scan records the folder without uploading its existing contents.
                $etag = if ($null -ne $remote) { [string]$remote.eTag } else { '' }
                $state.Files[$relative] = @{ Signature = $signature; ETag = $etag }
                $adopted++
                continue
            }
            if ($null -ne $previous -and -not $previous.ETag -and $null -ne $remote) {
                $state.Files[$relative] = @{ Signature = $signature; ETag = [string]$remote.eTag }
                $adopted++
                continue
            }
            if ($null -ne $previous -and $null -ne $remote -and $previous.ETag -ne [string]$remote.eTag) {
                throw 'Cloud file changed independently; manual conflict review required.'
            }
            if ($null -ne $previous -and $null -eq $remote -and $previous.ETag) {
                throw 'Cloud file was deleted independently; manual conflict review required.'
            }
            $beforeHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
            $uploaded = Send-CloudFile -DriveId ([string]$Config.DriveId) -RelativePath $relative -LocalPath $file.FullName -RemoteItem $remote
            $afterHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
            $savedSignature = if ($beforeHash -eq $afterHash) { $signature } else { 'retry' }
            $state.Files[$relative] = @{ Signature = $savedSignature; ETag = [string]$uploaded.eTag }
            $changed++
            Write-CloudLog "UPLOADED $relative"
            Save-CloudState -State $state
            if ($beforeHash -ne $afterHash) { throw 'Local file changed during upload; retry required.' }
        }
        catch {
            $message = "$relative`: $($_.Exception.Message)"
            $failures.Add($message)
            Write-CloudLog "ERROR $message"
        }
    }
    if (-not $targeted) { $state.Initialized = $true }
    Save-CloudState -State $state
    return [pscustomobject]@{ Uploaded = $changed; Adopted = $adopted; Failed = $failures.Count; Errors = @($failures) }
}

function Send-CloudStatus {
    param($Config, $Result, [string]$MonitorPath = (Join-Path $PSScriptRoot 'OneDriveSyncMonitor.ps1'))
    $cloudStatePath = $StatePath
    $state = Read-CloudState -Path $cloudStatePath
    $failure = if ($Result.Failed -gt 0) { (@($Result.Errors) -join '; ') } else { '' }
    $mustSend = ($failure -and $failure -ne $state.LastDeliveredFailure) -or
        (-not $failure -and -not [string]::IsNullOrWhiteSpace($state.LastDeliveredFailure))
    $state.LastFailure = $failure
    if (-not $mustSend) { Save-CloudState -State $state -Path $cloudStatePath; return }

    if (-not (Test-Path -LiteralPath $monitorPath)) { Save-CloudState -State $state -Path $cloudStatePath; return }
    try {
        . $monitorPath -LoadFunctionsOnly -ConfigPath (Join-Path $env:LOCALAPPDATA 'OneDriveSyncMonitor\config.json')
        $monitorConfig = Get-MonitorConfig
        $status = if ($failure) { 'Critical' } else { 'Healthy' }
        $message = if ($failure) { "Cloud backup failed: $failure" } else { 'Cloud backup has recovered.' }
        $resultForAlert = [pscustomobject]@{
            Status = $status
            Computer = [string]$monitorConfig.ComputerName
            TimestampUtc = [DateTime]::UtcNow.ToString('o')
            TimestampLocal = [DateTimeOffset]::Now.ToString('yyyy-MM-dd HH:mm:ss zzz')
            Text = "OneDrive cloud backup | $message"
            Issues = @([pscustomobject]@{ Code = 'CloudBackup.Failure'; Severity = $status; Account = $Config.Account; Message = $message })
            Accounts = @()
        }
        if (Send-WebhookAlert -Url ([string]$monitorConfig.WebhookUrl) -Result $resultForAlert -Reason 'cloud-backup') {
            $state.LastDeliveredFailure = $failure
        }
    }
    catch { }
    Save-CloudState -State $state -Path $cloudStatePath
}

if ($LoadFunctionsOnly) { return }

if ($Setup) {
    $account = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\OneDrive\Accounts\Business1' -ErrorAction Stop
    $draft = [pscustomobject]@{
        SourceRoot = [string]$account.UserFolder
        TenantId = [string]$account.ConfiguredTenantId
        Account = [string]$account.UserEmail
        DriveId = ''
    }
    Connect-CloudGraph -Config $draft -Interactive
    $drive = Invoke-CloudGraph -Method GET -Uri 'https://graph.microsoft.com/v1.0/me/drive'
    if (-not $drive.id) { throw 'Could not identify the signed-in OneDrive drive.' }
    $draft.DriveId = [string]$drive.id
    New-Item -ItemType Directory -Path (Split-Path -Parent $ConfigPath) -Force | Out-Null
    $draft | ConvertTo-Json | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
    Write-Host "Cloud backup configured for $($draft.Account): $($draft.SourceRoot)"
    Write-Host 'Use -Once -RelativePath "folder\file.ext" to test a file. Use -BaselineAll for a full inventory.'
    return
}

if ($Disable) {
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    Remove-ItemProperty -Path $runKey -Name 'OneDriveCloudBackup' -ErrorAction SilentlyContinue
    Set-Content -LiteralPath $StopPath -Value 'disabled' -Encoding ASCII
    Write-Host 'Cloud backup disabled. The watcher will stop within 30 seconds.'
    return
}

$config = Get-CloudConfig

if ($Enable) {
    Connect-CloudGraph -Config $config
    $check = Invoke-CloudGraph -Method GET -Uri ('https://graph.microsoft.com/v1.0/drives/{0}' -f [Uri]::EscapeDataString([string]$config.DriveId))
    if (-not $check.id) { throw 'Configured cloud drive is unavailable.' }
    $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $command = '"{0}" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}"' -f $powershell, $PSCommandPath
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if (-not (Test-Path -LiteralPath $runKey)) { New-Item -Path $runKey -Force | Out-Null }
    Set-ItemProperty -Path $runKey -Name 'OneDriveCloudBackup' -Value $command -ErrorAction Stop
    if (Test-Path -LiteralPath $StopPath) { Remove-Item -LiteralPath $StopPath -Force }
    Start-Process -FilePath $powershell -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath) -WindowStyle Hidden | Out-Null
    Write-Host 'Cloud backup enabled for this Windows user.'
    return
}

if ($Once) {
    if ($RelativePath.Count -eq 0 -and -not $BaselineAll) { throw 'Specify -RelativePath for a targeted upload, or -BaselineAll for a full inventory.' }
    Connect-CloudGraph -Config $config
    $targetPaths = if ($RelativePath.Count -gt 0) { $RelativePath } else { $null }
    $result = Invoke-CloudScan -Config $config -Backfill:$Backfill -RelativePaths $targetPaths
    if (-not $NoAlerts) { Send-CloudStatus -Config $config -Result $result }
    $result | ConvertTo-Json -Depth 4
    if ($result.Failed -gt 0) { exit 1 }
    return
}

$watcher = New-Object IO.FileSystemWatcher($config.SourceRoot)
$watcher.IncludeSubdirectories = $true
$watcher.EnableRaisingEvents = $true
$watcher.NotifyFilter = [IO.NotifyFilters]'FileName, LastWrite, Size, DirectoryName'
$sourceId = 'OneDriveCloudBackup-' + [guid]::NewGuid().ToString('N')
$eventNames = @('Changed', 'Created', 'Renamed', 'Error')
foreach ($eventName in $eventNames) {
    Register-ObjectEvent -InputObject $watcher -EventName $eventName -SourceIdentifier "$sourceId-$eventName" | Out-Null
}
$mutexName = 'Local\OneDriveCloudBackup-' + ($config.Account -replace '[^a-zA-Z0-9]', '-')
$mutex = New-Object Threading.Mutex($false, $mutexName)
if (-not $mutex.WaitOne(0)) {
    foreach ($eventName in $eventNames) { Unregister-Event -SourceIdentifier "$sourceId-$eventName" -ErrorAction SilentlyContinue }
    $watcher.Dispose()
    $mutex.Dispose()
    return
}
$versionPath = Join-Path $PSScriptRoot 'version.json'
$runningVersion = if (Test-Path -LiteralPath $versionPath) { (Get-Content -LiteralPath $versionPath -Raw | ConvertFrom-Json).version } else { '' }
$startupState = Read-CloudState
$startupState.LastCycleUtc = [DateTime]::UtcNow.ToString('o')
Save-CloudState -State $startupState
$restart = $false
try {
    while ($true) {
        if (Test-Path -LiteralPath $StopPath) { break }
        Wait-Event -Timeout 30 | Out-Null
        $pending = [ordered]@{}
        $state = Read-CloudState
        foreach ($path in @($state.PendingPaths)) { $pending[[string]$path] = $true }
        $events = @(Get-Event | Where-Object { $_.SourceIdentifier.StartsWith($sourceId + '-') })
        foreach ($event in $events) {
            if ($event.SourceIdentifier -eq "$sourceId-Error") {
                $state.WatcherOverflow = $true
                Write-CloudLog 'ERROR file watcher overflow or stopped; manual inventory is required.'
            }
            else {
                $path = [string]$event.SourceEventArgs.FullPath
                if ($path.StartsWith($config.SourceRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
                    $relative = $path.Substring($config.SourceRoot.Length).TrimStart('\')
                    if ($relative) { $pending[$relative] = $true }
                }
            }
            Remove-Event -EventIdentifier $event.EventIdentifier -ErrorAction SilentlyContinue
        }
        $state.PendingPaths = @($pending.Keys)
        $state.LastCycleUtc = [DateTime]::UtcNow.ToString('o')
        Save-CloudState -State $state
        if ($events.Count -gt 0) { Start-Sleep -Seconds 3 }

        $errors = New-Object 'System.Collections.Generic.List[string]'
        try {
            if ($pending.Count -gt 0) { Connect-CloudGraph -Config $config }
            foreach ($relative in @($pending.Keys)) {
                $result = Invoke-CloudScan -Config $config -RelativePaths @($relative)
                if ($result.Failed -gt 0) {
                    foreach ($message in $result.Errors) { $errors.Add([string]$message) }
                }
                else {
                    $pending.Remove($relative)
                    $state = Read-CloudState
                    $state.PendingPaths = @($pending.Keys)
                    Save-CloudState -State $state
                }
            }
        }
        catch {
            $errors.Add($_.Exception.Message)
            Write-CloudLog "ERROR cloud queue: $($_.Exception.Message)"
        }
        $state = Read-CloudState
        if ($state.WatcherOverflow) { $errors.Add('File watcher lost changes; IT must run a full inventory.') }
        if (-not $NoAlerts) { Send-CloudStatus -Config $config -Result ([pscustomobject]@{ Failed = $errors.Count; Errors = @($errors) }) }
        $diskVersion = if (Test-Path -LiteralPath $versionPath) { (Get-Content -LiteralPath $versionPath -Raw | ConvertFrom-Json).version } else { '' }
        if ($diskVersion -ne $runningVersion) {
            $restart = $true
            break
        }
    }
}
finally {
    foreach ($eventName in $eventNames) { Unregister-Event -SourceIdentifier "$sourceId-$eventName" -ErrorAction SilentlyContinue }
    $watcher.Dispose()
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
if ($restart) {
    $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $powershell -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath) -WindowStyle Hidden | Out-Null
}
