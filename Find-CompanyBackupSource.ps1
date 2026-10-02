#requires -Version 5.1
<#
.SYNOPSIS
Resolves the company's Design library without prompts or folder-name guesses.
.DESCRIPTION
Dot source with -LoadFunctionsOnly, then call Resolve-CompanyBackupSource with
-LibraryWebUrl, -TenantId and optionally -ExistingConfig (object or hashtable).
Returns one object: SourceRoot, TargetType, LibraryWebUrl, TenantId,
DiscoveryMethod (Registry or ExistingConfig). Throws when proof is unavailable.

The caller must strip Forms/AllItems.aspx and query strings first. ExistingConfig
is trusted prior configuration, not a path discovery hint: it must contain the
matching SharePoint target, library URL, tenant and an existing safe SourceRoot.
Known conflicting registry mappings invalidate it. Multiple roots fail closed.

Registry schema observed read-only on Windows: Accounts\Business* contains
ConfiguredTenantId and UserFolder; ScopeIdToMountPointPathCache stores scope ID
value names with local mount paths. SyncEngines\Providers\OneDrive\<scope ID>
contains UrlNamespace and MountPoint. Provider WebUrl is often only the site URL
and is never used as library proof. A provider must have an explicit matching
TenantId/ConfiguredTenantId or join to an account by BOTH scope ID and mount path.
No assumptions about the spelling of scope IDs, account number, or folder names.

Unsupported registry schemas fail closed. This does not query Graph, hydrate
files, check upload authorization, or guarantee that files are fully synced.
Path validation is a point-in-time check; callers must handle subsequent changes.
#>
[CmdletBinding()]
param(
    [string]$LibraryWebUrl = 'https://aspectengwa.sharepoint.com/sites/Design/Shared%20Documents',
    [string]$TenantId = 'a2f1a70f-1bf7-48c7-9b0f-c0d3f912a76e',
    $ExistingConfig = $null,
    [switch]$LoadFunctionsOnly
)

function Get-CompanyBackupValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function ConvertTo-CompanyBackupUrl {
    param([string]$Value)
    $uri = $null
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -ne $Value.Trim()) {
        return $null
    }
    # Check before System.Uri can collapse dot segments or normalize backslashes.
    $decoded = [uri]::UnescapeDataString($Value)
    if ($decoded -match '[\\\x00-\x1f]|(^|/)\.{1,2}(/|$)' -or $Value -match '%2f|%5c' -or
        -not [uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri)) { return $null }
    if ($uri.Scheme -ne 'https' -or -not $uri.IsDefaultPort -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) { return $null }
    return ('https://' + $uri.DnsSafeHost + [uri]::UnescapeDataString($uri.AbsolutePath).TrimEnd('/')).ToLowerInvariant()
}

function ConvertTo-CompanyBackupTenant {
    param([string]$Value)
    $id = [guid]::Empty
    if ([guid]::TryParse($Value, [ref]$id)) { return $id.ToString() }
    return $null
}

