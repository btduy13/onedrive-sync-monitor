[CmdletBinding()]
param([switch]$Live)

$ErrorActionPreference = 'Stop'
$helper = Join-Path $PSScriptRoot 'New-CloudBackupCertificate.ps1'
function Assert-CertificateTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Host "PASS: $Message"
}
$work = Join-Path $env:TEMP ('OneDrive-Cert-Test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$name = 'OneDrive-Cert-Test-' + [guid]::NewGuid().ToString('N')
$subject = 'CN=' + $name
$privateRsa = $null
$publicRsa = $null
$publicCert = $null
try {
    if (-not $Live) {
        # Capture actual bound parameters: no certificate or private key is created.
        $capture = @{ Parameters = $null }
        function New-SelfSignedCertificate {
            param($Type, $Subject, $CertStoreLocation, $KeyAlgorithm, $KeyLength,
                $HashAlgorithm, $KeyExportPolicy, $KeySpec, $KeyUsage, $Provider, $NotAfter, $ErrorAction)
            $capture.Parameters = @{} + $PSBoundParameters
            throw 'TEST_CERTIFICATE_CREATION_INTERCEPTED'
        }
        try { & $helper -PublicCertPath (Join-Path $work 'public.cer') -CertificateName $name }
        catch { if ($_.Exception.Message -ne 'TEST_CERTIFICATE_CREATION_INTERCEPTED') { throw } }
        $script:captured = $capture.Parameters
        Assert-CertificateTest ($null -ne $script:captured) 'Certificate creation is reached'
        Assert-CertificateTest ($script:captured.Provider -eq 'Microsoft Software Key Storage Provider' -and $script:captured.KeySpec -eq 'None') 'CNG provider uses KeySpec None'
        Assert-CertificateTest ($script:captured.CertStoreLocation -eq 'Cert:\CurrentUser\My' -and $script:captured.KeyExportPolicy -eq 'NonExportable') 'Private key is non-exportable and user-scoped'
        Assert-CertificateTest ($script:captured.KeyAlgorithm -eq 'RSA' -and $script:captured.KeyLength -eq 3072 -and $script:captured.HashAlgorithm -eq 'SHA256' -and $script:captured.KeyUsage -eq 'DigitalSignature') 'RSA signing parameters are preserved'
    }
    else {
        $output = Join-Path $work 'public.cer'
        $result = & $helper -PublicCertPath $output -CertificateName $name -ValidYears 1
        $certificate = Get-Item -LiteralPath ('Cert:\CurrentUser\My\' + $result.Thumbprint)
        Assert-CertificateTest ($certificate.HasPrivateKey -and $certificate.Subject -eq $subject) 'Real certificate has a private key in CurrentUser'
        $privateRsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($certificate)
        Assert-CertificateTest ($privateRsa -is [Security.Cryptography.RSACng] -and [int]$privateRsa.Key.ExportPolicy -eq 0 -and $privateRsa.KeySize -eq 3072) 'Real CNG key is RSA 3072 and non-exportable'
        $publicCert = New-Object Security.Cryptography.X509Certificates.X509Certificate2($output)
        Assert-CertificateTest (-not $publicCert.HasPrivateKey -and $publicCert.Thumbprint -eq $result.Thumbprint) 'CER contains only the matching public certificate'
        $publicRsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($publicCert)
        $data = [Text.Encoding]::UTF8.GetBytes('OneDrive certificate smoke test')
        $signature = $privateRsa.SignData($data, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        Assert-CertificateTest ($publicRsa.VerifyData($data, $signature, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)) 'Real private key signs and public key verifies SHA256/PKCS1'
        $hash = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash
        $rejected = $false
        try { & $helper -PublicCertPath $output -CertificateName ($name + '-second') | Out-Null }
        catch { $rejected = $_.Exception.Message -like '*already exists*' }
        Assert-CertificateTest ($rejected -and (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash -eq $hash) 'Existing public certificate is not overwritten'
    }
}
finally {
    if ($privateRsa) { $privateRsa.Dispose() }
    if ($publicRsa) { $publicRsa.Dispose() }
    if ($publicCert) { $publicCert.Dispose() }
    if ($Live) {
        # Only remove certificates created for this exact, randomly named test.
        foreach ($created in @(Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -eq $subject -or $_.Subject -eq ($subject + '-second') })) {
            Remove-Item -LiteralPath ('Cert:\CurrentUser\My\' + $created.Thumbprint) -DeleteKey -Force
        }
    }
    $resolved = (Resolve-Path -LiteralPath $work).Path
    $tempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')
    if (-not $resolved.StartsWith($tempRoot + '\OneDrive-Cert-Test-', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe temporary cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
