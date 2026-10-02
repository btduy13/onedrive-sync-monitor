[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $env:LOCALAPPDATA 'OneDriveSyncMonitor\cloud-backup.json'),
    [string]$StatePath = (Join-Path $env:LOCALAPPDATA 'OneDriveSyncMonitor\cloud-backup-state.json'),
    [string]$StopPath = (Join-Path $env:LOCALAPPDATA 'OneDriveSyncMonitor\cloud-backup.stop'),
    [switch]$Setup,
    [switch]$SetupSharePoint,
    [string]$SharePointLibraryUrl = '',
    [string]$SourceRoot = '',
    [string]$TenantId = '',
    [string]$ClientId = '',
    [string]$CertificateThumbprint = '',
    [switch]$Once,
    [switch]$Enable,
    [switch]$Disable,
    [switch]$Backfill,
    [switch]$BaselineAll,
    [switch]$Repair,
    [ValidateSet('Local', 'Cloud')][string]$ResolveWith,
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
    if (-not $config.SourceRoot -or -not $config.DriveId -or -not $config.TenantId) {
        throw 'Cloud backup config is incomplete.'
    }
    if ($config.AuthMode -eq 'Certificate') {
        if (-not $config.ClientId -or -not $config.CertificateThumbprint) { throw 'Certificate backup config is incomplete.' }
    }
    elseif (-not $config.AuthMode -or $config.AuthMode -eq 'Delegated') {
        if (-not $config.Account) { throw 'Delegated backup config is incomplete.' }
    }
    else { throw 'Unknown cloud backup authentication mode.' }
    $config.SourceRoot = [IO.Path]::GetFullPath([string]$config.SourceRoot).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $config.SourceRoot -PathType Container)) { throw "Source folder is unavailable: $($config.SourceRoot)" }
    if ($config.TargetType -eq 'SharePoint' -and (-not $config.LibraryWebUrl -or -not $config.SiteId)) {
        throw 'SharePoint target config is incomplete.'
    }
    return $config
}

function Test-CloudAuthCheckDue {
    param($Config, [DateTime]$LastCheckUtc, [DateTime]$NowUtc = [DateTime]::UtcNow)
    return ($Config.AuthMode -eq 'Certificate' -and ($NowUtc - $LastCheckUtc).TotalMinutes -ge 10)
}

