[CmdletBinding()]
param()
# Live, opt-in test for the current Windows account. It pauses and restores only
# this app's supervisor; never run it during an unrelated installation or repair.
$ErrorActionPreference='Stop'
$install=Join-Path $env:LOCALAPPDATA 'OneDriveSyncMonitor'
$sync=Join-Path $install 'MultiLibrarySync.ps1'
$monitor=Join-Path $install 'OneDriveSyncMonitor.ps1'
$data=Join-Path $install 'libraries'
$stop=Join-Path $data 'supervisor.stop'
$runKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
if(-not(Test-Path -LiteralPath $sync -PathType Leaf) -or -not(Test-Path -LiteralPath $monitor -PathType Leaf)){
    throw 'Installed monitor and supervisor are required for this live test.'
}
$prior=(Get-ItemProperty $runKey -Name OneDriveMultiLibrarySync -ErrorAction Stop).OneDriveMultiLibrarySync
if(-not $prior){throw 'Automatic sync must already be enabled.'}
$recoveryPath=Join-Path $data 'supervisor-recovery.json'
if(Test-Path -LiteralPath $recoveryPath -PathType Leaf){
    $last=[DateTime](Get-Content -LiteralPath $recoveryPath -Raw | ConvertFrom-Json).LastAttemptUtc
    $next=$last.ToUniversalTime().AddMinutes(5).AddSeconds(2)
    while([DateTime]::UtcNow -lt $next){Start-Sleep -Seconds 10}
}
$mutexName='Local\OneDriveMultiLibrarySync-'+[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$simulated=$false
try{
    & $sync -Disable
    $mutex=New-Object Threading.Mutex($false,$mutexName)
    try{
        $acquired=$false
        try{$acquired=$mutex.WaitOne(45000)}catch [Threading.AbandonedMutexException]{$acquired=$true}
        if(-not $acquired){throw 'Supervisor did not stop for the controlled test.'}
        $mutex.ReleaseMutex()
    }finally{$mutex.Dispose()}
    # Simulate an unexpected exit: autostart is configured, but no supervisor owns the mutex.
    if(-not(Test-Path -LiteralPath $stop -PathType Leaf)){throw 'Expected stop marker is missing.'}
    Remove-Item -LiteralPath $stop -Force
    Set-ItemProperty $runKey -Name OneDriveMultiLibrarySync -Value $prior
    $simulated=$true
    . $monitor -LoadFunctionsOnly
    Invoke-SafeMultiLibraryRecovery -Config (Get-MonitorConfig) -InstallPath $install -DataRoot $data
    $deadline=[DateTime]::UtcNow.AddSeconds(60)
    do{
        Start-Sleep -Seconds 2
        $owned=@(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
            Where-Object {$_.CommandLine -like ('*"'+$sync+'"*') -and $_.CommandLine -notmatch '\s-(?:Once|VerifyWrite|DiscoverOnly|Enable|Disable)\b'})
    }while(-not $owned.Count -and [DateTime]::UtcNow -lt $deadline)
    if(-not $owned.Count){throw 'Recovery did not start the installed supervisor within 60 seconds.'}
    Write-Host "PASS: missing supervisor restarted safely (PID $($owned[0].ProcessId))."
}finally{
    if($simulated){
        $registered=(Get-ItemProperty $runKey -Name OneDriveMultiLibrarySync -ErrorAction SilentlyContinue).OneDriveMultiLibrarySync
        if(-not $registered){Set-ItemProperty $runKey -Name OneDriveMultiLibrarySync -Value $prior}
        if(Test-Path -LiteralPath $stop -PathType Leaf){Remove-Item -LiteralPath $stop -Force}
        $owned=@(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
            Where-Object {$_.CommandLine -like ('*"'+$sync+'"*') -and $_.CommandLine -notmatch '\s-(?:Once|VerifyWrite|DiscoverOnly|Enable|Disable)\b'})
        if(-not $owned.Count){& $sync -Enable}
    }else{
        & $sync -Enable
    }
}
