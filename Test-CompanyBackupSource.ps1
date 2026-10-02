[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'Find-CompanyBackupSource.ps1') -LoadFunctionsOnly

# No registry writes, uploads, modules, or test directories. Mock the two I/O seams.
$script:targetUrl = 'https://aspectengwa.sharepoint.com/sites/Design/Shared%20Documents'
$script:targetTenant = 'a2f1a70f-1bf7-48c7-9b0f-c0d3f912a76e'
$script:library = 'C:\CompanySync\Unrelated local name'
$script:accountRoot = 'C:\CompanyOneDrive'
$script:passed = 0
$script:registry = @{}
$script:pathOverrides = @{}
$script:registryReads = 0

function Read-CompanyBackupRegistryKey {
    param([string]$Path, [string[]]$ValueNames, [switch]$AllValues)
    $script:registryReads++
    if ($script:registry.ContainsKey($Path)) { return $script:registry[$Path] }
    return $null
}

function Get-CompanyBackupPathInfo {
    param([string]$Path)
    if ($script:pathOverrides.ContainsKey($Path)) { return $script:pathOverrides[$Path] }
    return [pscustomobject]@{ IsDirectory = $true; ReparseTag = [uint32]0; IsReparsePoint = $false }
}

function Add-TestRegistryKey {
    param([string]$Path, [hashtable]$Values = @{}, [string[]]$Children = @())
    $script:registry[$Path] = [pscustomobject]@{ Values = $Values; SubKeyNames = $Children }
}

function Reset-TestEvidence {
    $script:registry = @{}
    $script:pathOverrides = @{}
    $script:registryReads = 0
    Add-TestRegistryKey 'Software\Microsoft\OneDrive\Accounts' @{} @('Personal', 'Business1')
    Add-TestRegistryKey 'Software\Microsoft\OneDrive\Accounts\Business1' @{
        ConfiguredTenantId = $script:targetTenant; UserFolder = $script:accountRoot
    }
    Add-TestRegistryKey 'Software\Microsoft\OneDrive\Accounts\Business1\ScopeIdToMountPointPathCache' @{
        'scope+1' = $script:library; 'personal-scope' = $script:accountRoot
    }
    Add-TestRegistryKey 'Software\SyncEngines\Providers\OneDrive' @{} @('scope+1')
    Add-TestRegistryKey 'Software\SyncEngines\Providers\OneDrive\scope+1' @{
        UrlNamespace = $script:targetUrl; MountPoint = $script:library
        WebUrl = 'https://aspectengwa.sharepoint.com/sites/Design'
    }
}

function Invoke-TestResolve {
    param($Config = $null)
    Resolve-CompanyBackupSource -LibraryWebUrl $script:targetUrl -TenantId $script:targetTenant -ExistingConfig $Config
}

function Assert-Test {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
}

function Assert-Rejected {
    param([scriptblock]$Action, [string]$Pattern = 'Cannot prove|unsafe|ambiguous|registry|Unsupported|Invalid')
    $message = ''
    try { $null = & $Action } catch { $message = $_.Exception.Message }
    Assert-Test ($message -match $Pattern) "Expected rejection ($Pattern); got: $message"
}

function Test-Case {
    param([string]$Name, [scriptblock]$Action)
    Reset-TestEvidence
    & $Action
    $script:passed++
    Write-Host "PASS: $Name"
}

function New-TestConfig {
    param([string]$Root = $script:library)
    return @{ TargetType = 'SharePoint'; LibraryWebUrl = $script:targetUrl; TenantId = $script:targetTenant; SourceRoot = $Root }
}

Test-Case 'Exact provider URL + matching scope ID and mount establishes tenant and library' {
    $result = @(Invoke-TestResolve)
    Assert-Test ($result.Count -eq 1) 'Return exactly one object without diagnostic output'
    Assert-Test ($result[0].SourceRoot -ceq $script:library) 'Preserve the exact mapped root, irrespective of its name'
    Assert-Test ($result[0].DiscoveryMethod -eq 'Registry') 'Report registry evidence'
    Assert-Test ($result[0].TargetType -eq 'SharePoint' -and $result[0].TenantId -eq $script:targetTenant) 'Return target identity'
}

