[CmdletBinding()]
param([string]$OutputPath = '')
$ErrorActionPreference = 'Stop'
if (-not $OutputPath) { $OutputPath = Join-Path $PSScriptRoot 'OneDriveSyncMonitorTray.exe' }
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) { throw "C# compiler not found: $csc" }
$references = @('System.dll','System.Core.dll','System.Drawing.dll','System.Management.dll','System.Windows.Forms.dll') | ForEach-Object { '/reference:' + $_ }
$iconBuilder=Join-Path $PSScriptRoot 'Build-AppIcon.exe'
$iconPath=Join-Path $PSScriptRoot 'OneDriveSyncMonitor.ico'
& $csc /nologo /target:exe /optimize+ /out:$iconBuilder /reference:System.Drawing.dll (Join-Path $PSScriptRoot 'AppLogo.cs') (Join-Path $PSScriptRoot 'Build-AppIcon.cs')
if ($LASTEXITCODE -ne 0) { throw "Icon build failed: $LASTEXITCODE" }
& $iconBuilder $iconPath
if ($LASTEXITCODE -ne 0) { throw "Icon generation failed: $LASTEXITCODE" }
& $csc /nologo /target:winexe /optimize+ "/win32icon:$iconPath" /out:$OutputPath @references (Join-Path $PSScriptRoot 'AppLogo.cs') (Join-Path $PSScriptRoot 'OneDriveSyncMonitorTray.cs') (Join-Path $PSScriptRoot 'DashboardForm.Operations.cs')
if ($LASTEXITCODE -ne 0) { throw "Tray build failed: $LASTEXITCODE" }
Write-Host "Created $OutputPath"
