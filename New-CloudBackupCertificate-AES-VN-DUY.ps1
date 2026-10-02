# Creates a machine-local, per-user signing certificate for Graph app-only authentication.
# Register the exported .cer with the app registration; keep the private key in CurrentUser\My.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$PublicCertPath,

    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9 ._-]{0,99}$')]
    [string]$CertificateName = 'OneDriveCloudBackup Graph app-only',

    [ValidateRange(1, 5)]
    [int]$ValidYears = 2
)

$ErrorActionPreference = 'Stop'

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'This helper requires Windows and the CurrentUser certificate store.'
}

$subject = 'CN=' + $CertificateName
$storePath = 'Cert:\CurrentUser\My'
$destination = [IO.Path]::GetFullPath($PublicCertPath)
$parent = [IO.Path]::GetDirectoryName($destination)

if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    throw 'The public certificate destination directory does not exist.'
}
if (Test-Path -LiteralPath $destination) {
    throw 'The public certificate destination already exists. Choose a new path.'
}
if ([IO.Path]::GetExtension($destination) -ine '.cer') {
    throw 'The public certificate path must end in .cer.'
}

$conflicts = @(Get-ChildItem -Path $storePath -ErrorAction Stop | Where-Object { $_.Subject -eq $subject })
if ($conflicts.Count -gt 0) {
    throw 'A certificate with this subject already exists in CurrentUser\My. Choose another certificate name or inspect the existing certificate.'
}

$certificateArgs = @{
    Type = 'Custom'
    Subject = $subject
    CertStoreLocation = $storePath
    KeyAlgorithm = 'RSA'
    KeyLength = 3072
    HashAlgorithm = 'SHA256'
    KeyExportPolicy = 'NonExportable'
    KeySpec = 'Signature'
    KeyUsage = 'DigitalSignature'
    Provider = 'Microsoft Software Key Storage Provider'
    NotAfter = (Get-Date).AddYears($ValidYears)
    ErrorAction = 'Stop'
}
try {
    $certificate = New-SelfSignedCertificate @certificateArgs
}
catch {
    if ($_.Exception.Message -notmatch 'NTE_PROV_TYPE_NOT_DEF|Provider type not defined') { throw }
    Write-Warning 'The configured key storage provider is unavailable; retrying certificate creation without an explicit provider.'
    $certificateArgs.Remove('Provider')
    $certificate = New-SelfSignedCertificate @certificateArgs
}

# X509ContentType.Cert contains only the public certificate. CreateNew atomically refuses
# an existing file, including one created after the earlier destination check.
$stream = $null
try {
    $publicBytes = $certificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert)
    $stream = [IO.File]::Open($destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $stream.Write($publicBytes, 0, $publicBytes.Length)
    $stream.Flush()
}
catch {
    # The certificate remains in CurrentUser\My if export fails, so its key is not
    # silently deleted. Report the thumbprint for an explicit recovery decision.
    if ($null -ne $stream) {
        $stream.Dispose()
        $stream = $null
        Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
    }
    throw "Certificate $($certificate.Thumbprint) was created in CurrentUser\My, but its public .cer could not be written. Check destination access and inspect the certificate before retrying."
}
finally {
    if ($null -ne $stream) { $stream.Dispose() }
}

[pscustomobject]@{
    Thumbprint = $certificate.Thumbprint
    Expires = $certificate.NotAfter
    PublicCertPath = $destination
}
