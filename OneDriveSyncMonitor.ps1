[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $env:LOCALAPPDATA 'OneDriveSyncMonitor\config.json'),
    [int]$IntervalSeconds = 60,
    [int]$StallMinutes = 15,
    [int]$ReminderMinutes = 60,
    [int]$DiagnosticsStaleMinutes = 30,
    [string]$LogPath = '',
    [string]$StatePath = '',
    [string]$WebhookUrl = '',
    [switch]$Once,
    [switch]$LoadFunctionsOnly,
    [switch]$TestAlert
)

$ErrorActionPreference = 'Stop'
$script:MonitorName = 'OneDriveSyncMonitor'
$script:MonitorVersion = '1.0.3'
$script:DefaultRepository = 'btduy13/onedrive-sync-monitor'
$script:LastUpdateCheckUtc = [DateTime]::MinValue

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Join-Path $env:LOCALAPPDATA 'OneDriveSyncMonitor\monitor.log'
}
if ([string]::IsNullOrWhiteSpace($StatePath)) {
    $StatePath = Join-Path $env:LOCALAPPDATA 'OneDriveSyncMonitor\state.json'
}
if ($IntervalSeconds -lt 15) { $IntervalSeconds = 15 }
if ($StallMinutes -lt 1) { $StallMinutes = 1 }
if ($ReminderMinutes -lt 0) { $ReminderMinutes = 0 }
if ($DiagnosticsStaleMinutes -lt 5) { $DiagnosticsStaleMinutes = 5 }

function Ensure-ParentDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    $parent = Split-Path -Parent -Path $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
}

