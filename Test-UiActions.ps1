[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$fixture=Join-Path $env:TEMP ('OneDriveMonitor-UiActions-'+[guid]::NewGuid().ToString('N'))
$previousLocalAppData=$env:LOCALAPPDATA
try {
    $env:LOCALAPPDATA=$fixture
    $app=Join-Path $fixture 'OneDriveSyncMonitor'
    New-Item -ItemType Directory -Path $app -Force | Out-Null
    @{NotifyItEmailEnabled=$true;AutoUpdateEnabled=$false;SafeRecoveryEnabled=$true;ComputerName='TEST-PC';WebhookUrlProtected=''} |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $app 'config.json') -Encoding UTF8
    & (Join-Path $PSScriptRoot 'Manage-OneDriveSyncMonitorUi.ps1') -Action SetPreference -Name Email -Value false | Out-Null
    $config=Get-Content (Join-Path $app 'config.json') -Raw | ConvertFrom-Json
    if($config.NotifyItEmailEnabled -ne $false -or $config.AutoUpdateEnabled -ne $false){throw 'Preference change lost an unrelated setting.'}
    Write-Host 'PASS: IT email preference saves without resetting auto-update.'

    $fakeUrl='https://example.invalid/flows/test?signature=fixture-only'
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $info.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $PSScriptRoot 'Manage-OneDriveSyncMonitorUi.ps1')+'" -Action SetWebhook'
    $info.UseShellExecute=$false
    $info.RedirectStandardInput=$true
    $info.RedirectStandardOutput=$true
    $info.RedirectStandardError=$true
    $info.EnvironmentVariables['LOCALAPPDATA']=$fixture
    $process=[Diagnostics.Process]::Start($info)
    try{
        $process.StandardInput.WriteLine($fakeUrl)
        $process.StandardInput.Close()
        $process.WaitForExit()
        if($process.ExitCode -ne 0){throw ('Webhook save failed: '+$process.StandardError.ReadToEnd())}
    }finally{$process.Dispose()}
    $raw=Get-Content (Join-Path $app 'config.json') -Raw
    $config=$raw | ConvertFrom-Json
    if(-not $config.WebhookUrlProtected -or $raw.Contains($fakeUrl)){throw 'Webhook URL was not protected in config.'}
    $secure=ConvertTo-SecureString -String $config.WebhookUrlProtected
    $pointer=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try{$roundTrip=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)}
    if($roundTrip -ne $fakeUrl){throw 'Saved webhook could not be decrypted by the same Windows user.'}
    Write-Host 'PASS: webhook is DPAPI-protected and round-trips without plaintext on disk.'

    & (Join-Path $PSScriptRoot 'Manage-OneDriveSyncMonitorUi.ps1') -Action ClearWebhook | Out-Null
    $config=Get-Content (Join-Path $app 'config.json') -Raw | ConvertFrom-Json
    if($config.WebhookUrlProtected){throw 'Webhook could not be cleared.'}
    Write-Host 'PASS: webhook can be cleared without changing other settings.'
} finally {
    $env:LOCALAPPDATA=$previousLocalAppData
    if((Test-Path -LiteralPath $fixture) -and $fixture.StartsWith(([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\OneDriveMonitor-UiActions-'),[StringComparison]::OrdinalIgnoreCase)){
        Remove-Item -LiteralPath $fixture -Recurse -Force
    }
}