Test-Case 'Decoded URL, case and trailing slash are equivalent' {
    $script:registry['Software\SyncEngines\Providers\OneDrive\scope+1'].Values.UrlNamespace = 'HTTPS://ASPECTENGWA.SHAREPOINT.COM/sites/design/Shared Documents/'
    Assert-Test ((Invoke-TestResolve).SourceRoot -eq $script:library) 'Canonical URL match'
}

Test-Case 'Other Business account numbers and brace GUID tenant format work' {
    $script:registry['Software\Microsoft\OneDrive\Accounts'].SubKeyNames = @('Business7')
    Add-TestRegistryKey 'Software\Microsoft\OneDrive\Accounts\Business7' @{ ConfiguredTenantId = ('{' + $script:targetTenant + '}'); UserFolder = $script:accountRoot }
    Add-TestRegistryKey 'Software\Microsoft\OneDrive\Accounts\Business7\ScopeIdToMountPointPathCache' @{ 'scope+1' = $script:library }
    Assert-Test ((Invoke-TestResolve).SourceRoot -eq $script:library) 'Enumerate Business accounts'
}

Test-Case 'Provider with explicit tenant metadata works without an account cache' {
    $script:registry.Remove('Software\Microsoft\OneDrive\Accounts')
    $script:registry['Software\SyncEngines\Providers\OneDrive\scope+1'].Values.TenantId = $script:targetTenant
    Assert-Test ((Invoke-TestResolve).SourceRoot -eq $script:library) 'Explicit provider tenant'
}

Test-Case 'No registry evidence fails; a same-named folder is never searched' {
    $script:registry = @{}
    Assert-Rejected { Invoke-TestResolve }
}

Test-Case 'Cache alone cannot prove the remote library' {
    $script:registry.Remove('Software\SyncEngines\Providers\OneDrive')
    Assert-Rejected { Invoke-TestResolve }
}

Test-Case 'URL alone cannot prove tenant identity' {
    $script:registry.Remove('Software\Microsoft\OneDrive\Accounts')
    Assert-Rejected { Invoke-TestResolve }
}

Test-Case 'Mount path alone cannot associate a provider with an account scope' {
    $script:registry['Software\Microsoft\OneDrive\Accounts\Business1\ScopeIdToMountPointPathCache'].Values = @{ differentScope = $script:library }
    Assert-Rejected { Invoke-TestResolve }
}

Test-Case 'Matching scope ID with different mount path is rejected' {
    $script:registry['Software\Microsoft\OneDrive\Accounts\Business1\ScopeIdToMountPointPathCache'].Values['scope+1'] = 'C:\Different'
    Assert-Rejected { Invoke-TestResolve }
}

Test-Case 'Wrong and conflicting tenant metadata are rejected' {
    $script:registry['Software\Microsoft\OneDrive\Accounts\Business1'].Values.ConfiguredTenantId = '11111111-1111-1111-1111-111111111111'
    Assert-Rejected { Invoke-TestResolve }
    $script:registry['Software\SyncEngines\Providers\OneDrive\scope+1'].Values.TenantId = $script:targetTenant
    Assert-Rejected { Invoke-TestResolve }
}

Test-Case 'Neither site URL, child folder, sibling library nor foreign host matches' {
    foreach ($url in @('https://aspectengwa.sharepoint.com/sites/Design',
        ($script:targetUrl + '/Subfolder'), ($script:targetUrl + '2'),
        'https://other.sharepoint.com/sites/Design/Shared%20Documents')) {
        $script:registry['Software\SyncEngines\Providers\OneDrive\scope+1'].Values.UrlNamespace = $url
        Assert-Rejected { Invoke-TestResolve }
    }
}

Test-Case 'WebUrl alone is not a library namespace' {
    $values = $script:registry['Software\SyncEngines\Providers\OneDrive\scope+1'].Values
    $values.Remove('UrlNamespace'); $values.WebUrl = $script:targetUrl
    Assert-Rejected { Invoke-TestResolve }
}

Test-Case 'Unsafe or non-library input URLs are rejected before registry access' {
    foreach ($url in @('http://aspectengwa.sharepoint.com/sites/Design/Shared%20Documents',
        ($script:targetUrl + '/Forms/AllItems.aspx'), ($script:targetUrl + '?id=other'),
        ($script:targetUrl + '#x'), 'https://user@aspectengwa.sharepoint.com/sites/Design/Shared%20Documents',
        'https://aspectengwa.sharepoint.com/sites/Other/../Design/Shared%20Documents',
        'https://aspectengwa.sharepoint.com/sites/Design%2fShared%20Documents')) {
        Assert-Rejected { Resolve-CompanyBackupSource -LibraryWebUrl $url -TenantId $script:targetTenant }
    }
    Assert-Test ($script:registryReads -eq 0) 'Validate inputs first'
}