function Write-MonitorLog {
    param([Parameter(Mandatory = $true)][string]$Message)
    try {
        Ensure-ParentDirectory -Path $LogPath
        $line = '{0} {1}' -f ([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')), $Message
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    }
    catch {
        Write-Host "[$script:MonitorName] Cannot write log: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Get-ProtectedStringPlainText {
    param([string]$ProtectedValue)
    if ([string]::IsNullOrWhiteSpace($ProtectedValue)) { return '' }

    if ($ProtectedValue.Length % 2 -ne 0 -or $ProtectedValue -notmatch '^[0-9a-fA-F]+$') {
        throw 'Protected webhook value is not a Windows DPAPI string.'
    }
    $cipherBytes = New-Object byte[] ($ProtectedValue.Length / 2)
    for ($index = 0; $index -lt $cipherBytes.Length; $index++) {
        $cipherBytes[$index] = [Convert]::ToByte($ProtectedValue.Substring($index * 2, 2), 16)
    }
    Add-Type -AssemblyName System.Security -ErrorAction Stop
    $plainBytes = [Security.Cryptography.ProtectedData]::Unprotect(
        $cipherBytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    try { return [Text.Encoding]::Unicode.GetString($plainBytes) }
    finally { [Array]::Clear($plainBytes, 0, $plainBytes.Length) }
}

function Get-MonitorConfig {
    $config = [ordered]@{
        WebhookUrl              = ''
        ComputerName            = ''
        DiagnosticsStaleMinutes = $DiagnosticsStaleMinutes
        StallMinutes            = $StallMinutes
        ReminderMinutes         = $ReminderMinutes
        AutoUpdateEnabled       = $true
        UpdateCheckHours        = 24
        Repository              = $script:DefaultRepository
    }

    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $raw = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
            if ($null -ne $raw.DiagnosticsStaleMinutes) { $config.DiagnosticsStaleMinutes = [int]$raw.DiagnosticsStaleMinutes }
            if ($null -ne $raw.StallMinutes) { $config.StallMinutes = [int]$raw.StallMinutes }
            if ($null -ne $raw.ReminderMinutes) { $config.ReminderMinutes = [int]$raw.ReminderMinutes }
            if ($null -ne $raw.ComputerName) { $config.ComputerName = [string]$raw.ComputerName }
            if ($null -ne $raw.AutoUpdateEnabled) { $config.AutoUpdateEnabled = [bool]$raw.AutoUpdateEnabled }
            if ($null -ne $raw.UpdateCheckHours) { $config.UpdateCheckHours = [int]$raw.UpdateCheckHours }
            if ($null -ne $raw.Repository) { $config.Repository = [string]$raw.Repository }
            if (-not [string]::IsNullOrWhiteSpace([string]$raw.WebhookUrl)) {
                $config.WebhookUrl = [string]$raw.WebhookUrl
            }
            elseif (-not [string]::IsNullOrWhiteSpace([string]$raw.WebhookUrlProtected)) {
                $config.WebhookUrl = Get-ProtectedStringPlainText -ProtectedValue ([string]$raw.WebhookUrlProtected)
            }
        }
        catch {
            Write-MonitorLog "WARN config could not be read: $($_.Exception.Message)"
            throw
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($WebhookUrl)) { $config.WebhookUrl = $WebhookUrl }
    if ($config.StallMinutes -lt 1) { $config.StallMinutes = 1 }
    if ($config.ReminderMinutes -lt 0) { $config.ReminderMinutes = 0 }
    if ($config.DiagnosticsStaleMinutes -lt 5) { $config.DiagnosticsStaleMinutes = 5 }
    if ($config.UpdateCheckHours -lt 1) { $config.UpdateCheckHours = 24 }
    return $config
}

function ConvertTo-MonitorVersion {
    param([string]$Tag)
    if ([string]::IsNullOrWhiteSpace($Tag)) { return $null }
    $match = [regex]::Match($Tag, '(?<major>\d+)\.(?<minor>\d+)(?:\.(?<patch>\d+))?')
    if (-not $match.Success) { return $null }
    try {
        return [Version]::new(
            [int]$match.Groups['major'].Value,
            [int]$match.Groups['minor'].Value,
            [int]$(if ($match.Groups['patch'].Success) { $match.Groups['patch'].Value } else { '0' })
        )
    }
    catch { return $null }
}

function Get-LatestReleaseInfo {
    param([Parameter(Mandatory = $true)][string]$Repository)
    if ($Repository -notmatch '^[^/\s]+/[^/\s]+$') { throw "Invalid GitHub repository: $Repository" }
    $uri = "https://api.github.com/repos/$Repository/releases/latest"
    $headers = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = "$script:MonitorName/$script:MonitorVersion" }
    return Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -TimeoutSec 15
}

function Set-UpdateAttemptTime {
    $script:LastUpdateCheckUtc = [DateTime]::UtcNow
}

function Start-ReleaseUpdate {
    param(
        [Parameter(Mandatory = $true)]$Release,
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][Version]$ReleaseVersion
    )
    $asset = @($Release.assets | Where-Object { $_.name -eq 'OneDriveSyncMonitor-Setup.zip' }) | Select-Object -First 1
    $checksumAsset = @($Release.assets | Where-Object { $_.name -eq 'OneDriveSyncMonitor-Setup.zip.sha256' }) | Select-Object -First 1
    if ($null -eq $asset -or [string]::IsNullOrWhiteSpace([string]$asset.browser_download_url)) {
        throw 'Latest release does not contain OneDriveSyncMonitor-Setup.zip.'
    }
    if ($null -eq $checksumAsset -or [string]::IsNullOrWhiteSpace([string]$checksumAsset.browser_download_url)) {
        throw 'Latest release does not contain the ZIP checksum asset.'
    }

    $checksumResponse = Invoke-WebRequest -Uri ([string]$checksumAsset.browser_download_url) -Headers @{ 'User-Agent' = $script:MonitorName } -UseBasicParsing -TimeoutSec 15
    $checksumText = if ($checksumResponse.Content -is [byte[]]) {
        [Text.Encoding]::UTF8.GetString($checksumResponse.Content)
    }
    else {
        [string]$checksumResponse.Content
    }
    $expectedHashMatch = [regex]::Match($checksumText, '(?i)\b[0-9a-f]{64}\b')
    if (-not $expectedHashMatch.Success) { throw 'Latest release checksum is invalid or missing.' }

    $updater = Join-Path $PSScriptRoot 'Update-OneDriveSyncMonitor.ps1'
    if (-not (Test-Path -LiteralPath $updater)) { throw "Updater is missing: $updater" }
    $installPath = Split-Path -Parent $updater
    $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $updater,
        '-Repository', $Repository,
        '-ReleaseTag', [string]$Release.tag_name,
        '-DownloadUrl', [string]$asset.browser_download_url,
        '-ExpectedSha256', $expectedHashMatch.Value,
        '-InstallPath', $installPath,
        '-MonitorPid', [string]$PID,
        '-PowerShellPath', $powershell
    )
    Start-Process -FilePath $powershell -ArgumentList $arguments -WindowStyle Hidden -ErrorAction Stop | Out-Null
    Write-MonitorLog "INFO update started: current=$script:MonitorVersion target=$ReleaseVersion tag=$($Release.tag_name)"
    return $true
}

