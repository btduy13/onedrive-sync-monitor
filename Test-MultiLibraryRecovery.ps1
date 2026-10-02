[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$fixture = Join-Path $env:TEMP ('MultiLibraryRecoveryTest-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
try {
    . (Join-Path $PSScriptRoot 'OneDriveSyncMonitor.ps1') -LoadFunctionsOnly `
        -ConfigPath (Join-Path $fixture 'config.json') -LogPath (Join-Path $fixture 'monitor.log') `
        -StatePath (Join-Path $fixture 'monitor-state.json') -CloudStatePath (Join-Path $fixture 'cloud-state.json')
    function Assert-Recovery { param([bool]$Condition,[string]$Message)
        if (-not $Condition) { throw "FAIL: $Message" }
        Write-Host "PASS: $Message"
    }
    $install = Join-Path $fixture 'installed'
    $data = Join-Path $fixture 'libraries'
    New-Item -ItemType Directory -Path $install,$data -Force | Out-Null
    $scriptPath = Join-Path $install 'MultiLibrarySync.ps1'
    Set-Content -LiteralPath $scriptPath -Value '# isolated test fixture' -Encoding ASCII
    $exe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $expected = '"' + $exe + '" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $scriptPath + '" -DataRoot "' + $data + '"'
    $now = [DateTime]::UtcNow
    $base = @{SafeRecoveryEnabled=$true; RegisteredCommand=$expected; ExpectedCommand=$expected;
        StopRequested=$false; SupervisorRunning=$false; LastAttemptUtc=''; NowUtc=$now}
    Assert-Recovery ((Get-MultiLibraryRecoveryDecision @base) -eq 'Restart') 'An enabled missing supervisor is eligible for a safe restart'
    $base.SafeRecoveryEnabled=$false
    Assert-Recovery ((Get-MultiLibraryRecoveryDecision @base) -eq 'Disabled') 'Safe recovery off prevents restart'
    $base.SafeRecoveryEnabled=$true; $base.RegisteredCommand=''
    Assert-Recovery ((Get-MultiLibraryRecoveryDecision @base) -eq 'NotEnabled') 'Explicitly disabled sync is never restarted'
    $base.RegisteredCommand='"C:\Other\powershell.exe" -File "C:\Other\script.ps1"'
    Assert-Recovery ((Get-MultiLibraryRecoveryDecision @base) -eq 'UnexpectedStartupCommand') 'Unexpected startup command is never executed'
    $base.RegisteredCommand=$expected; $base.StopRequested=$true
    Assert-Recovery ((Get-MultiLibraryRecoveryDecision @base) -eq 'Stopping') 'Manual pause prevents restart'
    $base.StopRequested=$false; $base.SupervisorRunning=$true
    Assert-Recovery ((Get-MultiLibraryRecoveryDecision @base) -eq 'Running') 'Existing supervisor is never duplicated'
    $base.SupervisorRunning=$false; $base.LastAttemptUtc=$now.AddMinutes(-1).ToString('o')
    Assert-Recovery ((Get-MultiLibraryRecoveryDecision @base) -eq 'Cooldown') 'Repeated crashes wait five minutes before retry'
    $base.LastAttemptUtc=$now.AddMinutes(-6).ToString('o')
    Assert-Recovery ((Get-MultiLibraryRecoveryDecision @base) -eq 'Restart') 'A later retry is allowed'

    $script:fixtureCommand = $expected
    $script:fixtureLaunches = @()
    function Get-ItemProperty { param($Path,$Name,$ErrorAction)
        return [pscustomobject]@{OneDriveMultiLibrarySync=$script:fixtureCommand}
    }
    function Start-Process { param($FilePath,$ArgumentList,$WindowStyle,$ErrorAction)
        $script:fixtureLaunches += [pscustomobject]@{FilePath=$FilePath;Arguments=$ArgumentList;WindowStyle=$WindowStyle}
    }
    $config = [pscustomobject]@{SafeRecoveryEnabled=$true}
    $testMutex = 'Local\MultiLibraryRecoveryTest-' + [guid]::NewGuid().ToString('N')
    Invoke-SafeMultiLibraryRecovery -Config $config -InstallPath $install -DataRoot $data -MutexName $testMutex
    Assert-Recovery ($script:fixtureLaunches.Count -eq 1 -and
        $script:fixtureLaunches[0].FilePath -eq $exe -and
        $script:fixtureLaunches[0].Arguments -match [regex]::Escape($scriptPath)) 'Recovery launches only the installed supervisor script'
    Invoke-SafeMultiLibraryRecovery -Config $config -InstallPath $install -DataRoot $data -MutexName $testMutex
    Assert-Recovery ($script:fixtureLaunches.Count -eq 1) 'Cooldown prevents a second launch'
    Set-Content -LiteralPath (Join-Path $data 'supervisor.stop') -Value 'manual pause' -Encoding ASCII
    Invoke-SafeMultiLibraryRecovery -Config $config -InstallPath $install -DataRoot $data -MutexName $testMutex
    Assert-Recovery ($script:fixtureLaunches.Count -eq 1) 'Stop marker prevents a restart during pause'
}
finally {
    $resolved=[IO.Path]::GetFullPath($fixture)
    if (-not $resolved.StartsWith(([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\MultiLibraryRecoveryTest-'),[StringComparison]::OrdinalIgnoreCase)) {
        throw 'Unsafe recovery fixture path'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