Test-Case 'Unsupported tenant is rejected before registry access' {
    Assert-Rejected { Resolve-CompanyBackupSource -LibraryWebUrl $script:targetUrl -TenantId '11111111-1111-1111-1111-111111111111' }
    Assert-Test ($script:registryReads -eq 0) 'Validate tenant first'
}

Test-Case 'Duplicate evidence for the same path is deduplicated' {
    $script:registry['Software\SyncEngines\Providers\OneDrive'].SubKeyNames += 'duplicate'
    Add-TestRegistryKey 'Software\SyncEngines\Providers\OneDrive\duplicate' @{
        UrlNamespace = $script:targetUrl; MountPoint = $script:library.ToUpperInvariant() + '\'; TenantId = $script:targetTenant
    }
    Assert-Test ((Invoke-TestResolve).SourceRoot -eq $script:library) 'Same physical spelling after normalization'
}

Test-Case 'Two different mounts are ambiguous, including with a matching config' {
    $script:registry['Software\SyncEngines\Providers\OneDrive'].SubKeyNames += 'second'
    Add-TestRegistryKey 'Software\SyncEngines\Providers\OneDrive\second' @{
        UrlNamespace = $script:targetUrl; MountPoint = 'D:\Another library'; TenantId = $script:targetTenant
    }
    Assert-Rejected { Invoke-TestResolve } 'ambiguous'
    Assert-Rejected { Invoke-TestResolve (New-TestConfig) } 'ambiguous'
}

Test-Case 'Validated SharePoint config works without a live registry mapping' {
    $script:registry = @{}
    $result = Invoke-TestResolve ([pscustomobject](New-TestConfig))
    Assert-Test ($result.SourceRoot -eq $script:library -and $result.DiscoveryMethod -eq 'ExistingConfig') 'Explicit config reuse'
}

Test-Case 'Legacy, wrong-target, missing-tenant and wrong-tenant configs cannot override discovery' {
    foreach ($field in @('TargetType', 'LibraryWebUrl', 'TenantId')) {
        $config = New-TestConfig 'C:\Wrong'
        $config[$field] = 'wrong'
        Assert-Test ((Invoke-TestResolve $config).SourceRoot -eq $script:library) 'Ignore mismatched config'
        $config.Remove($field)
        Assert-Test ((Invoke-TestResolve $config).SourceRoot -eq $script:library) 'Ignore incomplete config'
    }
}

Test-Case 'Existing config pointing at a Business OneDrive root is ignored' {
    Assert-Test ((Invoke-TestResolve (New-TestConfig $script:accountRoot)).SourceRoot -eq $script:library) 'Reject the legacy root'
}

Test-Case 'Config cannot select the parent of a registered library' {
    Assert-Test ((Invoke-TestResolve (New-TestConfig 'C:\CompanySync')).SourceRoot -eq $script:library) 'Reject broad parent'
}

Test-Case 'Config cannot select a child folder of a registered library' {
    Assert-Test ((Invoke-TestResolve (New-TestConfig ($script:library + '\Subfolder'))).SourceRoot -eq $script:library) 'Reject partial library'
}

Test-Case 'Conflicting validated config and registry root are ambiguous' {
    Assert-Rejected { Invoke-TestResolve (New-TestConfig 'D:\Different library') } 'ambiguous'
}

Test-Case 'Config explicitly contradicted by another namespace is ignored' {
    $script:registry['Software\SyncEngines\Providers\OneDrive'].SubKeyNames += 'other'
    Add-TestRegistryKey 'Software\SyncEngines\Providers\OneDrive\other' @{
        UrlNamespace = 'https://aspectengwa.sharepoint.com/sites/Other/Documents'; MountPoint = 'C:\Wrong'; TenantId = $script:targetTenant
    }
    Assert-Test ((Invoke-TestResolve (New-TestConfig 'C:\Wrong')).SourceRoot -eq $script:library) 'Honor contrary evidence'
}