function Invoke-SelfUpdateCheck {
    param([Parameter(Mandatory = $true)]$Config)
    if (-not $Config.AutoUpdateEnabled -or [string]::IsNullOrWhiteSpace([string]$Config.Repository)) { return $false }
    $elapsedHours = ([DateTime]::UtcNow - $script:LastUpdateCheckUtc).TotalHours
    if ($script:LastUpdateCheckUtc -ne [DateTime]::MinValue -and $elapsedHours -lt $Config.UpdateCheckHours) { return $false }
    Set-UpdateAttemptTime
    try {
        $release = Get-LatestReleaseInfo -Repository ([string]$Config.Repository)
        $releaseVersion = ConvertTo-MonitorVersion -Tag ([string]$release.tag_name)
        $currentVersion = ConvertTo-MonitorVersion -Tag $script:MonitorVersion
        if ($null -eq $releaseVersion -or $null -eq $currentVersion) {
            Write-MonitorLog "WARN update skipped: invalid version (current=$script:MonitorVersion, latest=$($release.tag_name))"
            return $false
        }
        if ($releaseVersion -le $currentVersion) {
            Write-MonitorLog "INFO update check: current=$script:MonitorVersion, latest=$($release.tag_name), no update"
            return $false
        }
        return Start-ReleaseUpdate -Release $release -Repository ([string]$Config.Repository) -ReleaseVersion $releaseVersion
    }
    catch {
        Write-MonitorLog "WARN update check failed: $($_.Exception.Message)"
        return $false
    }
}

function Read-KeyValueLog {
    param([Parameter(Mandatory = $true)][string]$Path)
    $values = @{}
    foreach ($line in @(Get-Content -LiteralPath $Path -ErrorAction Stop)) {
        if ($line -match '^\s*([^=\s]+)\s*=\s*(.*?)\s*$') {
            $key = $Matches[1]
            $value = $Matches[2].Trim()
            $number = 0L
            if ([long]::TryParse($value, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
                $values[$key] = $number
            }
            else {
                $values[$key] = $value
            }
        }
    }
    return $values
}

function Get-LongValue {
    param($Map, [string]$Name)
    if ($null -eq $Map -or -not $Map.ContainsKey($Name)) { return 0L }
    $value = 0L
    if ([long]::TryParse([string]$Map[$Name], [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$value)) {
        return $value
    }
    return 0L
}

function Get-ObjectLongValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return 0L }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return 0L }
    $value = 0L
    if ([long]::TryParse([string]$property.Value, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$value)) {
        return $value
    }
    return 0L
}

function Get-StringValue {
    param($Map, [string]$Name)
    if ($null -eq $Map -or -not $Map.ContainsKey($Name)) { return '' }
    return [string]$Map[$Name]
}

function Get-RegistryPropertyValue {
    param($Properties, [string]$Name)
    if ($null -eq $Properties) { return $null }
    $property = $Properties.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-OneDriveAccounts {
    $accounts = @()
    $registryRoot = 'HKCU:\Software\Microsoft\OneDrive\Accounts'

    if (Test-Path -LiteralPath $registryRoot) {
        foreach ($key in @(Get-ChildItem -LiteralPath $registryRoot -ErrorAction SilentlyContinue)) {
            try {
                $properties = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
                $folder = [string](Get-RegistryPropertyValue -Properties $properties -Name 'UserFolder')
                if (-not [string]::IsNullOrWhiteSpace($folder)) {
                    $businessAccount = [string](Get-RegistryPropertyValue -Properties $properties -Name 'Business') -eq '1'
                    $logDirectory = Join-Path $env:LOCALAPPDATA ("Microsoft\OneDrive\logs\{0}" -f $key.PSChildName)
                    $hasDiagnosticsDirectory = Test-Path -LiteralPath $logDirectory
                    # Personal accounts can remain as stale registry entries after sign-out.
                    # Keep them only when their OneDrive log directory still exists.
                    if ($businessAccount -or $hasDiagnosticsDirectory) {
                        $accounts += [pscustomobject]@{
                            Name       = $key.PSChildName
                            Root       = $folder
                            Properties = $properties
                        }
                    }
                }
            }
            catch {
                Write-MonitorLog "WARN cannot read OneDrive registry account $($key.PSChildName): $($_.Exception.Message)"
            }
        }
    }

    # Fallback for machines where the account registry key is not populated yet.
    foreach ($environmentName in @('OneDriveCommercial', 'OneDriveConsumer', 'OneDrive')) {
        $folder = [Environment]::GetEnvironmentVariable($environmentName)
        if ([string]::IsNullOrWhiteSpace($folder)) { continue }
        $alreadyConfigured = @($accounts | Where-Object { $_.Root -eq $folder }).Count -gt 0
        if (-not $alreadyConfigured) {
            $accounts += [pscustomobject]@{
                Name       = $environmentName
                Root       = $folder
                Properties = $null
            }
        }
    }

    return $accounts
}

function New-MonitorIssue {
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][ValidateSet('Warning', 'Critical')][string]$Severity,
        [string]$Account,
        [Parameter(Mandatory = $true)][string]$Message
    )
    return [pscustomobject]@{
        Code     = $Code
        Severity = $Severity
        Account  = $Account
        Message  = $Message
    }
}