function Connect-CloudGraph {
    param($Config, [switch]$Interactive, [switch]$UseCachedAuthentication)
    $runtimePath = Join-Path $PSScriptRoot 'graph-runtime.json'
    if (Test-Path -LiteralPath $runtimePath) {
        $runtime = Get-Content -LiteralPath $runtimePath -Raw | ConvertFrom-Json
        $modulePath = [IO.Path]::GetFullPath([string]$runtime.ManifestPath)
        $expectedRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
        $relative = if ($modulePath.StartsWith($expectedRoot, [StringComparison]::OrdinalIgnoreCase)) { $modulePath.Substring($expectedRoot.Length) } else { '' }
        if ($relative -notmatch '^GraphRuntime-[a-f0-9]{16}\\Microsoft\.Graph\.Authentication\\2\.41\.0\\Microsoft\.Graph\.Authentication\.psd1$') {
            throw 'Bundled Graph runtime path is invalid. Run the company installer to repair it.'
        }
        Import-Module $modulePath -ErrorAction Stop
    }
    else { Import-Module Microsoft.Graph.Authentication -ErrorAction Stop }
    $context = Get-MgContext
    if ($Config.AuthMode -eq 'Certificate') {
        $thumbprint = [string]$Config.CertificateThumbprint
        if ([string]$Config.ClientId -notmatch '^[0-9a-fA-F-]{36}$' -or $thumbprint -notmatch '^[0-9a-fA-F]{40}$') {
            throw 'Certificate app ID or thumbprint is invalid.'
        }
        $cert = Get-Item -LiteralPath ("Cert:\CurrentUser\My\$thumbprint") -ErrorAction Stop
        if (-not $cert.HasPrivateKey -or $cert.NotAfter -le (Get-Date)) {
            throw 'Current Windows user has no valid private key for the configured certificate.'
        }
        if ($null -eq $context -or $context.AuthType -ne 'AppOnly' -or
            $context.ClientId -ine $Config.ClientId -or $context.TenantId -ne $Config.TenantId -or
            ($context.CertificateThumbprint -and $context.CertificateThumbprint -ine $thumbprint)) {
            Connect-MgGraph -ClientId ([string]$Config.ClientId) -TenantId ([string]$Config.TenantId) `
                -CertificateThumbprint $thumbprint -ContextScope Process -NoWelcome -ErrorAction Stop
            $context = Get-MgContext
        }
        if ($null -eq $context -or $context.AuthType -ne 'AppOnly' -or
            $context.ClientId -ine $Config.ClientId -or $context.TenantId -ne $Config.TenantId) {
            throw 'Graph app-only context does not match the configured app and tenant.'
        }
    }
    elseif (-not $Config.AuthMode -or $Config.AuthMode -eq 'Delegated') {
        $requiredScopes = if ($Config.TargetType -eq 'SharePoint') {
            @('Files.ReadWrite.All', 'Sites.Read.All')
        } else { @('Files.ReadWrite') }
        $missingScope = @($requiredScopes | Where-Object { $_ -notin @($context.Scopes) }).Count -gt 0
        if ($null -eq $context -or $context.TenantId -ne $Config.TenantId -or
            $context.Account -ine $Config.Account -or $missingScope) {
            if (-not $Interactive -and -not $UseCachedAuthentication) { throw 'AuthenticationRequired: sign in interactively before starting background sync.' }
            $parameters = @{
                TenantId = [string]$Config.TenantId
                Scopes = $requiredScopes
                ContextScope = 'CurrentUser'
                NoWelcome = $true
                ErrorAction = 'Stop'
            }
            if ($Interactive) { $parameters.UseDeviceAuthentication = $true }
            if ($UseCachedAuthentication -and -not $Interactive) {
                # Device auth may wait forever for input when the cache has expired. Probe in a
                # bounded child process first, then reconnect in this process only if it succeeds.
                $probeJob = Start-Job -ScriptBlock {
                    param($manifest,$tenant,$scopes,$expectedAccount)
                    Import-Module $manifest -ErrorAction Stop
                    Connect-MgGraph -TenantId $tenant -Scopes $scopes -UseDeviceAuthentication -ContextScope CurrentUser -NoWelcome -ClientTimeout 15 -ErrorAction Stop | Out-Null
                    if ((Get-MgContext).Account -ine $expectedAccount) { throw 'Cached account differs from mapping.' }
                } -ArgumentList @($(if ($modulePath) { $modulePath } else { 'Microsoft.Graph.Authentication' }),[string]$Config.TenantId,$requiredScopes,[string]$Config.Account)
                try {
                    if (-not (Wait-Job -Job $probeJob -Timeout 20)) { throw 'AuthenticationRequired: cached Graph sign-in timed out; run foreground authentication.' }
                    Receive-Job -Job $probeJob -ErrorAction Stop | Out-Null
                } catch { throw 'AuthenticationRequired: cached Graph sign-in is unavailable; run foreground authentication.' }
                finally { Stop-Job -Job $probeJob -ErrorAction SilentlyContinue; Remove-Job -Job $probeJob -Force -ErrorAction SilentlyContinue }
                $parameters.UseDeviceAuthentication = $true
                $parameters.ClientTimeout = 15
            }
            Connect-MgGraph @parameters
            $context = Get-MgContext
        }
        if ($null -eq $context -or $context.Account -ine $Config.Account -or
            $context.TenantId -ne $Config.TenantId -or
            @($requiredScopes | Where-Object { $_ -notin @($context.Scopes) }).Count -gt 0) {
            throw "Graph account or delegated permissions do not match the target. Expected $($Config.Account) with $($requiredScopes -join ', ')."
        }
    }
    else { throw 'Unknown cloud backup authentication mode.' }
    # Get-MgContext reports cached metadata even when the SDK can no longer
    # acquire a token. Verify a real, read-only request before accepting it.
    $probeUri = 'https://graph.microsoft.com/v1.0/me/drive'
    if ($Config.TargetType -eq 'SharePoint') {
        $libraryUri = [Uri]$Config.LibraryWebUrl
        $segments = @([Uri]::UnescapeDataString($libraryUri.AbsolutePath).Trim('/') -split '/')
        if ($libraryUri.Scheme -ne 'https' -or $libraryUri.Host -notlike '*.sharepoint.com' -or
            $segments.Count -lt 3 -or $segments[0] -notin @('sites', 'teams')) {
            throw 'Configured SharePoint library URL is invalid.'
        }
        $sitePath = (@($segments[0..1] | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/')
        $probeUri = 'https://graph.microsoft.com/v1.0/sites/{0}:/{1}' -f $libraryUri.Host, $sitePath
    }
    try {
        $probe = Invoke-MgGraphRequest -Method GET -Uri $probeUri -OutputType PSObject -ErrorAction Stop
        if (-not $probe.id) { throw 'Graph did not return a site or drive ID.' }
    }
    catch {
        $failureType = $_.Exception.GetType().Name
        throw "Graph read probe failed ($failureType). Cloud uploads cannot be verified; check sign-in, site access, and network with IT."
    }
}

function Get-SharePointLibraryLocation {
    param([Parameter(Mandatory = $true)][string]$Url)
    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne 'https' -or $uri.Host -notlike '*.sharepoint.com' -or
        $uri.Port -ne 443 -or $uri.UserInfo) {
        throw 'Enter an HTTPS SharePoint document-library URL.'
    }
    $path = [Uri]::UnescapeDataString($uri.AbsolutePath)
    $match = [regex]::Match($path, '^/(sites|teams)/([^/]+)/([^/]+)/Forms/AllItems\.aspx/?$', 'IgnoreCase')
    if (-not $match.Success) { throw 'Expected a document-library AllItems.aspx URL, not a site or file link.' }
    $sitePath = '{0}/{1}' -f $match.Groups[1].Value, $match.Groups[2].Value
    $libraryPath = '{0}/{1}' -f $sitePath, $match.Groups[3].Value
    return [pscustomobject]@{
        Host = $uri.Host
        SitePath = $sitePath
        LibraryPath = $libraryPath
        LibraryWebUrl = ('https://{0}/{1}' -f $uri.Host, $libraryPath)
    }
}

function New-SharePointBackupDraft {
    param([string]$Root, $Location, [string]$TenantId = '', [string]$ClientId = '',
        [string]$CertificateThumbprint = '', $OneDriveAccount = $null)
    $appRequested = [bool]($TenantId -or $ClientId -or $CertificateThumbprint)
    if ($appRequested) {
        $parsedTenant = [guid]::Empty
        $parsedClient = [guid]::Empty
        if (-not [guid]::TryParse($TenantId, [ref]$parsedTenant) -or
            -not [guid]::TryParse($ClientId, [ref]$parsedClient) -or
            $CertificateThumbprint -notmatch '^[0-9a-fA-F]{40}$') {
            throw 'Certificate setup requires a valid tenant ID, app ID, and 40-character certificate thumbprint.'
        }
        return [pscustomobject]@{
            TargetType = 'SharePoint'; AuthMode = 'Certificate'; SourceRoot = $Root
            TenantId = $parsedTenant.ToString(); Account = ('App:' + $parsedClient.ToString())
            ClientId = $parsedClient.ToString(); CertificateThumbprint = $CertificateThumbprint.ToUpperInvariant()
            SiteId = ''; DriveId = ''; LibraryWebUrl = $Location.LibraryWebUrl
            # A newer installer may repair one-sided changes after it has recorded a baseline.
            # It never uses timestamps to choose a winner for an unverified conflict.
            SyncMode = 'BidirectionalRepair'
        }
    }
    if (-not $OneDriveAccount -or -not $OneDriveAccount.ConfiguredTenantId -or -not $OneDriveAccount.UserEmail) {
        throw 'Delegated backup requires a configured OneDrive Business1 account.'
    }
    return [pscustomobject]@{
        TargetType = 'SharePoint'; AuthMode = 'Delegated'; SourceRoot = $Root
        TenantId = [string]$OneDriveAccount.ConfiguredTenantId; Account = [string]$OneDriveAccount.UserEmail
        SiteId = ''; DriveId = ''; LibraryWebUrl = $Location.LibraryWebUrl
        SyncMode = 'BidirectionalRepair'
    }
}

function Resolve-SharePointLibraryDrive {
    param($Location)
    $encodedSitePath = (@($Location.SitePath -split '/' | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/')
    $site = Invoke-CloudGraph -Method GET -Uri ('https://graph.microsoft.com/v1.0/sites/{0}:/{1}' -f $Location.Host, $encodedSitePath)
    if (-not $site.id) { throw 'Graph could not resolve the SharePoint site.' }
    $next = 'https://graph.microsoft.com/v1.0/sites/{0}/drives' -f [Uri]::EscapeDataString([string]$site.id)
    $matches = @()
    while ($next) {
        $page = Invoke-CloudGraph -Method GET -Uri $next
        foreach ($drive in @($page.value)) {
            if (-not $drive.webUrl -or $drive.driveType -ne 'documentLibrary') { continue }
            $driveUri = [Uri]$drive.webUrl
            $drivePath = [Uri]::UnescapeDataString($driveUri.AbsolutePath).TrimEnd('/')
            if ($driveUri.Host -ieq $Location.Host -and $drivePath -ieq ('/' + $Location.LibraryPath)) {
                $matches += $drive
            }
        }
        $next = [string]$page.'@odata.nextLink'
    }
    if ($matches.Count -ne 1) { throw "Expected exactly one document library at $($Location.LibraryWebUrl); found $($matches.Count). No upload target was configured." }
    return [pscustomobject]@{ SiteId = [string]$site.id; DriveId = [string]$matches[0].id; LibraryWebUrl = [string]$matches[0].webUrl }
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
    param([string]$DriveId, [string]$RelativePath, [string]$LocalPath, $RemoteItem, [switch]$ForceUploadSession, [switch]$CreateOnly)
    if($CreateOnly -and $null -ne $RemoteItem){throw 'Create-only upload cannot replace a cloud item.'}
    $parent = Split-Path -Parent $RelativePath
    $parentId = Ensure-RemoteFolder -DriveId $DriveId -RelativeFolder $parent
    $encoded = Get-EncodedPath -RelativePath $RelativePath
    $base = 'https://graph.microsoft.com/v1.0/drives/{0}/root:/{1}' -f [Uri]::EscapeDataString($DriveId), $encoded
    $length = (Get-Item -LiteralPath $LocalPath).Length
    if ($length -le 250MB -and -not $ForceUploadSession -and -not $CreateOnly) {
        $headers = @{}
        if ($null -ne $RemoteItem) { $headers['If-Match'] = [string]$RemoteItem.eTag }
        return Invoke-CloudGraph -Method PUT -Uri ($base + ':/content') -InputFilePath $LocalPath -Headers $headers
    }

    # Graph defaults new upload sessions to conflictBehavior=fail. An empty body also
    # avoids a SharePoint 400 response observed when specifying uploadable item fields.
    $body = $null
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
    $state = @{ Files = @{}; PendingPaths = @(); WatcherOverflow = $false; Initialized = $false; LastCycleUtc = ''; LastSuccessfulCycleUtc = ''; LastFailure = ''; LastDeliveredFailure = ''; RemoteDeltaLink = ''; RemoteDeltaNextLink = '' }
    if (-not (Test-Path -LiteralPath $Path)) { return $state }
    $raw = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($raw.Files) {
        foreach ($property in $raw.Files.PSObject.Properties) { $state.Files[$property.Name] = $property.Value }
    }
    if ($raw.PendingPaths) { $state.PendingPaths = @($raw.PendingPaths) }
    if ($null -ne $raw.WatcherOverflow) { $state.WatcherOverflow = [bool]$raw.WatcherOverflow }
    if ($raw.LastCycleUtc) { $state.LastCycleUtc = [string]$raw.LastCycleUtc }
    if ($raw.LastSuccessfulCycleUtc) { $state.LastSuccessfulCycleUtc = [string]$raw.LastSuccessfulCycleUtc }
    if ($null -ne $raw.Initialized) { $state.Initialized = [bool]$raw.Initialized }
    if ($raw.LastFailure) { $state.LastFailure = [string]$raw.LastFailure }
    if ($raw.LastDeliveredFailure) { $state.LastDeliveredFailure = [string]$raw.LastDeliveredFailure }
    if ($raw.LastAlertAttemptUtc) { $state.LastAlertAttemptUtc = [string]$raw.LastAlertAttemptUtc }
    if ($raw.RemoteDeltaLink) { $state.RemoteDeltaLink = [string]$raw.RemoteDeltaLink }
    if ($raw.RemoteDeltaNextLink) { $state.RemoteDeltaNextLink = [string]$raw.RemoteDeltaNextLink }
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

function Test-LocalContentPresent {
    param($Item)
    # Reading these placeholders can hydrate a 400 GB SharePoint library unexpectedly.
    $cloudOnlyFlags = 0x00001000 -bor 0x00040000 -bor 0x00400000
    return (([int]$Item.Attributes -band $cloudOnlyFlags) -eq 0 -and [string]::IsNullOrWhiteSpace([string]$Item.LinkType))
}

function Get-CloudLocalSignature {
    param($Item)
    return '{0}|{1}' -f $Item.Length, $Item.LastWriteTimeUtc.Ticks
}

function Get-CloudLocalChange {
    param($Item, $Previous)
    $signature = Get-CloudLocalSignature -Item $Item
    $hash = ''
    $changed = $true
    if ($null -ne $Previous -and -not [string]::IsNullOrWhiteSpace([string]$Previous.ContentHash)) {
        $hash = (Get-FileHash -LiteralPath $Item.FullName -Algorithm SHA256).Hash
        $changed = $hash -ne [string]$Previous.ContentHash
    }
    return [pscustomobject]@{ Signature = $signature; ContentHash = $hash; Changed = $changed }
}

function Resolve-CloudLocalFilePath {
    param($Config, [Parameter(Mandatory = $true)][string]$RelativePath)
    $relative = $RelativePath.Replace('/', '\')
    if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or
        $relative -match '(^|\\)\.\.?(\\|$)') {
        throw "Unsafe relative path: $RelativePath"
    }
    foreach ($segment in ($relative -split '\\')) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
            throw "Unsafe path segment: $RelativePath"
        }
    }
    $root = [IO.Path]::GetFullPath([string]$Config.SourceRoot).TrimEnd('\')
    $full = [IO.Path]::GetFullPath((Join-Path $root $relative))
    if (-not $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path escapes source root: $RelativePath"
    }
    return $full
}

function Confirm-CloudLocalParentPath {
    param($Config, [Parameter(Mandatory = $true)][string]$FullPath, [switch]$Create)
    $root = [IO.Path]::GetFullPath([string]$Config.SourceRoot).TrimEnd('\')
    $parent = Split-Path -Parent $FullPath
    if (-not $parent.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw 'Local destination escaped the configured source.' }
    $rootItem = Get-Item -LiteralPath $root -Force
    if (-not [string]::IsNullOrWhiteSpace([string]$rootItem.LinkType)) { throw 'Configured source root is a linked path.' }
    $current = $root
    $suffix = $parent.Substring($root.Length).TrimStart('\')
    foreach ($segment in @($suffix -split '\\' | Where-Object { $_ })) {
        $current = Join-Path $current $segment
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (-not $item.PSIsContainer -or -not [string]::IsNullOrWhiteSpace([string]$item.LinkType)) {
                throw "Unsafe local destination parent: $current"
            }
        }
        elseif ($Create) {
            New-Item -ItemType Directory -Path $current -Force -ErrorAction Stop | Out-Null
        }
        else { throw "Local destination parent is missing: $current" }
    }
}

function Save-CloudRemoteContent {
    param([string]$DriveId, $RemoteItem, [string]$LocalPath)
    if (-not $RemoteItem.id) { throw 'Cloud file has no item ID.' }
    $uri = 'https://graph.microsoft.com/v1.0/drives/{0}/items/{1}/content' -f
        [Uri]::EscapeDataString($DriveId), [Uri]::EscapeDataString([string]$RemoteItem.id)
    Invoke-MgGraphRequest -Method GET -Uri $uri -OutputFilePath $LocalPath -ErrorAction Stop | Out-Null
}

function Invoke-CloudPullFile {
    param($Config, [string]$RelativePath, $RemoteItem, [string]$ExpectedSignature = '')
    if ($null -eq $RemoteItem -or $null -eq $RemoteItem.file) { throw 'Cloud item is not a downloadable file.' }
    $fullPath = Resolve-CloudLocalFilePath -Config $Config -RelativePath $RelativePath
    Confirm-CloudLocalParentPath -Config $Config -FullPath $fullPath -Create
    $existing = $null
    if (Test-Path -LiteralPath $fullPath -PathType Container) { throw 'Local destination is a folder.' }
    if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
        $existing = Get-Item -LiteralPath $fullPath -Force
        if (-not (Test-LocalContentPresent -Item $existing)) { throw 'Local destination is a cloud-only or linked item.' }
        if ($ExpectedSignature -and (Get-CloudLocalSignature -Item $existing) -ne $ExpectedSignature) {
            throw 'Local file changed while a cloud download was being prepared.'
        }
    }
    $temporary = Join-Path (Split-Path -Parent $fullPath) ('.onedrive-sync-monitor-' + [guid]::NewGuid().ToString('N') + '.partial')
    $backup = Join-Path (Split-Path -Parent $fullPath) ('.onedrive-sync-monitor-' + [guid]::NewGuid().ToString('N') + '.prepull-backup')
    try {
        Save-CloudRemoteContent -DriveId ([string]$Config.DriveId) -RemoteItem $RemoteItem -LocalPath $temporary
        $remoteNow = Get-RemoteItem -DriveId ([string]$Config.DriveId) -RelativePath $RelativePath
        if (-not $remoteNow -or $remoteNow.id -ne $RemoteItem.id -or $remoteNow.eTag -ne $RemoteItem.eTag) {
            throw 'Cloud file changed during download; retry required.'
        }
        if (-not (Test-Path -LiteralPath $temporary -PathType Leaf)) { throw 'Cloud download did not create a local temporary file.' }
        if ($null -ne $RemoteItem.size -and [long](Get-Item -LiteralPath $temporary).Length -ne [long]$RemoteItem.size) {
            throw 'Downloaded cloud file length did not match Graph metadata.'
        }
        if ($null -ne $existing) {
            $current = Get-Item -LiteralPath $fullPath -Force
            if (-not (Test-LocalContentPresent -Item $current) -or
                ($ExpectedSignature -and (Get-CloudLocalSignature -Item $current) -ne $ExpectedSignature)) {
                throw 'Local file changed while the cloud download was in progress.'
            }
            [IO.File]::Replace($temporary, $fullPath, $backup)
            if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force -ErrorAction Stop }
        }
        else {
            [IO.File]::Move($temporary, $fullPath)
        }
        return Get-Item -LiteralPath $fullPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function New-CloudFileStateEntry {
    param([string]$Signature, $RemoteItem, [string]$ContentHash = '')
    return @{ BaselineVersion = 2; Verified = $true; Signature = $Signature
        ETag = if ($null -ne $RemoteItem) { [string]$RemoteItem.eTag } else { '' }
        RemoteId = if ($null -ne $RemoteItem) { [string]$RemoteItem.id } else { '' }; ContentHash = $ContentHash }
}

function Test-CloudVerifiedBaseline {
    param($Entry)
    return ($null -ne $Entry -and [bool]$Entry.Verified -and [int]$Entry.BaselineVersion -ge 2 -and
        -not [string]::IsNullOrWhiteSpace([string]$Entry.Signature) -and
        -not [string]::IsNullOrWhiteSpace([string]$Entry.ETag) -and
        -not [string]::IsNullOrWhiteSpace([string]$Entry.ContentHash))
}

function Invoke-CloudPathRepair {
    param($Config, [Parameter(Mandatory = $true)][string]$RelativePath, $RemoteItem = $null, [switch]$RemoteItemProvided,
        [ValidateSet('Local', 'Cloud')][string]$ResolveWith, [switch]$AutoCreateIfRemoteMissing)
    $state = Read-CloudState
    $errors = New-Object 'System.Collections.Generic.List[string]'
    $pushed = 0; $pulled = 0; $adopted = 0
    try {
        $fullPath = Resolve-CloudLocalFilePath -Config $Config -RelativePath $RelativePath
        Confirm-CloudLocalParentPath -Config $Config -FullPath $fullPath
        $local = $null
        if (Test-Path -LiteralPath $fullPath -PathType Container) { throw 'Local path is a folder.' }
        if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
            $candidate = Get-Item -LiteralPath $fullPath -Force
            if (-not (Test-LocalContentPresent -Item $candidate)) { throw 'Local item is cloud-only or linked; native OneDrive must hydrate it.' }
            $local = $candidate
        }
        if (-not $RemoteItemProvided) { $RemoteItem = Get-RemoteItem -DriveId ([string]$Config.DriveId) -RelativePath $RelativePath }
        if ($null -ne $RemoteItem -and $null -eq $RemoteItem.file) { throw 'Cloud path is a folder.' }
        $previousRaw = $state.Files[$RelativePath]
        # Entries from the previous one-way uploader did not prove local/cloud content equality.
        # Do not treat those historical ETag/signature pairs as authority to overwrite either side.
        $previous = if (Test-CloudVerifiedBaseline -Entry $previousRaw) { $previousRaw } else { $null }
        if ($ResolveWith -eq 'Local') {
            if ($null -eq $local) { throw 'Manual local resolution requires a locally available file.' }
            $beforeHash = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash
            $uploaded = Send-CloudFile -DriveId ([string]$Config.DriveId) -RelativePath $RelativePath -LocalPath $fullPath -RemoteItem $RemoteItem
            $afterFile = Get-Item -LiteralPath $fullPath -Force
            $afterHash = (Get-FileHash -LiteralPath $afterFile.FullName -Algorithm SHA256).Hash
            if ($beforeHash -ne $afterHash) { throw 'Local file changed during the manual cloud upload; the outcome needs review.' }
            $state.Files[$RelativePath] = New-CloudFileStateEntry -Signature (Get-CloudLocalSignature -Item $afterFile) -RemoteItem $uploaded -ContentHash $afterHash
            $pushed++
            Write-CloudLog "MANUAL-PUSHED $RelativePath"
        }
        elseif ($ResolveWith -eq 'Cloud') {
            if ($null -eq $RemoteItem) { throw 'Manual cloud resolution requires a downloadable cloud file.' }
            $expectedSignature = if ($null -ne $local) { Get-CloudLocalSignature -Item $local } else { '' }
            $downloaded = Invoke-CloudPullFile -Config $Config -RelativePath $RelativePath -RemoteItem $RemoteItem -ExpectedSignature $expectedSignature
            $state.Files[$RelativePath] = New-CloudFileStateEntry -Signature (Get-CloudLocalSignature -Item $downloaded) -RemoteItem $RemoteItem -ContentHash ((Get-FileHash -LiteralPath $downloaded.FullName -Algorithm SHA256).Hash)
            $pulled++
            Write-CloudLog "MANUAL-PULLED $RelativePath"
        }
        elseif ($null -eq $previous) {
            if ($null -ne $local -and $null -ne $RemoteItem) {
                if (-not (Test-RemoteMatchesLocal -DriveId ([string]$Config.DriveId) -RemoteItem $RemoteItem -LocalPath $fullPath)) {
                    throw 'Local and cloud versions have no verified common baseline; manual conflict review required.'
                }
                $hash = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash
                $state.Files[$RelativePath] = New-CloudFileStateEntry -Signature (Get-CloudLocalSignature $local) -RemoteItem $RemoteItem -ContentHash $hash
                $adopted++
            }
            elseif ($null -ne $local -and $AutoCreateIfRemoteMissing) {
                if($local.Length -eq 0 -or $local.Length -gt 250MB){throw 'New local-only file needs review because automatic readback is limited to non-empty files up to 250 MB.'}
                $beforeHash=(Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash
                $uploaded=Send-CloudFile -DriveId ([string]$Config.DriveId) -RelativePath $RelativePath -LocalPath $fullPath -RemoteItem $null -CreateOnly
                $afterHash=(Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash
                if($beforeHash -ne $afterHash){throw 'Local file changed during create-only upload; review the cloud result.'}
                $remoteNow=Get-RemoteItem -DriveId ([string]$Config.DriveId) -RelativePath $RelativePath
                if(-not $remoteNow -or $remoteNow.id -ne $uploaded.id -or
                    -not(Test-RemoteMatchesLocal -DriveId ([string]$Config.DriveId) -RemoteItem $remoteNow -LocalPath $fullPath)){
                    throw 'New cloud file could not be read back as the same content.'
                }
                $state.Files[$RelativePath]=New-CloudFileStateEntry -Signature (Get-CloudLocalSignature (Get-Item -LiteralPath $fullPath -Force)) -RemoteItem $remoteNow -ContentHash $afterHash
                $pushed++
                Write-CloudLog "CREATED $RelativePath"
            }
            elseif ($null -ne $local) { throw 'Local-only file has no verified baseline; use an explicit migration review before upload.' }
            elseif ($null -ne $RemoteItem) { throw 'Cloud-only file has no verified baseline; use OneDrive or an explicit restore review before download.' }
        }
        elseif ($null -eq $local -and $null -eq $RemoteItem) {
            $state.Files.Remove($RelativePath)
            $adopted++
        }
        elseif ($null -eq $local) {
            if ([string]$previous.ETag -eq [string]$RemoteItem.eTag) { throw 'Local file was deleted independently; it will not be recreated automatically.' }
            throw 'Local deletion conflicts with a cloud change; manual conflict review required.'
        }
        elseif ($null -eq $RemoteItem) {
            if ([string]::IsNullOrWhiteSpace([string]$previous.ETag)) { throw 'Cloud file is absent without a verified baseline.' }
            throw 'Cloud file was deleted independently; it will not be recreated automatically.'
        }
        else {
            $localChange = Get-CloudLocalChange -Item $local -Previous $previous
            $remoteChanged = [string]$previous.ETag -ne [string]$RemoteItem.eTag
            if (-not $localChange.Changed -and -not $remoteChanged) {
                if ($localChange.Signature -ne [string]$previous.Signature) {
                    $state.Files[$RelativePath] = New-CloudFileStateEntry -Signature $localChange.Signature -RemoteItem $RemoteItem -ContentHash ([string]$previous.ContentHash)
                }
            }
            elseif ($localChange.Changed -and -not $remoteChanged) {
                $beforeHash = if ($localChange.ContentHash) { $localChange.ContentHash } else { (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash }
                $uploaded = Send-CloudFile -DriveId ([string]$Config.DriveId) -RelativePath $RelativePath -LocalPath $fullPath -RemoteItem $RemoteItem
                $afterHash = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash
                $signature = if ($beforeHash -eq $afterHash) { Get-CloudLocalSignature (Get-Item -LiteralPath $fullPath -Force) } else { 'retry' }
                if ($beforeHash -ne $afterHash) { throw 'Local file changed during cloud upload; baseline preserved for review.' }
                $state.Files[$RelativePath] = New-CloudFileStateEntry -Signature $signature -RemoteItem $uploaded -ContentHash $afterHash
                $pushed++
                Write-CloudLog "PUSHED $RelativePath"
                if ($beforeHash -ne $afterHash) { throw 'Local file changed during cloud upload; retry required.' }
            }
            elseif (-not $localChange.Changed -and $remoteChanged) {
                if (Test-RemoteMatchesLocal -DriveId ([string]$Config.DriveId) -RemoteItem $RemoteItem -LocalPath $fullPath) {
                    $hash = if ($localChange.ContentHash) { $localChange.ContentHash } else { (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash }
                    $state.Files[$RelativePath] = New-CloudFileStateEntry -Signature $localChange.Signature -RemoteItem $RemoteItem -ContentHash $hash
                    $adopted++
                }
                else {
                    $downloaded = Invoke-CloudPullFile -Config $Config -RelativePath $RelativePath -RemoteItem $RemoteItem -ExpectedSignature $localChange.Signature
                    $state.Files[$RelativePath] = New-CloudFileStateEntry -Signature (Get-CloudLocalSignature $downloaded) -RemoteItem $RemoteItem -ContentHash ((Get-FileHash -LiteralPath $downloaded.FullName -Algorithm SHA256).Hash)
                    $pulled++
                    Write-CloudLog "PULLED $RelativePath"
                }
            }
            elseif (Test-RemoteMatchesLocal -DriveId ([string]$Config.DriveId) -RemoteItem $RemoteItem -LocalPath $fullPath) {
                $hash = if ($localChange.ContentHash) { $localChange.ContentHash } else { (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash }
                $state.Files[$RelativePath] = New-CloudFileStateEntry -Signature $localChange.Signature -RemoteItem $RemoteItem -ContentHash $hash
                $adopted++
            }
            else { throw 'Local and cloud versions both changed; manual conflict review required.' }
        }
    }
    catch {
        $message = "$RelativePath`: $($_.Exception.Message)"
        $errors.Add($message)
        Write-CloudLog "ERROR $message"
    }
    Save-CloudState -State $state
    return [pscustomobject]@{ Pushed = $pushed; Pulled = $pulled; Adopted = $adopted; Failed = $errors.Count; Errors = @($errors) }
}

function Test-CloudBidirectionalRepairEnabled {
    param($Config)
    return [string]$Config.SyncMode -eq 'BidirectionalRepair'
}

function Get-CloudDeltaRelativePath {
    param($Config, $State, $Item)
    $parentPath = [Uri]::UnescapeDataString([string]$Item.parentReference.path)
    $marker = $parentPath.IndexOf('root:', [StringComparison]::OrdinalIgnoreCase)
    if ($marker -ge 0 -and $Item.name) {
        $parent = $parentPath.Substring($marker + 5).TrimStart('/')
        $relative = if ($parent) { ($parent.Replace('/', '\').TrimEnd('\') + '\' + [string]$Item.name) } else { [string]$Item.name }
        try { [void](Resolve-CloudLocalFilePath -Config $Config -RelativePath $relative); return $relative } catch { Write-CloudLog "WARN ignored unsafe Graph delta path: $relative"; return '' }
    }
    if ($Item.id) {
        foreach ($path in @($State.Files.Keys)) {
            if ([string]$State.Files[$path].RemoteId -eq [string]$Item.id) { return [string]$path }
        }
    }
    return ''
}

function Get-CloudRemoteChangedPaths {
    param($Config, [int]$MaxPages = 10)
    $state = Read-CloudState
    $next = if ($state.RemoteDeltaNextLink) { [string]$state.RemoteDeltaNextLink } elseif ($state.RemoteDeltaLink) { [string]$state.RemoteDeltaLink } else {
        ('https://graph.microsoft.com/v1.0/drives/{0}/root/delta?$select=id,name,eTag,size,file,folder,deleted,parentReference,lastModifiedDateTime' -f [Uri]::EscapeDataString([string]$Config.DriveId))
    }
    $changed = [ordered]@{}
    for ($pageNumber = 0; $next -and $pageNumber -lt $MaxPages; $pageNumber++) {
        $page = Invoke-CloudGraph -Method GET -Uri $next
        foreach ($item in @($page.value)) {
            # Ignore folders and only process known paths. Initial delta must never hydrate or bulk-copy a library.
            $isDeleted = $null -ne $item.PSObject.Properties['deleted']
            if ($null -eq $item.file -and -not $isDeleted) { continue }
            $relative = Get-CloudDeltaRelativePath -Config $Config -State $state -Item $item
            if ($relative -and $state.Files.ContainsKey($relative)) { $changed[$relative] = $true }
        }
        $next = [string]$page.'@odata.nextLink'
        if ($next) { $state.RemoteDeltaNextLink = $next }
        else {
            $state.RemoteDeltaNextLink = ''
            $state.RemoteDeltaLink = [string]$page.'@odata.deltaLink'
        }
    }
    # Persist pending paths together with the cursor: a crash must not lose remote changes.
    $state.PendingPaths = @(@($state.PendingPaths) + @($changed.Keys) | Select-Object -Unique)
    Save-CloudState -State $state
    return @($changed.Keys)
}

function Get-CloudReconciliationPaths {
    param($Config, $State, [switch]$KnownOnly)
    $observed = @{}
    foreach ($file in (Get-LocalFiles -Root $Config.SourceRoot)) {
        $relative = $file.FullName.Substring($Config.SourceRoot.Length).TrimStart('\')
        $observed[$relative] = $true
        $signature = '{0}|{1}' -f $file.Length, $file.LastWriteTimeUtc.Ticks
        $previous = $State.Files[$relative]
        if ($null -eq $previous) {
            if (-not $KnownOnly) { $relative }
            continue
        }
        if ($previous.Signature -ne $signature -or -not $previous.ETag) { $relative }
    }
    if ($KnownOnly) {
        foreach ($relative in @($State.Files.Keys)) {
            if ($observed.ContainsKey($relative)) { continue }
            try {
                $fullPath = Resolve-CloudLocalFilePath -Config $Config -RelativePath ([string]$relative)
                # A local cloud-only placeholder is deliberately not treated as deletion; it must not be hydrated.
                if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { [string]$relative }
            }
            catch { Write-CloudLog "WARN ignored unsafe local state path during reconciliation: $relative" }
        }
    }
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
            if (-not (Test-LocalContentPresent -Item $item)) { continue }
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
            # Reject junction/symlink ancestors, including directory events.
            $ancestor = $fullPath
            while ($ancestor.Length -gt $Config.SourceRoot.Length) {
                if (Test-Path -LiteralPath $ancestor) {
                    $entry = Get-Item -LiteralPath $ancestor -Force
                    if (-not [string]::IsNullOrWhiteSpace([string]$entry.LinkType)) { throw 'Linked paths are not allowed.' }
                }
                $ancestor = Split-Path -Parent $ancestor
            }
            if (Test-Path -LiteralPath $fullPath -PathType Container) {
                Get-LocalFiles -Root $fullPath
                continue
            }
            if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { continue }
            $item = Get-Item -LiteralPath $fullPath -Force
            if (-not (Test-LocalContentPresent -Item $item)) { continue }
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
            ((-not $Backfill -and -not $targeted) -or -not [string]::IsNullOrWhiteSpace([string]$previous.ETag))) { continue }
        try {
            $remote = Get-RemoteItem -DriveId ([string]$Config.DriveId) -RelativePath $relative
            if ($null -ne $remote -and $null -eq $remote.file) { throw 'Cloud path is a folder.' }
            if ($targeted -and $null -eq $previous -and $null -ne $remote) {
                # Without a known base, timestamps cannot prove overwrite safety.
                    if (Test-RemoteMatchesLocal -DriveId ([string]$Config.DriveId) -RemoteItem $remote -LocalPath $file.FullName) {
                        $state.Files[$relative] = @{ Signature = $signature; ETag = [string]$remote.eTag }
                        $adopted++
                        continue
                    }
                    throw 'Cloud file has no verified common baseline; manual conflict review required.'
            }
            if (-not $targeted -and $null -eq $previous -and ($null -ne $remote -or -not $Backfill)) {
                # First scan records the folder without uploading its existing contents.
                $etag = if ($null -ne $remote) { [string]$remote.eTag } else { '' }
                $state.Files[$relative] = @{ Signature = $signature; ETag = $etag }
                $adopted++
                continue
            }
            if ($null -ne $previous -and $null -ne $remote -and $previous.ETag -ne [string]$remote.eTag) {
                if (Test-RemoteMatchesLocal -DriveId ([string]$Config.DriveId) -RemoteItem $remote -LocalPath $file.FullName) {
                    $state.Files[$relative] = @{ Signature = $signature; ETag = [string]$remote.eTag }
                    $adopted++
                    continue
                }
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
    $lastAttempt = [DateTime]::MinValue
    if ($failure -and [DateTime]::TryParse([string]$state.LastAlertAttemptUtc, [ref]$lastAttempt) -and
        ([DateTime]::UtcNow - $lastAttempt.ToUniversalTime()).TotalMinutes -lt 60) { $mustSend = $false }
    if (-not $mustSend) { Save-CloudState -State $state -Path $cloudStatePath; return }

    if (-not (Test-Path -LiteralPath $monitorPath)) { Save-CloudState -State $state -Path $cloudStatePath; return }
    $state.LastAlertAttemptUtc = [DateTime]::UtcNow.ToString('o')
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
        if (Send-WebhookAlert -Url ([string]$monitorConfig.WebhookUrl) -Result $resultForAlert -Reason 'cloud-backup' -SendItEmail ([bool]$monitorConfig.NotifyItEmailEnabled)) {
            $state.LastDeliveredFailure = $failure
        }
    }
    catch { }
    Save-CloudState -State $state -Path $cloudStatePath
}

if ($LoadFunctionsOnly) { return }

if ($Setup -and $SetupSharePoint) { throw 'Choose either -Setup or -SetupSharePoint.' }
if ($ResolveWith -and (-not $Once -or -not $Repair -or $RelativePath.Count -ne 1)) {
    throw 'Manual resolution requires -Once -Repair and exactly one -RelativePath.'
}
if ($SetupSharePoint) {
    if (-not $SharePointLibraryUrl -or -not $SourceRoot) {
        throw 'Provide both -SharePointLibraryUrl and -SourceRoot.'
    }
    $root = [IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "Source folder is unavailable: $root" }
    if (Test-Path -LiteralPath $StatePath) {
        throw "Existing backup state belongs to another target or run: $StatePath. Keep it; use a fresh state path or ask IT to migrate it."
    }
    $run = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'OneDriveCloudBackup' -ErrorAction SilentlyContinue
    if ($run -and $run.OneDriveCloudBackup) { throw 'Disable the running cloud backup before changing its target.' }
    $location = Get-SharePointLibraryLocation -Url $SharePointLibraryUrl
    $account = if (-not ($TenantId -or $ClientId -or $CertificateThumbprint)) {
        Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\OneDrive\Accounts\Business1' -ErrorAction Stop
    } else { $null }
    $draft = New-SharePointBackupDraft -Root $root -Location $location -TenantId $TenantId `
        -ClientId $ClientId -CertificateThumbprint $CertificateThumbprint -OneDriveAccount $account
    Connect-CloudGraph -Config $draft -Interactive:($draft.AuthMode -eq 'Delegated')
    $resolved = Resolve-SharePointLibraryDrive -Location $location
    $draft.SiteId = $resolved.SiteId
    $draft.DriveId = $resolved.DriveId
    $draft.LibraryWebUrl = $resolved.LibraryWebUrl
    New-Item -ItemType Directory -Path (Split-Path -Parent $ConfigPath) -Force | Out-Null
    if (Test-Path -LiteralPath $ConfigPath) {
        $backupPath = '{0}.before-sharepoint-{1}.bak' -f $ConfigPath, (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-Item -LiteralPath $ConfigPath -Destination $backupPath -ErrorAction Stop
        Write-Host "Previous backup config preserved at $backupPath"
    }
    $draft | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
    Write-Host "SharePoint source: $root"
    Write-Host "Verified library: $($draft.LibraryWebUrl)"
    Write-Host "Signed-in account: $($draft.Account)"
    Write-Host 'Automatic backup remains OFF. First verify one matching file with -Once -Repair -RelativePath before -Enable.'
    return
}

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
    Write-Host 'Use -Once -Repair -RelativePath "folder\file.ext" to test a verified file. Use -Once -Repair -BaselineAll for a guarded inventory.'
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
    if ($config.TargetType -eq 'SharePoint') {
        $driveUri = [Uri]$check.webUrl
        $expectedUri = [Uri]$config.LibraryWebUrl
        if ($driveUri.Host -ine $expectedUri.Host -or
            [Uri]::UnescapeDataString($driveUri.AbsolutePath).TrimEnd('/') -ine [Uri]::UnescapeDataString($expectedUri.AbsolutePath).TrimEnd('/')) {
            throw 'Configured SharePoint drive no longer matches the verified library URL.'
        }
    }
    $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $command = '"{0}" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}"' -f $powershell, $PSCommandPath
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if (-not (Test-Path -LiteralPath $runKey)) { New-Item -Path $runKey -Force | Out-Null }
    Set-ItemProperty -Path $runKey -Name 'OneDriveCloudBackup' -Value $command -ErrorAction Stop
    if (Test-Path -LiteralPath $StopPath) { Remove-Item -LiteralPath $StopPath -Force }
    Start-Process -FilePath $powershell -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath)) -WindowStyle Hidden | Out-Null
    Write-Host 'Cloud backup enabled for this Windows user.'
    return
}

if ($Once) {
    if ($RelativePath.Count -eq 0 -and -not $BaselineAll) { throw 'Specify -RelativePath for a targeted sync, or -BaselineAll for a full inventory.' }
    Connect-CloudGraph -Config $config
    $targetPaths = if ($RelativePath.Count -gt 0) { $RelativePath } else { $null }
    if ($Repair) {
        $repairPaths = if ($targetPaths) { @($targetPaths) } else {
            @(Get-LocalFiles -Root $config.SourceRoot | ForEach-Object { $_.FullName.Substring($config.SourceRoot.Length).TrimStart('\') })
        }
        $errors = New-Object 'System.Collections.Generic.List[string]'
        $pushed = 0; $pulled = 0; $adopted = 0
        foreach ($path in $repairPaths) {
            $repairArgs = @{ Config = $config; RelativePath = $path }
            if ($ResolveWith) { $repairArgs.ResolveWith = $ResolveWith }
            $repair = Invoke-CloudPathRepair @repairArgs
            $pushed += $repair.Pushed; $pulled += $repair.Pulled; $adopted += $repair.Adopted
            foreach ($errorText in @($repair.Errors)) { $errors.Add([string]$errorText) }
        }
        $result = [pscustomobject]@{ Pushed = $pushed; Pulled = $pulled; Adopted = $adopted; Failed = $errors.Count; Errors = @($errors) }
    }
    else { $result = Invoke-CloudScan -Config $config -Backfill:$Backfill -RelativePaths $targetPaths }
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
$eventNames = @('Changed', 'Created', 'Deleted', 'Renamed', 'Error')
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
$lastAuthCheckUtc = [DateTime]::MinValue
$lastReconcileUtc = [DateTime]::MinValue
$lastRemoteDeltaUtc = [DateTime]::MinValue
$bidirectionalRepair = Test-CloudBidirectionalRepairEnabled -Config $config
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
                Write-CloudLog 'WARN watcher lost events; scheduling local reconciliation.'
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
            $nowUtc = [DateTime]::UtcNow
            if ($state.WatcherOverflow -or ($nowUtc - $lastReconcileUtc).TotalMinutes -ge 5) {
                foreach ($relative in (Get-CloudReconciliationPaths -Config $config -State $state -KnownOnly:$bidirectionalRepair)) { $pending[$relative] = $true }
                $state.PendingPaths = @($pending.Keys)
                $state.WatcherOverflow = $false
                Save-CloudState -State $state
                $lastReconcileUtc = $nowUtc
            }
            if ($lastAuthCheckUtc -eq [DateTime]::MinValue -or $pending.Count -gt 0 -or (Test-CloudAuthCheckDue -Config $config -LastCheckUtc $lastAuthCheckUtc -NowUtc $nowUtc)) {
                Connect-CloudGraph -Config $config
                $lastAuthCheckUtc = $nowUtc
            }
            if ($bidirectionalRepair -and ($nowUtc - $lastRemoteDeltaUtc).TotalMinutes -ge 5) {
                foreach ($relative in (Get-CloudRemoteChangedPaths -Config $config)) { $pending[$relative] = $true }
                $state = Read-CloudState
                $state.PendingPaths = @($pending.Keys)
                Save-CloudState -State $state
                $lastRemoteDeltaUtc = $nowUtc
            }
            foreach ($relative in @($pending.Keys)) {
                # Give the native client a chance and avoid uploading a file still being saved.
                $pendingFile = Join-Path $config.SourceRoot $relative
                if (Test-Path -LiteralPath $pendingFile -PathType Leaf) {
                    if (([DateTime]::UtcNow - (Get-Item -LiteralPath $pendingFile).LastWriteTimeUtc).TotalSeconds -lt 60) { continue }
                }
                $result = if ($bidirectionalRepair) {
                    Invoke-CloudPathRepair -Config $config -RelativePath $relative
                }
                else { Invoke-CloudScan -Config $config -RelativePaths @($relative) }
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
            $lastAuthCheckUtc = [DateTime]::MinValue
            $errors.Add($_.Exception.Message)
            Write-CloudLog "ERROR cloud queue: $($_.Exception.Message)"
        }
        $state = Read-CloudState
        if ($state.WatcherOverflow) { $errors.Add('File watcher lost changes; IT must run a full inventory.') }
        if (-not $NoAlerts) { Send-CloudStatus -Config $config -Result ([pscustomobject]@{ Failed = $errors.Count; Errors = @($errors) }) }
        else {
            $state.LastFailure = @($errors) -join '; '
            Save-CloudState -State $state
        }
        if ($errors.Count -eq 0) {
            $state = Read-CloudState
            $state.LastSuccessfulCycleUtc = [DateTime]::UtcNow.ToString('o')
            Save-CloudState -State $state
        }
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
    Start-Process -FilePath $powershell -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath)) -WindowStyle Hidden | Out-Null
}
