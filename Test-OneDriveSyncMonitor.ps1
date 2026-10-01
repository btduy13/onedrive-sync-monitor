[CmdletBinding()]
param([string]$MonitorPath = '')

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($MonitorPath)) { $MonitorPath = Join-Path $PSScriptRoot 'OneDriveSyncMonitor.ps1' }
$testRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'work'
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
$testDirectory = Join-Path $testRoot ('OneDriveSyncMonitor-Test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testDirectory -Force | Out-Null
$testState = Join-Path $testDirectory 'state.json'
$testLog = Join-Path $testDirectory 'monitor.log'

try {
    . $MonitorPath -LoadFunctionsOnly -ConfigPath (Join-Path $testDirectory 'config.json') -StatePath $testState -LogPath $testLog -WebhookUrl 'http://localhost/test' -StallMinutes 1

    $script:FixtureFailedUploads = 0
    $script:FixturePendingChanges = 0
    $script:FixtureProcessPresent = $true
    $script:WebhookFail = $false
    $script:Payloads = @()

    function Get-Process {
        param([string]$Name, [string]$ErrorAction)
        if ($script:FixtureProcessPresent) { return [pscustomobject]@{ Responding = $true } }
        return @()
    }
    function Get-OneDriveAccounts {
        return [pscustomobject]@{ Name = 'Business1'; Root = 'C:\TestOneDrive'; Properties = $null }
    }
    function Get-AccountSnapshot {
        param($Account)
        return [pscustomobject]@{
            Name = $Account.Name
            Root = $Account.Root
            RootExists = $true
            DiagnosticsExists = $true
            DiagnosticsAgeMinutes = 0
            OnlineStatus = 'Completed'
            LastSignInResult = '0'
            ErrorCounters = [pscustomobject]@{
                FailedUploads = $script:FixtureFailedUploads
                FailedDownloads = 0
                Warnings = 0
                UploadErrors = 0
                RealizerErrors = 0
                SyncStall = 0
                ScanStall = 0
            }
            Progress = [pscustomobject]@{
                PendingChanges = $script:FixturePendingChanges
                FilesUploaded = 10
                FilesDownloaded = 0
                SuccessfulBytesUploaded = 1000
                SuccessfulBytesDownloaded = 0
            }
            NoProgressSinceUtc = $null
        }
    }
    function Invoke-RestMethod {
        param($Uri, $Method, $ContentType, $Body, $TimeoutSec)
        if ($script:WebhookFail) { throw 'Simulated network failure' }
        $script:Payloads += ($Body | ConvertFrom-Json)
        return [pscustomobject]@{ accepted = $true }
    }
    function Assert-Test {
        param([bool]$Condition, [string]$Message)
        if (-not $Condition) { throw "FAIL: $Message" }
        Write-Host "PASS: $Message"
    }

    $result = Invoke-OneDriveCheck
    Assert-Test ($result.Status -eq 'Healthy' -and $script:Payloads.Count -eq 0) 'Healthy baseline does not alert'

    $script:FixtureFailedUploads = 1
    $result = Invoke-OneDriveCheck
    Assert-Test ($result.Status -eq 'Warning' -and $script:Payloads.Count -eq 1) 'First failed upload sends an alert'
    Assert-Test ($script:Payloads[0].recipient -eq 'it@aspectengineering.com.au' -and $script:Payloads[0].computer -eq $env:COMPUTERNAME) 'Alert contains IT recipient and machine name'
    Assert-Test ($script:Payloads[0].type -eq 'message' -and $script:Payloads[0].attachments[0].content.type -eq 'AdaptiveCard') 'Webhook payload uses the Teams Adaptive Card format'

    $result = Invoke-OneDriveCheck
    Assert-Test ($script:Payloads.Count -eq 1) 'Unchanged failure does not send duplicate alerts'

    $script:FixtureFailedUploads = 2
    $result = Invoke-OneDriveCheck
    Assert-Test ($script:Payloads.Count -eq 2 -and $script:Payloads[1].reason -eq 'new-failure') 'New failed upload sends another alert'

    $script:FixtureFailedUploads = 0
    $script:FixturePendingChanges = 2
    $result = Invoke-OneDriveCheck
    $state = Get-Content -LiteralPath $testState -Raw | ConvertFrom-Json
    $state.Accounts.Business1.NoProgressSinceUtc = [DateTime]::UtcNow.AddMinutes(-2).ToString('o')
    $state | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $testState -Encoding UTF8
    $result = Invoke-OneDriveCheck
    Assert-Test ($result.Status -eq 'Critical' -and @($result.Issues | Where-Object { $_.Code -eq 'Sync.NoProgress' }).Count -eq 1) "Pending changes without progress trigger a stall alert (status=$($result.Status), since=$($result.Accounts[0].NoProgressSinceUtc), issues=$(@($result.Issues | ForEach-Object { $_.Code }) -join ','))"

    $script:FixturePendingChanges = 0
    $script:FixtureProcessPresent = $false
    $result = Invoke-OneDriveCheck
    Assert-Test (@($result.Issues | Where-Object { $_.Code -eq 'Process.Stopped' }).Count -eq 1) 'Stopped OneDrive process triggers a critical alert'

    $script:FixtureProcessPresent = $true
    $result = Invoke-OneDriveCheck
    Assert-Test ($result.Status -eq 'Healthy' -and $script:Payloads[-1].reason -eq 'recovered') 'Recovery sends an alert'

    $script:WebhookFail = $true
    $script:FixtureFailedUploads = 3
    $result = Invoke-OneDriveCheck
    $state = Get-Content -LiteralPath $testState -Raw | ConvertFrom-Json
    Assert-Test ($state.PendingAlert -eq $true) 'Failed webhook delivery remains pending'

    $script:FixtureFailedUploads = 0
    $result = Invoke-OneDriveCheck
    $state = Get-Content -LiteralPath $testState -Raw | ConvertFrom-Json
    Assert-Test ($state.PendingAlerts.Count -eq 2) 'Failure and recovery are queued while offline'

    $script:WebhookFail = $false
    $state.LastAttemptUtc = [DateTime]::UtcNow.AddMinutes(-6).ToString('o')
    $state | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $testState -Encoding UTF8
    $payloadCountBeforeRetry = $script:Payloads.Count
    $result = Invoke-OneDriveCheck
    $state = Get-Content -LiteralPath $testState -Raw | ConvertFrom-Json
    Assert-Test ($state.PendingAlert -eq $false -and $script:Payloads.Count -eq ($payloadCountBeforeRetry + 2)) 'Queued alerts retry after connectivity returns'
    Assert-Test ($script:Payloads[-2].status -eq 'Warning' -and $script:Payloads[-1].status -eq 'Healthy') 'Original failure arrives before recovery'

    Write-Host 'All OneDrive monitor tests passed.'
}
finally {
    if (Test-Path -LiteralPath $testDirectory) {
        $resolvedTestRoot = (Resolve-Path -LiteralPath $testRoot).Path.TrimEnd('\')
        $resolvedTestDirectory = (Resolve-Path -LiteralPath $testDirectory).Path
        if (-not $resolvedTestDirectory.StartsWith($resolvedTestRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove unexpected test path: $resolvedTestDirectory"
        }
        Remove-Item -LiteralPath $testDirectory -Recurse -Force
    }
}
