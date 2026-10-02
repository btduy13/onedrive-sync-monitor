[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Setup-MultiLibrarySync.ps1') -LoadFunctionsOnly
$testRoot=Join-Path $env:TEMP ('MultiLibrarySetupTest-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
try{
    if(-not(Get-MultiLibraryDisableAutoUpdate -InstallPath $testRoot)){throw 'New installs must default to no automatic updates.'}
    Write-Host 'PASS: new installs leave auto-update off until enabled by IT.'
    Set-Content -LiteralPath (Join-Path $testRoot 'config.json') -Value '{"AutoUpdateEnabled":true}' -Encoding UTF8
    if(Get-MultiLibraryDisableAutoUpdate -InstallPath $testRoot){throw 'Existing enabled preference was not preserved.'}
    Write-Host 'PASS: reinstall preserves an existing enabled preference.'
    Set-Content -LiteralPath (Join-Path $testRoot 'config.json') -Value '{"AutoUpdateEnabled":false}' -Encoding UTF8
    if(-not(Get-MultiLibraryDisableAutoUpdate -InstallPath $testRoot)){throw 'Existing disabled preference was not preserved.'}
    Write-Host 'PASS: reinstall preserves an existing disabled preference.'
    Set-Content -LiteralPath (Join-Path $testRoot 'config.json') -Value '{' -Encoding UTF8
    $rejected=$false
    try{Get-MultiLibraryDisableAutoUpdate -InstallPath $testRoot | Out-Null}catch{$rejected=$true}
    if(-not $rejected){throw 'Malformed existing config was silently replaced.'}
    Write-Host 'PASS: invalid existing config is rejected rather than silently reset.'
}finally{
    $resolved=[IO.Path]::GetFullPath($testRoot)
    if(-not $resolved.StartsWith(([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\MultiLibrarySetupTest-'),[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture path'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
