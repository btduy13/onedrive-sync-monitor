[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$helperPath = Join-Path $PSScriptRoot 'New-CloudBackupCertificate.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($helperPath, [ref]$tokens, [ref]$parseErrors)

function Assert-CertificateTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Host "PASS: $Message"
}

Assert-CertificateTest ($parseErrors.Count -eq 0) 'Helper parses in Windows PowerShell 5.1'

$source = [IO.File]::ReadAllText($helperPath)
$commands = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true))
$creation = @($commands | Where-Object { $_.GetCommandName() -eq 'New-SelfSignedCertificate' })
Assert-CertificateTest ($creation.Count -eq 2) 'Certificate creation has an explicit-provider attempt and a fallback attempt'

foreach ($required in @('-CertStoreLocation $storePath', '-KeyAlgorithm RSA', '-KeyLength 3072',
        '-HashAlgorithm SHA256', '-KeyExportPolicy NonExportable', '-KeySpec Signature',
        '-KeyUsage DigitalSignature')) {
    Assert-CertificateTest ($source.Contains($required)) "Creation requires $required"
}
Assert-CertificateTest ($source.Contains("`$storePath = 'Cert:\CurrentUser\My'")) 'Private key is scoped to CurrentUser\My'
Assert-CertificateTest ($source.Contains('X509ContentType]::Cert')) 'Export uses public certificate content type'
Assert-CertificateTest ($source.Contains('[IO.FileMode]::CreateNew')) 'Public output cannot overwrite an existing file'
Assert-CertificateTest ($source.Contains('$_.Subject -eq $subject')) 'Existing subject conflicts are checked'
Assert-CertificateTest (-not ($source -match 'Export-PfxCertificate|X509ContentType\]::Pfx')) 'No private-key export path is present'
Assert-CertificateTest ($source.Contains('Thumbprint = $certificate.Thumbprint') -and
    $source.Contains('Expires = $certificate.NotAfter') -and
    $source.Contains('PublicCertPath = $destination')) 'Result includes thumbprint, expiry, and public path'
Assert-CertificateTest ($source.Contains('NTE_PROV_TYPE_NOT_DEF') -and
    $source.Contains('without an explicit provider')) 'Provider incompatibility has a compatible fallback'

Write-Host 'Certificate helper static tests passed; no certificate was created.'