function Get-DiagnosticsTimestampUtc {
    param([hashtable]$Diagnostics, [DateTime]$FallbackUtc)
    $raw = Get-StringValue -Map $Diagnostics -Name 'timeUtc'
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        $parsed = [DateTime]::MinValue
        $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
        if ([DateTime]::TryParse($raw, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
            return $parsed.ToUniversalTime()
        }
    }
    return $FallbackUtc
}

function Get-AccountSnapshot {
    param(
        [Parameter(Mandatory = $true)]$Account
    )

    $logDirectory = Join-Path $env:LOCALAPPDATA ("Microsoft\OneDrive\logs\{0}" -f $Account.Name)
    $diagnosticsPath = Join-Path $logDirectory 'SyncDiagnostics.log'
    $diagnostics = @{}
    $diagnosticsExists = Test-Path -LiteralPath $diagnosticsPath
    $diagnosticsLastWriteUtc = [DateTime]::MinValue

    if ($diagnosticsExists) {
        try {
            $diagnosticsFile = Get-Item -LiteralPath $diagnosticsPath -ErrorAction Stop
            $diagnosticsLastWriteUtc = $diagnosticsFile.LastWriteTimeUtc
            $diagnostics = Read-KeyValueLog -Path $diagnosticsPath
        }
        catch {
            Write-MonitorLog "WARN cannot read $diagnosticsPath : $($_.Exception.Message)"
        }
    }

    $nowUtc = [DateTime]::UtcNow
    $diagnosticsAge = $null
    if ($diagnosticsLastWriteUtc -ne [DateTime]::MinValue) {
        $diagnosticsAge = [math]::Max(0, [math]::Round(($nowUtc - $diagnosticsLastWriteUtc).TotalMinutes, 1))
    }

    $snapshot = [ordered]@{
        Name                  = $Account.Name
        Root                  = $Account.Root
        RootExists            = (Test-Path -LiteralPath $Account.Root)
        DiagnosticsPath       = $diagnosticsPath
        DiagnosticsExists     = $diagnosticsExists
        DiagnosticsAgeMinutes = $diagnosticsAge
        DiagnosticsUtc        = if ($diagnosticsExists) { (Get-DiagnosticsTimestampUtc -Diagnostics $diagnostics -FallbackUtc $diagnosticsLastWriteUtc).ToString('o') } else { $null }
        OnlineStatus          = [string](Get-RegistryPropertyValue -Properties $Account.Properties -Name 'GetOnlineStatus')
        LastSignInResult      = [string](Get-RegistryPropertyValue -Properties $Account.Properties -Name 'LastSignInResult')
        ErrorCounters         = [ordered]@{
            FailedUploads  = Get-LongValue -Map $diagnostics -Name 'numFileFailedUploads'
            FailedDownloads = Get-LongValue -Map $diagnostics -Name 'numFileFailedDownloads'
            Warnings       = Get-LongValue -Map $diagnostics -Name 'numFileInWarning'
            UploadErrors   = Get-LongValue -Map $diagnostics -Name 'numUploadErrorsReported'
            RealizerErrors = Get-LongValue -Map $diagnostics -Name 'numRealizerErrorsReported'
            SyncStall      = Get-LongValue -Map $diagnostics -Name 'syncStallDetected'
            ScanStall      = Get-LongValue -Map $diagnostics -Name 'scanStateStallDetected'
        }
        Progress              = [ordered]@{
            PendingChanges           = Get-LongValue -Map $diagnostics -Name 'numLocalChanges'
            SyncProgressState         = Get-LongValue -Map $diagnostics -Name 'syncProgressState'
            FilesUploaded             = Get-LongValue -Map $diagnostics -Name 'numFileUploads'
            FilesDownloaded           = Get-LongValue -Map $diagnostics -Name 'numFileDownloads'
            SuccessfulBytesUploaded   = Get-LongValue -Map $diagnostics -Name 'successfulBytesUploadedTotal'
            SuccessfulBytesDownloaded = Get-LongValue -Map $diagnostics -Name 'successfulBytesDownloadedTotal'
        }
        NoProgressSinceUtc    = $null
    }

    return [pscustomobject]$snapshot
}