function ConvertTo-CompanyBackupPath {
    param([string]$Value)
    # Local DOS paths only. Reject spellings which Windows could silently alias.
    if ($Value -notmatch '^[A-Za-z]:\\' -or $Value.Substring(2) -match '[:/\x00-\x1f*?"<>|]') { return $null }
    $path = $Value.TrimEnd('\')
    foreach ($segment in $path.Substring(2).Split('\')) {
        if ($segment -eq '.' -or $segment -eq '..' -or $segment -match '[. ]$' -or
            $segment -match '^(?i:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|$)') { return $null }
    }
    if ($path.Length -le 2 -or $path.Substring(2).Contains('\\')) { return $null }
    try { return [IO.Path]::GetFullPath($path).TrimEnd('\') } catch { return $null }
}

function Read-CompanyBackupRegistryKey {
    param([string]$Path, [string[]]$ValueNames = @(), [switch]$AllValues)
    # CurrentUser only; read permission only; no email, credentials or log output.
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Path, $false)
    if ($null -eq $key) { return $null }
    try {
        $values = @{}
        $names = if ($AllValues) { @($key.GetValueNames()) } else { $ValueNames }
        foreach ($name in $names) {
            $value = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if ($null -ne $value) { $values[$name] = $value }
        }
        return [pscustomobject]@{ Values = $values; SubKeyNames = @($key.GetSubKeyNames()) }
    }
    finally { $key.Dispose() }
}

function Get-CompanyBackupRegistryEvidence {
    $accounts = @(); $providers = @()
    try {
        $base = 'Software\Microsoft\OneDrive\Accounts'
        $root = Read-CompanyBackupRegistryKey -Path $base
        if ($null -ne $root) {
            foreach ($name in $root.SubKeyNames) {
                if ($name -notmatch '^Business\d+$') { continue }
                $account = Read-CompanyBackupRegistryKey -Path "$base\$name" -ValueNames @('ConfiguredTenantId', 'UserFolder', 'UserEmail')
                if ($null -eq $account) { throw 'Registry changed during discovery.' }
                $cache = Read-CompanyBackupRegistryKey -Path "$base\$name\ScopeIdToMountPointPathCache" -AllValues
                $scopes = if ($null -ne $cache) { $cache.Values } else { @{} }
                $accounts += [pscustomobject]@{
                    TenantId = [string]$account.Values['ConfiguredTenantId']
                    UserFolder = [string]$account.Values['UserFolder']; Scopes = $scopes
                    Account = [string]$account.Values['UserEmail']
                }
            }
        }
        $base = 'Software\SyncEngines\Providers\OneDrive'
        $root = Read-CompanyBackupRegistryKey -Path $base
        if ($null -ne $root) {
            foreach ($name in $root.SubKeyNames) {
                $entry = Read-CompanyBackupRegistryKey -Path "$base\$name" -ValueNames @('UrlNamespace', 'MountPoint', 'TenantId', 'ConfiguredTenantId')
                if ($null -eq $entry) { throw 'Registry changed during discovery.' }
                $providers += [pscustomobject]@{
                    ScopeId = $name; MountPoint = [string]$entry.Values['MountPoint']
                    UrlNamespace = [string]$entry.Values['UrlNamespace']
                    TenantIds = @($entry.Values['TenantId'], $entry.Values['ConfiguredTenantId'] | Where-Object { $null -ne $_ -and [string]$_ -ne '' })
                }
            }
        }
    }
    catch { throw 'Cannot read current-user OneDrive registry mappings safely. Check registry access and retry; no source was selected.' }
    return [pscustomobject]@{ Accounts = $accounts; Providers = $providers }
}

function Get-CompanyBackupPathInfo {
    param([string]$Path)
    # FindFirstFile reads attributes and the reparse tag without opening file data.
    # https://learn.microsoft.com/en-us/windows/win32/fileio/reparse-point-tags
    if (-not ('CompanyBackupSource.NativePath' -as [type])) {
        Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace CompanyBackupSource {
    public sealed class PathInfo {
        public bool IsDirectory;
        public bool IsReparsePoint;
        public uint ReparseTag;
    }
    public static class NativePath {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct FindData {
            public uint Attributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME Creation, Access, Write;
            public uint SizeHigh, SizeLow, Reserved0, Reserved1;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string Name;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 14)] public string AlternateName;
        }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr FindFirstFileW(string name, out FindData data);
        [DllImport("kernel32.dll")] private static extern bool FindClose(IntPtr handle);
        public static PathInfo Read(string path) {
            FindData data;
            IntPtr handle = FindFirstFileW(path, out data);
            if (handle == new IntPtr(-1)) {
                int error = Marshal.GetLastWin32Error();
                if (error == 2 || error == 3) return null;
                throw new Win32Exception(error);
            }
            try {
                return new PathInfo { IsDirectory = (data.Attributes & 16) != 0,
                    IsReparsePoint = (data.Attributes & 1024) != 0, ReparseTag = data.Reserved0 };
            } finally { FindClose(handle); }
        }
    }
}
'@ | Out-Null
    }
    return [CompanyBackupSource.NativePath]::Read($Path)
}

function Test-CompanyBackupSafePath {
    param([string]$Path, [string[]]$AccountRoots = @())
    $normalized = ConvertTo-CompanyBackupPath $Path
    if (-not $normalized) { return $false }
    # Never back up a profile, an ancestor of it, or a whole personal OneDrive.
    foreach ($blocked in @($env:USERPROFILE) + $AccountRoots) {
        $blockedPath = ConvertTo-CompanyBackupPath ([string]$blocked)
        if ($blockedPath -and ($normalized -ieq $blockedPath -or
            $blockedPath.StartsWith($normalized + '\', [StringComparison]::OrdinalIgnoreCase))) { return $false }
    }
    try {
        # Inspect ancestors from the volume downward, before traversing a link.
        $parts = $normalized.Substring(3).Split('\')
        $current = $normalized.Substring(0, 2)
        foreach ($part in $parts) {
            $current += '\' + $part
            $info = Get-CompanyBackupPathInfo -Path $current
            if ($null -eq $info -or -not $info.IsDirectory) { return $false }
            if ($info.IsReparsePoint) {
                # Only IO_REPARSE_TAG_CLOUD and CLOUD_1..F, never name-surrogate tags.
                # UInt64 literals avoid PowerShell 5.1 signed hex conversion surprises.
                if (([uint64]$info.ReparseTag -band [uint64]4294905855) -ne [uint64]2415919130) { return $false }
            }
        }
    }
    catch { return $false }
    return $true
}

function Resolve-CompanyBackupSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LibraryWebUrl,
        [Parameter(Mandatory = $true)][string]$TenantId,
        $ExistingConfig = $null
    )
    $canonicalUrl = 'https://aspectengwa.sharepoint.com/sites/Design/Shared%20Documents'
    $targetUrl = ConvertTo-CompanyBackupUrl $LibraryWebUrl
    $targetTenant = ConvertTo-CompanyBackupTenant $TenantId
    if (-not $targetUrl -or $targetUrl -ne (ConvertTo-CompanyBackupUrl $canonicalUrl)) {
        throw 'Invalid or unsupported library URL. Supply the exact Design Shared Documents library URL without Forms/AllItems.aspx, query, or fragment.'
    }
    if ($targetTenant -ne 'a2f1a70f-1bf7-48c7-9b0f-c0d3f912a76e') { throw 'Unsupported company tenant ID.' }

    $evidence = Get-CompanyBackupRegistryEvidence
    $accountRoots = @($evidence.Accounts | ForEach-Object { $_.UserFolder }) + @($env:OneDrive, $env:OneDriveCommercial)
    $candidates = @{}
    foreach ($provider in $evidence.Providers) {
        if ((ConvertTo-CompanyBackupUrl $provider.UrlNamespace) -ne $targetUrl) { continue }
        $mount = ConvertTo-CompanyBackupPath $provider.MountPoint
        if (-not $mount) { throw 'An exact library registry mapping has an unsafe local path; no source was selected.' }
        $tenants = @($provider.TenantIds)
        $conflict = $false
        foreach ($account in $evidence.Accounts) {
            if ($account.Scopes.ContainsKey($provider.ScopeId)) {
                $scopeMount = ConvertTo-CompanyBackupPath ([string]$account.Scopes[$provider.ScopeId])
                if ($scopeMount -ine $mount) { $conflict = $true }
                $tenants += $account.TenantId
            }
        }
        if ($tenants.Count -eq 0) { continue }
        foreach ($tenant in $tenants) {
            if ((ConvertTo-CompanyBackupTenant ([string]$tenant)) -ne $targetTenant) { $conflict = $true }
        }
        if ($conflict) { throw 'Cannot prove the Design library mapping: registry tenant or scope/mount evidence conflicts. No source was selected.' }
        foreach ($other in $evidence.Providers) {
            if ((ConvertTo-CompanyBackupPath $other.MountPoint) -ieq $mount -and
                (ConvertTo-CompanyBackupUrl $other.UrlNamespace) -ne $targetUrl) {
                throw 'Cannot prove the Design library mapping: registry namespaces conflict at the same mount. No source was selected.'
            }
        }
        if (-not (Test-CompanyBackupSafePath -Path $mount -AccountRoots $accountRoots)) {
            throw 'The proven library registry mapping has an unavailable or unsafe local root (including redirected ancestors). No source was selected.'
        }
        if (-not $candidates.ContainsKey($mount)) { $candidates[$mount] = 'Registry' }
    }

    $configRoot = ConvertTo-CompanyBackupPath ([string](Get-CompanyBackupValue $ExistingConfig 'SourceRoot'))
    $validConfig = (Get-CompanyBackupValue $ExistingConfig 'TargetType') -eq 'SharePoint' -and
        (ConvertTo-CompanyBackupUrl ([string](Get-CompanyBackupValue $ExistingConfig 'LibraryWebUrl'))) -eq $targetUrl -and
        (ConvertTo-CompanyBackupTenant ([string](Get-CompanyBackupValue $ExistingConfig 'TenantId'))) -eq $targetTenant -and
        $configRoot -and (Test-CompanyBackupSafePath -Path $configRoot -AccountRoots $accountRoots)
    if ($validConfig) {
        foreach ($account in $evidence.Accounts) {
            foreach ($scopePath in $account.Scopes.Values) {
                $mount = ConvertTo-CompanyBackupPath ([string]$scopePath)
                if ($mount -and $mount -ine $configRoot -and
                    ($mount.StartsWith($configRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or
                     $configRoot.StartsWith($mount + '\', [StringComparison]::OrdinalIgnoreCase))) { $validConfig = $false }
            }
        }
        foreach ($provider in $evidence.Providers) {
            $mount = ConvertTo-CompanyBackupPath $provider.MountPoint
            if (-not $mount) { continue }
            if ($mount -ieq $configRoot) {
                if ((ConvertTo-CompanyBackupUrl $provider.UrlNamespace) -ne $targetUrl) { $validConfig = $false }
            }
            elseif ($mount.StartsWith($configRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or
                $configRoot.StartsWith($mount + '\', [StringComparison]::OrdinalIgnoreCase)) { $validConfig = $false }
        }
        if ($validConfig -and -not $candidates.ContainsKey($configRoot)) { $candidates[$configRoot] = 'ExistingConfig' }
    }
    if ($candidates.Count -gt 1) { throw 'Design library source is ambiguous: more than one distinct local root is evidenced. Reconcile OneDrive mappings/configuration; no source was selected.' }
    if ($candidates.Count -eq 0) {
        throw 'Cannot prove the exact local Design library root for the company tenant. Sync that SharePoint library with OneDrive for this Windows user and retry, or supply a previously validated matching SharePoint config. No folder-name guessing was performed.'
    }
    $root = @($candidates.Keys)[0]
    return [pscustomobject]@{
        SourceRoot = $root; TargetType = 'SharePoint'; LibraryWebUrl = $canonicalUrl
        TenantId = $targetTenant; DiscoveryMethod = $candidates[$root]
    }
}

if ($LoadFunctionsOnly) { return }
Resolve-CompanyBackupSource -LibraryWebUrl $LibraryWebUrl -TenantId $TenantId -ExistingConfig $ExistingConfig
