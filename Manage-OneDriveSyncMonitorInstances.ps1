# Shared, current-user instance cleanup for install and uninstall. Dot-source only.
function Test-SafeMonitorInstallPath {
    param([string]$InstallPath)
    if ([string]::IsNullOrWhiteSpace($InstallPath) -or -not [IO.Path]::IsPathRooted($InstallPath)) { return $false }
    try {
        $root = [IO.Path]::GetFullPath($InstallPath).TrimEnd('\')
        $local = [IO.Path]::GetFullPath($env:LOCALAPPDATA).TrimEnd('\')
        return $root.StartsWith($local + '\', [StringComparison]::OrdinalIgnoreCase) -and
            -not ($root -match '^[A-Za-z]:$')
    }
    catch { return $false }
}

function Test-MonitorScriptCommand {
    param([string]$CommandLine, [string]$ScriptPath)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $false }
    $match = [regex]::Match($CommandLine, '(?i)(?:^|\s)-File\s+(?:"([^"]+)"|(\S+))')
    if (-not $match.Success) { return $false }
    if ($CommandLine.Substring(0, $match.Index) -match '(?i)(?:^|\s)-(?:Command|EncodedCommand|C|Enc)(?:\s|$)') { return $false }
    $found = if ($match.Groups[1].Success) { $match.Groups[1].Value } else { $match.Groups[2].Value }
    try {
        return [IO.Path]::GetFullPath($found).TrimEnd('\') -ieq [IO.Path]::GetFullPath($ScriptPath).TrimEnd('\')
    }
    catch { return $false }
}

function Test-MonitorProcessIdentity {
    param([string]$CommandLine, [string]$MonitorPath, [string]$BackupPath)
    return (Test-MonitorScriptCommand -CommandLine $CommandLine -ScriptPath $MonitorPath) -or
        (Test-MonitorScriptCommand -CommandLine $CommandLine -ScriptPath $BackupPath) -or
        (Test-MonitorScriptCommand -CommandLine $CommandLine -ScriptPath (Join-Path (Split-Path $MonitorPath -Parent) 'MultiLibrarySync.ps1'))
}

function Test-MonitorProcessStillRunning {
    param([int]$ProcessId, [string]$MonitorPath, [string]$BackupPath)
    $candidate = Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $ProcessId) -ErrorAction SilentlyContinue
    if (-not $candidate) { return $false }
    return Test-MonitorProcessIdentity -CommandLine ([string]$candidate.CommandLine) -MonitorPath $MonitorPath -BackupPath $BackupPath
}

function Test-MonitorStartupCommand {
    param([string]$CommandLine, [string]$TargetPath)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $false }
    $match = [regex]::Match($CommandLine.Trim(), '^(?:"([^"]+)"|(\S+))$')
    if (-not $match.Success) { return $false }
    $found = if ($match.Groups[1].Success) { $match.Groups[1].Value } else { $match.Groups[2].Value }
    try { return [IO.Path]::GetFullPath($found).TrimEnd('\') -ieq [IO.Path]::GetFullPath($TargetPath).TrimEnd('\') }
    catch { return $false }
}

function Stop-OneDriveMonitorInstances {
    param([Parameter(Mandatory = $true)][string]$InstallPath)
    if (-not (Test-SafeMonitorInstallPath -InstallPath $InstallPath)) {
        throw 'Refusing to clean instances outside the current-user LOCALAPPDATA install folder.'
    }
    $root = [IO.Path]::GetFullPath($InstallPath).TrimEnd('\')
    $monitor = Join-Path $root 'OneDriveSyncMonitor.ps1'
    $backup = Join-Path $root 'OneDriveCloudBackup.ps1'
    $tray = Join-Path $root 'OneDriveSyncMonitorTray.exe'
    $taskName = 'OneDrive Sync Monitor'
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($task) {
        $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $taskUser = [string]$task.Principal.UserId
        $taskOwned = $false
        if ($taskUser) {
            try {
                $taskSid = if ($taskUser -match '^S-1-') { $taskUser } else {
                    ([Security.Principal.NTAccount]::new($taskUser)).Translate([Security.Principal.SecurityIdentifier]).Value
                }
                $taskOwned = $taskSid -eq [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            } catch { $taskOwned = $false }
        }
        if (-not $taskOwned) {
            throw "Task '$taskName' belongs to '$taskUser', not '$currentUser'; refusing to remove it."
        }
        $owned = @($task.Actions | Where-Object { Test-MonitorScriptCommand -CommandLine ([string]$_.Arguments) -ScriptPath $monitor }).Count -gt 0
        if (-not $owned) { throw "Task '$taskName' points elsewhere; refusing to remove or replace it." }
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
    }

    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $backupWasEnabled = $false
    $multiWasEnabled = $false
    if (Test-Path -LiteralPath $runKey) {
        $run = Get-ItemProperty -LiteralPath $runKey
        foreach ($entry in @(
            @{ Name = 'OneDriveSyncMonitor'; Path = $monitor; IsScript = $true },
            @{ Name = 'OneDriveCloudBackup'; Path = $backup; IsScript = $true },
            @{ Name = 'OneDriveMultiLibrarySync'; Path = (Join-Path $root 'MultiLibrarySync.ps1'); IsScript = $true },
            @{ Name = 'OneDriveSyncMonitorTray'; Path = $tray; IsScript = $false }
        )) {
            $value = [string]$run.($entry.Name)
            if (-not $value) { continue }
            $owned = if ($entry.IsScript) {
                Test-MonitorScriptCommand -CommandLine $value -ScriptPath $entry.Path
            } else {
                Test-MonitorStartupCommand -CommandLine $value -TargetPath $entry.Path
            }
            if (-not $owned) { throw "Startup entry '$($entry.Name)' points elsewhere; refusing to remove or replace it." }
            if ($entry.Name -eq 'OneDriveCloudBackup') { $backupWasEnabled = $true }
            if ($entry.Name -eq 'OneDriveMultiLibrarySync') { $multiWasEnabled = $true }
            Remove-ItemProperty -LiteralPath $runKey -Name $entry.Name -ErrorAction Stop
        }
    }

    $stopPath = Join-Path $root 'cloud-backup.stop'
    if (Test-Path -LiteralPath $root -PathType Container) {
        Set-Content -LiteralPath $stopPath -Value 'disabled' -Encoding ASCII
        if(Test-Path -LiteralPath (Join-Path $root 'libraries')) { Set-Content -LiteralPath (Join-Path $root 'libraries\supervisor.stop') -Value 'disabled' -Encoding ASCII }
    }
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $stopped = 0
    $processes = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction Stop)
    foreach ($process in $processes) {
        if (-not (Test-MonitorProcessIdentity -CommandLine ([string]$process.CommandLine) -MonitorPath $monitor -BackupPath $backup)) { continue }
        try { $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid -ErrorAction Stop }
        catch {
            if (-not (Test-MonitorProcessStillRunning -ProcessId ([int]$process.ProcessId) -MonitorPath $monitor -BackupPath $backup)) { continue }
            throw "Cannot verify owner of process $($process.ProcessId); refusing incomplete cleanup."
        }
        if ($owner.Sid -ne $currentSid) { continue }
        Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        while ([DateTime]::UtcNow -lt $deadline -and (Test-MonitorProcessStillRunning -ProcessId ([int]$process.ProcessId) -MonitorPath $monitor -BackupPath $backup)) {
            Start-Sleep -Milliseconds 200
        }
        if (Test-MonitorProcessStillRunning -ProcessId ([int]$process.ProcessId) -MonitorPath $monitor -BackupPath $backup) {
            throw "Owned process $($process.ProcessId) did not stop; refusing incomplete cleanup."
        }
        $stopped++
    }
    foreach ($process in @(Get-Process -Name 'OneDriveSyncMonitorTray' -ErrorAction SilentlyContinue)) {
        try {
            if ([IO.Path]::GetFullPath($process.Path) -ieq $tray) {
                Stop-Process -Id $process.Id -Force -ErrorAction Stop
                $stopped++
            }
        }
        catch { Write-Warning "Could not stop tray process $($process.Id): $($_.Exception.Message)" }
    }
    return [pscustomobject]@{ StoppedProcesses = $stopped; BackupWasEnabled = $backupWasEnabled; MultiWasEnabled = $multiWasEnabled; RemovedTask = [bool]$task }
}