function Get-PreviousAccount {
    param($State, [string]$Name)
    if ($null -eq $State -or $null -eq $State.Accounts) { return $null }
    $property = $State.Accounts.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Add-AccountIssues {
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        $PreviousSnapshot,
        [Parameter(Mandatory = $true)][int]$StaleMinutes,
        [Parameter(Mandatory = $true)][int]$StallMinutes,
        [Parameter(Mandatory = $true)][ref]$Issues
    )

    if (-not $Snapshot.RootExists) {
        $Issues.Value += New-MonitorIssue -Code 'Account.RootMissing' -Severity Critical -Account $Snapshot.Name -Message "Sync folder is missing or inaccessible: $($Snapshot.Root)"
    }
    if (-not $Snapshot.DiagnosticsExists) {
        $Issues.Value += New-MonitorIssue -Code 'Account.DiagnosticsMissing' -Severity Warning -Account $Snapshot.Name -Message 'SyncDiagnostics.log is missing; OneDrive health cannot be verified.'
    }
    elseif ($null -ne $Snapshot.DiagnosticsAgeMinutes -and $Snapshot.DiagnosticsAgeMinutes -gt $StaleMinutes -and $Snapshot.Progress.PendingChanges -gt 0) {
        $Issues.Value += New-MonitorIssue -Code 'Account.DiagnosticsStale' -Severity Warning -Account $Snapshot.Name -Message "OneDrive diagnostics have not changed for $($Snapshot.DiagnosticsAgeMinutes) minutes."
    }

    if ($Snapshot.Progress.PendingChanges -gt 0 -and $null -ne $PreviousSnapshot) {
        $progressMoved = $false
        foreach ($fieldName in @('FilesUploaded', 'FilesDownloaded', 'SuccessfulBytesUploaded', 'SuccessfulBytesDownloaded')) {
            $previousValue = Get-ObjectLongValue -Object $PreviousSnapshot.Progress -Name $fieldName
            if ([long]$Snapshot.Progress.$fieldName -ne $previousValue) { $progressMoved = $true; break }
        }
        if (-not $progressMoved) {
            $since = if ($PreviousSnapshot.NoProgressSinceUtc) { [string]$PreviousSnapshot.NoProgressSinceUtc } else { [DateTime]::UtcNow.ToString('o') }
            $Snapshot.NoProgressSinceUtc = $since
            $sinceTime = [DateTime]::MinValue
            if ([DateTime]::TryParse($since, [ref]$sinceTime)) {
                $minutes = ([DateTime]::UtcNow - $sinceTime.ToUniversalTime()).TotalMinutes
                if ($minutes -ge $StallMinutes) {
                    $Issues.Value += New-MonitorIssue -Code 'Sync.NoProgress' -Severity Critical -Account $Snapshot.Name -Message "$($Snapshot.Progress.PendingChanges) local change(s) pending with no upload/download progress for $([math]::Round($minutes, 1)) minutes."
                }
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($Snapshot.OnlineStatus) -and $Snapshot.OnlineStatus -ne 'Completed') {
        $Issues.Value += New-MonitorIssue -Code 'Account.OnlineStatus' -Severity Critical -Account $Snapshot.Name -Message "OneDrive account online check is '$($Snapshot.OnlineStatus)'."
    }
    if (-not [string]::IsNullOrWhiteSpace($Snapshot.LastSignInResult) -and $Snapshot.LastSignInResult -ne '0') {
        $Issues.Value += New-MonitorIssue -Code 'Account.SignIn' -Severity Critical -Account $Snapshot.Name -Message "OneDrive sign-in result is '$($Snapshot.LastSignInResult)'."
    }

    $counters = $Snapshot.ErrorCounters
    $previousCounters = if ($null -ne $PreviousSnapshot) { $PreviousSnapshot.ErrorCounters } else { $null }
    if ($counters.SyncStall -gt 0) {
        $Issues.Value += New-MonitorIssue -Code 'Sync.Stall' -Severity Critical -Account $Snapshot.Name -Message "OneDrive reports a sync stall (syncStallDetected=$($counters.SyncStall))."
    }
    if ($counters.ScanStall -gt 0) {
        $Issues.Value += New-MonitorIssue -Code 'Sync.ScanStall' -Severity Critical -Account $Snapshot.Name -Message "OneDrive reports a scan stall (scanStateStallDetected=$($counters.ScanStall))."
    }

    $failureFields = @(
        @{ Name = 'FailedUploads'; Label = 'failed upload(s)' },
        @{ Name = 'FailedDownloads'; Label = 'failed download(s)' },
        @{ Name = 'Warnings'; Label = 'file warning(s)' },
        @{ Name = 'UploadErrors'; Label = 'upload error event(s)' },
        @{ Name = 'RealizerErrors'; Label = 'file realization error(s)' }
    )
    foreach ($field in $failureFields) {
        $value = [long]$counters.($field.Name)
        if ($value -le 0) { continue }
        $Issues.Value += New-MonitorIssue -Code ("Sync.{0}" -f $field.Name) -Severity Warning -Account $Snapshot.Name -Message "OneDrive reports $value $($field.Label)."
    }
}

function Get-HealthStatus {
    param([array]$Issues)
    if (@($Issues | Where-Object { $_.Severity -eq 'Critical' }).Count -gt 0) { return 'Critical' }
    if (@($Issues | Where-Object { $_.Severity -eq 'Warning' }).Count -gt 0) { return 'Warning' }
    return 'Healthy'
}

function Get-IssueFingerprint {
    param([array]$Issues)
    if (@($Issues).Count -eq 0) { return 'Healthy' }
    return (@($Issues | Sort-Object Code, Account | ForEach-Object {
        '{0}|{1}|{2}' -f $_.Code, $_.Severity, $_.Account
    }) -join ' || ')
}

function Read-MonitorState {
    if (-not (Test-Path -LiteralPath $StatePath)) { return $null }
    try {
        return Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    }
    catch {
        Write-MonitorLog "WARN state file could not be read: $($_.Exception.Message)"
        return $null
    }
}

function Write-MonitorState {
    param([Parameter(Mandatory = $true)]$State)
    try {
        Ensure-ParentDirectory -Path $StatePath
        $tempPath = "$StatePath.tmp"
        $State | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $tempPath -Encoding UTF8
        Move-Item -LiteralPath $tempPath -Destination $StatePath -Force
    }
    catch {
        Write-MonitorLog "WARN state file could not be saved: $($_.Exception.Message)"
    }
}

function Send-WebhookAlert {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Url,
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)][string]$Reason
    )
    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }

    $payload = [ordered]@{
        type         = 'message'
        attachments  = @(
            [ordered]@{
                contentType = 'application/vnd.microsoft.card.adaptive'
                contentUrl  = $null
                content     = [ordered]@{
                    '$schema' = 'http://adaptivecards.io/schemas/adaptive-card.json'
                    type      = 'AdaptiveCard'
                    version   = '1.2'
                    body      = @(
                        [ordered]@{ type = 'TextBlock'; text = "OneDrive $($Result.Status) - $($Result.Computer)"; weight = 'Bolder'; size = 'Medium' },
                        [ordered]@{ type = 'TextBlock'; text = $Result.Text; wrap = $true }
                    )
                }
            }
        )
        monitor      = $script:MonitorName
        status       = $Result.Status
        reason       = $Reason
        timestampUtc = $Result.TimestampUtc
        timestampLocal = $Result.TimestampLocal
        computer     = $Result.Computer
        recipient    = 'it@aspectengineering.com.au'
        text         = $Result.Text
        user         = "$env:USERDOMAIN\$env:USERNAME"
        issues       = @($Result.Issues | ForEach-Object {
            [ordered]@{ code = $_.Code; severity = $_.Severity; account = $_.Account; message = $_.Message }
        })
        accounts     = @($Result.Accounts | ForEach-Object {
            [ordered]@{
                name              = $_.Name
                root              = $_.Root
                rootExists        = $_.RootExists
                diagnosticsAgeMin = $_.DiagnosticsAgeMinutes
                progress          = $_.Progress
                errorCounters     = $_.ErrorCounters
            }
        })
    }

    try {
        $json = $payload | ConvertTo-Json -Depth 10
        Invoke-RestMethod -Uri $Url -Method Post -ContentType 'application/json' -Body $json -TimeoutSec 15 | Out-Null
        Write-MonitorLog "INFO webhook sent: status=$($Result.Status), reason=$Reason"
        return $true
    }
    catch {
        Write-MonitorLog "ERROR webhook failed: $($_.Exception.Message)"
        return $false
    }
}

