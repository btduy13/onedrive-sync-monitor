[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$ReleaseTag,
    [Parameter(Mandatory = $true)][string]$DownloadUrl,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-fA-F]{64}$')][string]$ExpectedSha256,
    [Parameter(Mandatory = $true)][string]$InstallPath,
    [int]$MonitorPid = 0,
    [string]$PowerShellPath = ''
)

$ErrorActionPreference = 'Stop'
$updateFiles = @(
    'OneDriveSyncMonitor.ps1',
    'Update-OneDriveSyncMonitor.ps1',
    'Install-OneDriveSyncMonitor.ps1',
    'Uninstall-OneDriveSyncMonitor.ps1',
    'Setup-OneDriveSyncMonitor.cmd',
    'Test-OneDriveSyncMonitor.ps1',
    'README-OneDriveSyncMonitor-vi.md',
    'version.json'
)
$logPath = Join-Path $InstallPath 'monitor.log'
$stagePath = $null

function Write-UpdaterLog {
    param([Parameter(Mandatory = $true)][string]$Message)
    try {
        Add-Content -LiteralPath $logPath -Value ('{0} INFO updater: {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8
    }
    catch { }
}

function Test-SafeZipEntry {
    param([Parameter(Mandatory = $true)][string]$EntryName)
    $normalized = $EntryName.Replace('/', '\')
    if ([string]::IsNullOrWhiteSpace($normalized) -or [IO.Path]::IsPathRooted($normalized)) { return $false }
    if ($normalized -match '(^|\)\.\.?($|\)') { return $false }
    return $true
}

function Get-ValidatedDownloadUri {
    param([Parameter(Mandatory = $true)][string]$Uri)
    $parsed = [Uri]$Uri
    if ($parsed.Scheme -ne 'https' -or $parsed.Host -notin @('github.com', 'objects.githubusercontent.com')) {
        throw "Refusing release download from unexpected host: $($parsed.Host)"
    }
    return $parsed
}

function Remove-SafeStage {
    if ($null -eq $stagePath -or -not (Test-Path -LiteralPath $stagePath)) { return }
    $resolvedInstall = (Resolve-Path -LiteralPath $InstallPath).Path.TrimEnd('\')
    $resolvedStage = (Resolve-Path -LiteralPath $stagePath).Path
    if (-not $resolvedStage.StartsWith($resolvedInstall + '\.', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove unexpected staging path: $resolvedStage"
    }
    Remove-Item -LiteralPath $resolvedStage -Recurse -Force
}

try {
    if (-not (Test-Path -LiteralPath $InstallPath)) { throw "Install folder does not exist: $InstallPath" }
    $resolvedInstallPath = (Resolve-Path -LiteralPath $InstallPath).Path
    $downloadUri = Get-ValidatedDownloadUri -Uri $DownloadUrl
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $stagePath = Join-Path $resolvedInstallPath ('.OneDriveSyncMonitor-update-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stagePath -Force | Out-Null
    $zipPath = Join-Path $stagePath 'release.zip'
    Invoke-WebRequest -Uri $downloadUri -Headers @{ 'User-Agent' = 'OneDriveSyncMonitor updater' } -OutFile $zipPath -UseBasicParsing -TimeoutSec 60
    $actualHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
    if ($actualHash -ine $ExpectedSha256) {
        throw "Release checksum mismatch. Expected $ExpectedSha256, received $actualHash."
    }

    $extractPath = Join-Path $stagePath 'extracted'
    New-Item -ItemType Directory -Path $extractPath -Force | Out-Null
    $archive = [IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        foreach ($entry in $archive.Entries) {
            if (-not (Test-SafeZipEntry -EntryName $entry.FullName)) { throw "Unsafe ZIP entry: $($entry.FullName)" }
            if ($entry.FullName.EndsWith('/')) { continue }
            $destination = Join-Path $extractPath ($entry.FullName.Replace('/', '\'))
            $destinationParent = Split-Path -Parent $destination
            New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destination, $true)
        }
    }
    finally { $archive.Dispose() }

    foreach ($file in $updateFiles) {
        $source = Join-Path $extractPath $file
        if (-not (Test-Path -LiteralPath $source)) { throw "Release is missing required file: $file" }
    }

    if ($MonitorPid -gt 0) {
        try { Wait-Process -Id $MonitorPid -Timeout 90 -ErrorAction Stop } catch { Write-UpdaterLog "monitor process $MonitorPid did not exit before timeout; continuing" }
    }

    foreach ($file in $updateFiles) {
        Copy-Item -LiteralPath (Join-Path $extractPath $file) -Destination (Join-Path $resolvedInstallPath $file) -Force
    }
    Write-UpdaterLog "updated from $Repository release $ReleaseTag"

    if ([string]::IsNullOrWhiteSpace($PowerShellPath)) {
        $PowerShellPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    }
    $monitorPath = Join-Path $resolvedInstallPath 'OneDriveSyncMonitor.ps1'
    $configPath = Join-Path $resolvedInstallPath 'config.json'
    $restartArguments = @(
        '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass',
        '-File', $monitorPath, '-ConfigPath', $configPath
    )
    Start-Process -FilePath $PowerShellPath -ArgumentList $restartArguments -WorkingDirectory $resolvedInstallPath -WindowStyle Hidden | Out-Null
}
catch {
    Write-UpdaterLog "update failed: $($_.Exception.Message)"
}
finally {
    Remove-SafeStage
}
