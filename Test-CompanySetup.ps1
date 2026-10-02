[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Setup-CompanyOneDrive.ps1') -LoadFunctionsOnly
function Assert-Setup($Condition, $Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Host "PASS: $Message"
}
$profile = Get-CompanyBackupProfile
Assert-Setup ($profile.ClientId -eq '4f06b4cf-c94e-4eb7-930f-e03daa267193') 'Company app is predetermined'
Assert-Setup ($profile.LibraryWebUrl -eq 'https://aspectengwa.sharepoint.com/sites/Design/Shared%20Documents') 'Only Design library is targeted'
$old = [pscustomobject]@{ TargetType='SharePoint'; AuthMode='Certificate'; TenantId=$profile.TenantId; ClientId=$profile.ClientId; SourceRoot='D:\Design'; LibraryWebUrl=$profile.LibraryWebUrl; SiteId='site1'; DriveId='drive1' }
$new = $old | ConvertTo-Json | ConvertFrom-Json
Assert-Setup (Test-SameBackupTarget $old $new) 'Same target may retain state'
$new.DriveId = 'other'
Assert-Setup (-not (Test-SameBackupTarget $old $new)) 'Different drive cannot reuse state'
$new.DriveId = 'drive1'; $new.SourceRoot = 'D:\Other'
Assert-Setup (-not (Test-SameBackupTarget $old $new)) 'Different local root cannot reuse state'
Assert-Setup (-not (Test-SameBackupTarget ([pscustomobject]@{SourceRoot='D:\OneDrive'}) $old)) 'Legacy personal config is not a verified SharePoint mapping'
Assert-Setup (Test-CompanyLegacyUnverifiedConfig ([pscustomobject]@{SourceRoot='D:\OneDrive'})) 'Legacy one-way config is eligible for safe state archival'
Assert-Setup (-not (Test-CompanyLegacyUnverifiedConfig $old)) 'A complete SharePoint config is never auto-archived'
$migrationRoot = Join-Path $env:TEMP ('CompanyStateMigration-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $migrationRoot | Out-Null
    $legacy = [pscustomobject]@{ SourceRoot = 'D:\OneDrive'; Account = 'legacy@example.com' }
    $legacy | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $migrationRoot 'cloud-backup.json') -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $migrationRoot 'cloud-backup-state.json') -Value '{"Files":{}}' -Encoding UTF8
    Save-CompanyCloudTarget -InstallPath $migrationRoot -Existing $legacy -Target $old
    $stateArchives = @(Get-ChildItem -LiteralPath $migrationRoot -Filter 'cloud-backup-state.json.before-company-*.bak')
    $savedTarget = Get-Content -LiteralPath (Join-Path $migrationRoot 'cloud-backup.json') -Raw | ConvertFrom-Json
    Assert-Setup (-not (Test-Path -LiteralPath (Join-Path $migrationRoot 'cloud-backup-state.json')) -and $stateArchives.Count -eq 1 -and $savedTarget.DriveId -eq 'drive1') 'Legacy state is archived before the verified Design target is saved'
}
finally { if (Test-Path -LiteralPath $migrationRoot) { Remove-Item -LiteralPath $migrationRoot -Recurse -Force } }

# Exercise orchestration, not the live installer, registry, certificate store or Graph.
$script:events = New-Object 'System.Collections.Generic.List[string]'
function Invoke-CompanyInstallFiles { $script:events.Add('install') }
function Initialize-CompanyDependency { $script:events.Add('dependency') }
function Get-CompanyExistingConfig { return $null }
function Resolve-CompanyBackupSource { return [pscustomobject]@{ SourceRoot='D:\Design'; DiscoveryMethod='Registry' } }
function Get-CompanyCertificate { return [pscustomobject]@{Thumbprint=('A'*40)} }
function Resolve-CompanyCloudTarget { $script:events.Add('resolve'); return $old }
function Save-CompanyCloudTarget { $script:events.Add('save') }
function Test-CompanyDirectUpload { $script:events.Add('probe'); if ($script:failProbe) { throw 'probe failed' }; return 'probe.txt' }
function Enable-CompanyBackup { $script:events.Add('enable') }
function Confirm-CompanyWatcher { $script:events.Add('heartbeat'); if ($script:failHeartbeat) { throw 'no heartbeat' } }
function Disable-CompanyBackup { $script:events.Add('disable') }
function Get-CompanyAlertStatus { return 'NotConfigured' }
function Write-CompanySetupResult { param($InstallPath, $Result); $script:lastResult=$Result }
$script:failProbe=$false; $script:failHeartbeat=$false
$result = Invoke-CompanySetup -InstallPath 'C:\FakeInstall'
Assert-Setup (($script:events -join ',') -eq 'install,dependency,resolve,save,probe,enable,heartbeat') 'Cloud probe precedes enabling watcher'
Assert-Setup ($result.BackupVerified -and $result.RemoteAlerts -eq 'NotConfigured') 'Missing alert endpoint is not reported delivered'
$script:events.Clear(); $script:failProbe=$true
try { Invoke-CompanySetup -InstallPath 'C:\FakeInstall'; throw 'Expected probe failure' } catch { Assert-Setup ($_.Exception.Message -eq 'probe failed') 'Probe failure is reported' }
Assert-Setup ('enable' -notin $script:events) 'Failed upload never enables backup'
$script:events.Clear(); $script:failProbe=$false; $script:failHeartbeat=$true
try { Invoke-CompanySetup -InstallPath 'C:\FakeInstall'; throw 'Expected heartbeat failure' } catch { Assert-Setup ($_.Exception.Message -eq 'no heartbeat') 'Watcher failure is reported' }
Assert-Setup ('disable' -in $script:events) 'Failed watcher startup removes automatic backup'
Assert-Setup (-not $script:lastResult.BackupVerified) 'Failed run replaces stale success status'