function Invoke-OneDriveCheck {
    $config = Get-MonitorConfig
    $state = Read-MonitorState
    $issues = @()
    $processes = @(Get-Process -Name 'OneDrive' -ErrorAction SilentlyContinue)
    $accounts = @(Get-OneDriveAccounts)
    $accountSnapshots = @()

    if ($processes.Count -eq 0) {
        $issues += New-MonitorIssue -Code 'Process.Stopped' -Severity Critical -Message 'OneDrive.exe is not running.'
    }
    elseif (@($processes | Where-Object { $_.Responding -eq $false }).Count -gt 0) {
        $issues += New-MonitorIssue -Code 'Process.NotResponding' -Severity Critical -Message 'OneDrive.exe is running but not responding.'
    }
    if ($accounts.Count -eq 0) {
        $issues += New-MonitorIssue -Code 'Account.NotConfigured' -Severity Critical -Message 'No OneDrive account with a configured local sync folder was found.'
    }

    foreach ($account in $accounts) {
        $snapshot = Get-AccountSnapshot -Account $account
        $previousSnapshot = Get-PreviousAccount -State $state -Name $snapshot.Name
        Add-AccountIssues -Snapshot $snapshot -PreviousSnapshot $previousSnapshot -StaleMinutes $config.DiagnosticsStaleMinutes -StallMinutes $config.StallMinutes -Issues ([ref]$issues)
        $accountSnapshots += $snapshot
    }

    $status = Get-HealthStatus -Issues $issues
    $fingerprint = Get-IssueFingerprint -Issues $issues
    $timestampUtc = [DateTime]::UtcNow.ToString('o')
    $timestampLocal = [DateTimeOffset]::Now.ToString('yyyy-MM-dd HH:mm:ss zzz')
    $computer = if (-not [string]::IsNullOrWhiteSpace([string]$config.ComputerName)) { [string]$config.ComputerName } else { $env:COMPUTERNAME }
    $issueText = if ($issues.Count -eq 0) { 'OneDrive sync has recovered.' } else { @($issues | ForEach-Object { "[$($_.Severity)] $($_.Account): $($_.Message)" }) -join '; ' }
    $result = [pscustomobject]@{
        Status       = $status
        Fingerprint  = $fingerprint
        TimestampUtc = $timestampUtc
        TimestampLocal = $timestampLocal
        Issues       = @($issues)
        Accounts     = @($accountSnapshots)
        ProcessCount = $processes.Count
        Computer     = $computer
        Text         = "OneDrive $status | $computer | $timestampLocal | $issueText"
    }

    $newFailure = $false
    foreach ($snapshot in $accountSnapshots) {
        $previousSnapshot = Get-PreviousAccount -State $state -Name $snapshot.Name
        if ($null -eq $previousSnapshot) { continue }
        foreach ($fieldName in @('FailedUploads', 'FailedDownloads', 'Warnings', 'UploadErrors', 'RealizerErrors')) {
            $priorCount = Get-ObjectLongValue -Object $previousSnapshot.ErrorCounters -Name $fieldName
            if ([long]$snapshot.ErrorCounters.$fieldName -gt $priorCount) { $newFailure = $true }
        }
    }

    $sendAlert = $false
    $reason = 'initial'
    if ($null -eq $state) {
        $sendAlert = $status -ne 'Healthy'
    }
    else {
        if ($state.Fingerprint -ne $fingerprint -or $state.Status -ne $status) {
            $sendAlert = $true
            $reason = if ($status -eq 'Healthy') { 'recovered' } else { 'state-changed' }
        }
        elseif ($newFailure) {
            $sendAlert = $true
            $reason = 'new-failure'
        }
        elseif ($status -ne 'Healthy' -and $config.ReminderMinutes -gt 0 -and $state.LastAlertUtc) {
            $lastAlert = [DateTime]::MinValue
            if ([DateTime]::TryParse([string]$state.LastAlertUtc, [ref]$lastAlert)) {
                if (([DateTime]::UtcNow - $lastAlert.ToUniversalTime()).TotalMinutes -ge $config.ReminderMinutes) {
                    $sendAlert = $true
                    $reason = 'reminder'
                }
            }
        }
    }

    $lastAlertUtc = if ($null -ne $state) { [string]$state.LastAlertUtc } else { $null }
    $lastDeliveredFingerprint = if ($null -ne $state) { [string]$state.LastDeliveredFingerprint } else { $null }
    $lastAttemptUtc = if ($null -ne $state) { [string]$state.LastAttemptUtc } else { $null }
    $pendingAlerts = @()
    if ($null -ne $state -and $null -ne $state.PendingAlerts) { $pendingAlerts = @($state.PendingAlerts) }

    if ($reason -eq 'reminder' -and @($pendingAlerts | Where-Object { $_.Result.Fingerprint -eq $fingerprint }).Count -gt 0) {
        $sendAlert = $false
    }
    if ($sendAlert) {
        $pendingAlerts += [pscustomobject]@{ Result = $result; Reason = $reason }
        Write-MonitorLog "ALERT queued: status=$status, reason=$reason"
    }

    $retryDue = $sendAlert
    if (-not $retryDue -and $pendingAlerts.Count -gt 0) {
        $lastAttempt = [DateTime]::MinValue
        $retryDue = -not $lastAttemptUtc
        if (-not $retryDue -and [DateTime]::TryParse($lastAttemptUtc, [ref]$lastAttempt)) {
            $retryDue = ([DateTime]::UtcNow - $lastAttempt.ToUniversalTime()).TotalMinutes -ge 5
        }
    }
    if ($retryDue -and $pendingAlerts.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$config.WebhookUrl)) {
        $lastAttemptUtc = $timestampUtc
        $remaining = @()
        for ($index = 0; $index -lt $pendingAlerts.Count; $index++) {
            $queued = $pendingAlerts[$index]
            if (Send-WebhookAlert -Url ([string]$config.WebhookUrl) -Result $queued.Result -Reason ([string]$queued.Reason)) {
                $lastAlertUtc = [DateTime]::UtcNow.ToString('o')
                $lastDeliveredFingerprint = [string]$queued.Result.Fingerprint
            }
            else {
                $remaining = @($pendingAlerts | Select-Object -Skip $index)
                break
            }
        }
        $pendingAlerts = $remaining
    }

    $stateAccounts = [ordered]@{}
    foreach ($snapshot in $accountSnapshots) {
        $stateAccounts[$snapshot.Name] = $snapshot
    }
    Write-MonitorState -State ([ordered]@{
        Version      = 1
        LastCheckUtc = $timestampUtc
        LastAlertUtc = $lastAlertUtc
        LastDeliveredFingerprint = $lastDeliveredFingerprint
        LastAttemptUtc = $lastAttemptUtc
        PendingAlert = ($pendingAlerts.Count -gt 0)
        PendingAlerts = @($pendingAlerts)
        Status       = $status
        Fingerprint  = $fingerprint
        Accounts     = $stateAccounts
    })

    $summary = if ($issues.Count -eq 0) { 'no issues' } else { (@($issues | ForEach-Object { "$($_.Severity):$($_.Code)" }) -join ', ') }
    $transition = if ($null -eq $state -or $state.Status -ne $status -or $state.Fingerprint -ne $fingerprint) { 'changed' } else { 'unchanged' }
    Write-MonitorLog "STATUS $status ($transition), process=$($processes.Count), accounts=$($accounts.Count), $summary"
    Write-Host ("{0} [{1}] OneDrive process={2}, accounts={3}; {4}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $status, $processes.Count, $accounts.Count, $summary)
    return $result
}