Test-Case 'A second namespace at the proven mount is conflicting evidence' {
    $script:registry['Software\SyncEngines\Providers\OneDrive'].SubKeyNames += 'other'
    Add-TestRegistryKey 'Software\SyncEngines\Providers\OneDrive\other' @{
        UrlNamespace = 'https://aspectengwa.sharepoint.com/sites/Other/Documents'; MountPoint = $script:library
    }
    Assert-Rejected { Invoke-TestResolve } 'conflict'
}

Test-Case 'Config cannot select a parent or child of a cache-only mount' {
    $script:registry.Remove('Software\SyncEngines\Providers\OneDrive')
    Assert-Rejected { Invoke-TestResolve (New-TestConfig 'C:\CompanySync') }
    Assert-Rejected { Invoke-TestResolve (New-TestConfig ($script:library + '\Subfolder')) }
}

Test-Case 'Missing or file-valued root fails and stale config falls back to registry' {
    $script:pathOverrides[$script:library] = $null
    Assert-Rejected { Invoke-TestResolve }
    $script:pathOverrides[$script:library] = [pscustomobject]@{ IsDirectory = $false; IsReparsePoint = $false; ReparseTag = 0 }
    Assert-Rejected { Invoke-TestResolve }
    $script:pathOverrides = @{ 'C:\Missing' = $null }
    Assert-Test ((Invoke-TestResolve (New-TestConfig 'C:\Missing')).SourceRoot -eq $script:library) 'Discard missing config root'
}

Test-Case 'Roots, network/device/relative paths, ADS, wildcards and traversal are unsafe' {
    foreach ($path in @('C:\', 'C:', '\\server\share\library', '\\?\C:\Library', 'relative\library',
        'C:\CompanySync\..\Library', 'C:\Library:stream', 'C:\Library*', 'C:\Library.', 'C:\Library ')) {
        $script:registry['Software\SyncEngines\Providers\OneDrive\scope+1'].Values.MountPoint = $path
        $script:registry['Software\Microsoft\OneDrive\Accounts\Business1\ScopeIdToMountPointPathCache'].Values['scope+1'] = $path
        Assert-Rejected { Invoke-TestResolve }
    }
}

Test-Case 'Mapped OneDrive account root and current user profile are unsafe' {
    foreach ($path in @($script:accountRoot, $env:USERPROFILE)) {
        $script:registry['Software\SyncEngines\Providers\OneDrive\scope+1'].Values.MountPoint = $path
        $script:registry['Software\Microsoft\OneDrive\Accounts\Business1\ScopeIdToMountPointPathCache'].Values['scope+1'] = $path
        Assert-Rejected { Invoke-TestResolve }
    }
}

Test-Case 'Junctions, symlinks and unknown reparse points on root or ancestors fail' {
    foreach ($path in @($script:library, 'C:\CompanySync')) {
        foreach ($tag in @([uint32]2684354563, [uint32]2684354572, [uint32]2147483667, [uint32]0)) {
            $script:pathOverrides = @{}
            $script:pathOverrides[$path] = [pscustomobject]@{ IsDirectory = $true; IsReparsePoint = $true; ReparseTag = $tag }
            Assert-Rejected { Invoke-TestResolve } 'unsafe'
        }
    }
}

Test-Case 'Cloud Files placeholder tags on root and ancestors are accepted' {
    foreach ($tag in @([uint32]2415919130, [uint32]2415980570)) {
        $script:pathOverrides[$script:library] = [pscustomobject]@{ IsDirectory = $true; IsReparsePoint = $true; ReparseTag = $tag }
        $script:pathOverrides['C:\CompanySync'] = $script:pathOverrides[$script:library]
        Assert-Test ((Invoke-TestResolve).SourceRoot -eq $script:library) 'Cloud tag family is not a path redirection'
    }
}

Test-Case 'Registry access errors fail closed without exposing raw details' {
    function Read-CompanyBackupRegistryKey { throw 'PRIVATE_REGISTRY_DETAIL' }
    $message = ''
    try { Invoke-TestResolve (New-TestConfig) | Out-Null } catch { $message = $_.Exception.Message }
    Assert-Test ($message -match 'registry' -and $message -notmatch 'PRIVATE_REGISTRY_DETAIL') 'Sanitize registry failures'
}

Write-Host "All $script:passed company backup source tests passed (PowerShell $($PSVersionTable.PSVersion))."
