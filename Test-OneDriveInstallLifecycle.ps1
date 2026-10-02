[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Manage-OneDriveSyncMonitorInstances.ps1')

function Assert-LifecycleTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Host "PASS: $Message"
}

$root = Join-Path $env:LOCALAPPDATA 'OneDriveSyncMonitor'
$monitor = Join-Path $root 'OneDriveSyncMonitor.ps1'
$backup = Join-Path $root 'OneDriveCloudBackup.ps1'
$tray = Join-Path $root 'OneDriveSyncMonitorTray.exe'
Assert-LifecycleTest (Test-MonitorScriptCommand -CommandLine ('powershell.exe -NoProfile -File "{0}" -ConfigPath x' -f $monitor) -ScriptPath $monitor) 'Quoted monitor process is in scope'
Assert-LifecycleTest (Test-MonitorScriptCommand -CommandLine ('powershell.exe -File {0}' -f $backup) -ScriptPath $backup) 'Backup process is in scope'
Assert-LifecycleTest (-not (Test-MonitorScriptCommand -CommandLine ('powershell.exe -File "{0}"' -f (Join-Path $env:TEMP 'OneDriveSyncMonitor.ps1')) -ScriptPath $monitor)) 'Same script name in another directory is out of scope'
Assert-LifecycleTest (-not (Test-MonitorScriptCommand -CommandLine 'powershell.exe -File C:\Windows\other.ps1 -Argument OneDriveSyncMonitor.ps1' -ScriptPath $monitor)) 'Incidental script name in arguments is out of scope'
Assert-LifecycleTest (-not (Test-MonitorScriptCommand -CommandLine ('powershell.exe -Command "Write-Host -File ""{0}"""' -f $monitor) -ScriptPath $monitor)) 'PowerShell command text is not mistaken for an owned process'
Assert-LifecycleTest (Test-MonitorProcessIdentity -CommandLine ('powershell.exe -File "{0}"' -f $monitor) -MonitorPath $monitor -BackupPath $backup) 'A still-running process is identified by its exact script path'
Assert-LifecycleTest (-not (Test-MonitorProcessIdentity -CommandLine ('powershell.exe -File "{0}"' -f (Join-Path $env:TEMP 'replacement.ps1')) -MonitorPath $monitor -BackupPath $backup)) 'A reused PID for another process is not treated as the monitor'
Assert-LifecycleTest (Test-MonitorStartupCommand -CommandLine ('"{0}"' -f $tray) -TargetPath $tray) 'Installed tray Startup command is in scope'
Assert-LifecycleTest (-not (Test-MonitorStartupCommand -CommandLine '"C:\Other\OneDriveSyncMonitorTray.exe"' -TargetPath $tray)) 'Other tray Startup command is out of scope'
Assert-LifecycleTest (Test-SafeMonitorInstallPath -InstallPath $root) 'Current-user monitor install folder is safe'
Assert-LifecycleTest (-not (Test-SafeMonitorInstallPath -InstallPath $env:LOCALAPPDATA)) 'LOCALAPPDATA root is never an uninstall target'
Assert-LifecycleTest (-not (Test-SafeMonitorInstallPath -InstallPath 'C:\')) 'Drive root is never an uninstall target'

$uninstall = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Uninstall-OneDriveSyncMonitor.ps1') -Raw
Assert-LifecycleTest ($uninstall -match 'RemoveProgramFiles' -and $uninstall -match 'Stop-OneDriveMonitorInstances') 'Uninstaller supports one-click program removal and instance cleanup'
$installer = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Install-OneDriveSyncMonitor.ps1') -Raw
Assert-LifecycleTest ($installer -match 'Stop-OneDriveMonitorInstances') 'Installer cleans previous instances before copying files'
$wrapper = Join-Path $PSScriptRoot 'OneClick-Uninstall.cmd'
Assert-LifecycleTest (Test-Path -LiteralPath $wrapper -PathType Leaf) 'One-click uninstaller wrapper exists'