if ($LoadFunctionsOnly) { return }

if ($TestAlert) {
    $testConfig = Get-MonitorConfig
    if ([string]::IsNullOrWhiteSpace([string]$testConfig.WebhookUrl)) { throw 'A webhook URL is required for -TestAlert.' }
    $testComputer = if ([string]::IsNullOrWhiteSpace([string]$testConfig.ComputerName)) { $env:COMPUTERNAME } else { [string]$testConfig.ComputerName }
    $testTime = [DateTime]::UtcNow.ToString('o')
    $testLocalTime = [DateTimeOffset]::Now.ToString('yyyy-MM-dd HH:mm:ss zzz')
    $testResult = [pscustomobject]@{
        Status = 'Test'
        TimestampUtc = $testTime
        TimestampLocal = $testLocalTime
        Computer = $testComputer
        Text = "TEST ONLY | OneDrive monitor | $testComputer | $testLocalTime"
        Issues = @()
        Accounts = @()
    }
    if (-not (Send-WebhookAlert -Url ([string]$testConfig.WebhookUrl) -Result $testResult -Reason 'test')) { throw 'Test alert could not be delivered. Check monitor.log.' }
    Write-Host "Test alert sent for $testComputer"
    return
}

Write-MonitorLog "INFO monitor started (version=$script:MonitorVersion, interval=${IntervalSeconds}s, stale=${DiagnosticsStaleMinutes}m, reminder=${ReminderMinutes}m, once=$Once)"
if ($Once) {
    Invoke-OneDriveCheck | Out-Null
    return
}

while ($true) {
    try {
        Invoke-OneDriveCheck | Out-Null
        if (Invoke-SelfUpdateCheck -Config (Get-MonitorConfig)) { break }
    }
    catch {
        Write-MonitorLog "ERROR monitor cycle failed: $($_.Exception.Message)"
    }
    Start-Sleep -Seconds $IntervalSeconds
}
