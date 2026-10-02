#requires -Version 5.1
<##
.SYNOPSIS
Enrolls a caller-pinned backup app and this user's local public certificate.
.DESCRIPTION
Call only after the installer's app-only read probe fails. The caller creates a
nonexportable RSA certificate in CurrentUser\My and supplies the four fixed
deployment values; this helper creates no app, private-key file or configuration.
Requires an existing home-tenant app registration and service principal, and the
already installed Microsoft.Graph.Authentication module. Browser sign-in may
require IT: Graph app-role consent requires Privileged Role Administrator (or
equivalent), and site grants require SharePoint Administrator (or equivalent).

Run enrollments for the same app serially, including on different computers.
Graph application PATCH replaces collections and has no documented conditional
update guarantee. Re-read/verify detects some races, not all; no destructive
rollback or automatic write retry is performed. Partial enrollment is retained
and a later serialized run can resume. The caller must repeat its app-only probe
after success because directory changes may take time to propagate.

Only the specified site is inspected or granted. Pre-existing permissions on
other sites are neither enumerated nor revoked; this is not a tenant-wide audit.
.OUTPUTS
One object: Status (Enrolled/AlreadyEnrolled), TenantId, ClientId,
CertificateThumbprint, ApplicationObjectId, SiteId, SiteUrl, CredentialAdded,
AppPermissionAdded, SitePermissionAdded. Throws on failure; always disconnects
the admin session. LoadFunctionsOnly defines functions without importing Graph
or touching certificates/network. Dot-source that mode for offline mock tests.
.NOTES
Microsoft Graph v1.0 references:
https://learn.microsoft.com/en-us/graph/api/application-update
https://learn.microsoft.com/en-us/graph/api/resources/keycredential
https://learn.microsoft.com/en-us/graph/api/serviceprincipal-post-approleassignments
https://learn.microsoft.com/en-us/graph/api/site-post-permissions
https://learn.microsoft.com/en-us/graph/api/site-list-permissions
##>
[CmdletBinding()]
param(
    [string]$TenantId,
    [string]$ClientId,
    [string]$CertificateThumbprint,
    [string]$SiteUrl,
    [switch]$LoadFunctionsOnly
)

function Assert-CompanyEnrollmentGuid {
    param([string]$Value, [string]$Label)
    if ($Value -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' -or [guid]$Value -eq [guid]::Empty) {
        throw "A nonempty GUID is required for $Label."
    }
}

function Assert-CompanyEnrollmentGraphUrl {
    param([string]$Uri)
    $parsed = $null
    if (-not [Uri]::TryCreate($Uri, [UriKind]::Absolute, [ref]$parsed) -or
        $parsed.Scheme -ne 'https' -or $parsed.Host -ine 'graph.microsoft.com' -or
        $parsed.Port -ne 443 -or $parsed.UserInfo -or $parsed.Fragment -or
        -not $parsed.AbsolutePath.StartsWith('/v1.0/', [StringComparison]::Ordinal)) {
        throw 'Refusing unexpected Graph URL (including pagination).'
    }
}

function Get-CompanyEnrollmentCollection {
    param([string]$Uri)
    $seen = @{}
    while ($Uri) {
        Assert-CompanyEnrollmentGraphUrl $Uri
        if ($seen.ContainsKey($Uri) -or $seen.Count -ge 1000) { throw 'Graph pagination repeated or exceeded the safety bound.' }
        $seen[$Uri] = $true
        $page = Invoke-MgGraphRequest -Method GET -Uri $Uri -OutputType PSObject -ErrorAction Stop
        if ($null -eq $page.value) { throw 'Graph collection response omitted value; refusing incomplete enumeration.' }
        foreach ($item in $page.value) { $item }
        $Uri = [string]$page.'@odata.nextLink'
    }
}

function Get-CompanyEnrollmentFingerprint {
    # Compare JSON structurally. Collection/property order and OData annotations
    # are immaterial; public key Base64 and other values are case-sensitive.
    param($Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [Collections.IDictionary]) {
        $pairs = @(foreach ($name in @($Value.Keys | Sort-Object)) {
            if ([string]$name -notlike '@odata.*') {
                (ConvertTo-Json -InputObject ([string]$name) -Compress) + ':' + (Get-CompanyEnrollmentFingerprint $Value[$name])
            }
        })
        return '{' + ($pairs -join ',') + '}'
    }
    if ($Value -is [pscustomobject]) {
        $map = @{}
        foreach ($property in $Value.PSObject.Properties) { $map[$property.Name] = $property.Value }
        return Get-CompanyEnrollmentFingerprint $map
    }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
        $items = @(foreach ($item in $Value) { Get-CompanyEnrollmentFingerprint $item })
        return '[' + (($items | Sort-Object -CaseSensitive) -join ',') + ']'
    }
    return ConvertTo-Json -InputObject $Value -Compress
}

function Get-CompanyEnrollmentAppState {
    param($Application, [string]$ClientId)
    if ($null -eq $Application -or $Application.appId -ine $ClientId) { throw 'Resolved application does not match the pinned client ID.' }
    Assert-CompanyEnrollmentGuid ([string]$Application.id) 'application object ID'
    if ($null -eq $Application.keyCredentials -or $null -eq $Application.requiredResourceAccess) {
        throw 'Application omitted selected credential/access collections; refusing an incomplete snapshot.'
    }
    $keyIds = @{}
    $keys = @(foreach ($key in $Application.keyCredentials) {
        Assert-CompanyEnrollmentGuid ([string]$key.keyId) 'key ID'
        if ($keyIds.ContainsKey([string]$key.keyId)) { throw 'Duplicate application key IDs require IT review.' }
        $keyIds[[string]$key.keyId] = $true
        if ([string]::IsNullOrWhiteSpace([string]$key.key)) { throw 'Existing credential key bytes are missing; cannot safely preserve keyCredentials.' }
        try { $bytes = [Convert]::FromBase64String([string]$key.key) } catch { throw 'Existing credential key bytes are invalid.' }
        if ($bytes.Length -eq 0) { throw 'Existing credential key bytes are empty.' }
        $copy = [ordered]@{}
        foreach ($field in @('keyId', 'key', 'type', 'usage', 'customKeyIdentifier', 'displayName', 'startDateTime', 'endDateTime')) {
            $value = $key.$field
            if ($field -in @('startDateTime', 'endDateTime') -and $null -ne $value) {
                $value = ([DateTimeOffset]::Parse([string]$value, [Globalization.CultureInfo]::InvariantCulture)).UtcDateTime.ToString('o')
            }
            $copy[$field] = $value
        }
        [pscustomobject]$copy
    })
    [pscustomobject]@{ id = [string]$Application.id; appId = [string]$Application.appId; keyCredentials = $keys; requiredResourceAccess = @($Application.requiredResourceAccess) }
}

function Get-CompanyEnrollmentCertificate {
    param([string]$Thumbprint)
    if ($Thumbprint -notmatch '^[0-9a-fA-F]{40}$') { throw 'CertificateThumbprint must contain exactly 40 hexadecimal characters.' }
    $cert = Get-Item -LiteralPath ('Cert:\CurrentUser\My\' + $Thumbprint) -ErrorAction Stop
    $now = [DateTime]::UtcNow
    if ($null -eq $cert -or $cert.Thumbprint -ine $Thumbprint -or -not $cert.HasPrivateKey -or
        $cert.NotBefore.ToUniversalTime() -gt $now -or $cert.NotAfter.ToUniversalTime() -le $now) {
        throw 'The local certificate must match, have a private key, and be currently valid.'
    }
    # Cert exports public DER only. Never export PFX/Pkcs12 or read the private key.
    [pscustomobject]@{
        keyId = [guid]::NewGuid().ToString()
        key = [Convert]::ToBase64String($cert.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert))
        customKeyIdentifier = [Convert]::ToBase64String($cert.GetCertHash())
        type = 'AsymmetricX509Cert'; usage = 'Verify'
        displayName = 'Company backup ' + $Thumbprint.ToUpperInvariant()
        startDateTime = $cert.NotBefore.ToUniversalTime().ToString('o')
        endDateTime = $cert.NotAfter.ToUniversalTime().ToString('o')
    }
}

function Assert-CompanyEnrollmentContext {
    param([string]$TenantId, [string[]]$Scopes)
    $context = Get-MgContext
    if ($null -eq $context -or $context.TenantId -ine $TenantId -or
        $context.AuthType -ne 'Delegated' -or $context.ContextScope -ne 'Process' -or $context.Environment -ne 'Global') {
        throw 'Administrator Graph context does not match the requested tenant/process/delegated environment.'
    }
    foreach ($scope in $Scopes) {
        if ($scope -notin @($context.Scopes)) { throw "Administrator context is missing delegated scope $scope." }
    }
}

function Get-CompanyEnrollmentPrincipal {
    param([string]$AppId)
    $filter = [Uri]::EscapeDataString("appId eq '$AppId'")
    $uri = 'https://graph.microsoft.com/v1.0/servicePrincipals?$filter={0}&$select=id,appId,appOwnerOrganizationId,appRoles' -f $filter
    $matches = @(Get-CompanyEnrollmentCollection $uri)
    if ($matches.Count -ne 1 -or $matches[0].appId -ine $AppId) { throw 'Expected exactly one service principal for the pinned application.' }
    Assert-CompanyEnrollmentGuid ([string]$matches[0].id) 'service principal object ID'
    return $matches[0]
}

function Assert-CompanyEnrollmentRoles {
    param($State, [object[]]$Assignments, [string]$GraphId, [string]$SelectedId, [string]$PrincipalId)
    foreach ($resource in $State.requiredResourceAccess) {
        if ($resource.resourceAppId -eq '00000003-0000-0000-c000-000000000000') {
            foreach ($access in $resource.resourceAccess) {
                if ($access.type -eq 'Role' -and $access.id -ne $SelectedId) { throw 'A pre-existing Graph application role is broader than Sites.Selected; IT must review it. Nothing will be revoked.' }
            }
        }
    }
    foreach ($assignment in $Assignments) {
        if ($assignment.principalId -ne $PrincipalId) { throw 'Unexpected principal in application role assignments.' }
        if ($assignment.resourceId -eq $GraphId -and $assignment.appRoleId -ne $SelectedId) { throw 'A pre-existing assigned Graph application role is not Sites.Selected; IT must review it. Nothing will be revoked.' }
    }
    $selected = @($Assignments | Where-Object { $_.resourceId -eq $GraphId -and $_.appRoleId -eq $SelectedId })
    if ($selected.Count -gt 1) { throw 'Duplicate Graph app role assignments require IT review.' }
}

function Get-CompanyEnrollmentSiteGrant {
    param([object[]]$Permissions, [string]$ClientId)
    $matches = @(foreach ($permission in $Permissions) {
        $identities = @($permission.grantedToIdentitiesV2) + @($permission.grantedToIdentities) + @($permission.grantedToV2) + @($permission.grantedTo)
        if (@($identities | Where-Object { $null -ne $_ -and $_.application.id -eq $ClientId }).Count -gt 0) { $permission }
    })
    if ($matches.Count -gt 1) { throw 'Duplicate site permissions for the backup app require IT review.' }
    if ($matches.Count -eq 1) {
        if (@($matches[0].roles).Count -ne 1 -or $matches[0].roles[0] -ne 'write') {
            throw 'The existing site permission is not exactly write; IT must review it. It will not be overwritten or duplicated.'
        }
        return $matches[0]
    }
}

function Register-CompanyBackupCredential {
    [CmdletBinding()]
    param([string]$TenantId, [string]$ClientId, [string]$CertificateThumbprint, [string]$SiteUrl)
    $ErrorActionPreference = 'Stop'
    Assert-CompanyEnrollmentGuid $TenantId 'TenantId'
    Assert-CompanyEnrollmentGuid $ClientId 'ClientId'
    $siteUri = $null
    if (-not [Uri]::TryCreate($SiteUrl, [UriKind]::Absolute, [ref]$siteUri) -or
        $siteUri.Scheme -ne 'https' -or $siteUri.Host -notmatch '^[a-z0-9-]+\.sharepoint\.com$' -or
        $siteUri.Port -ne 443 -or $siteUri.UserInfo -or $siteUri.Query -or $siteUri.Fragment -or
        $siteUri.AbsolutePath -notmatch '^/(?:$|(?:sites|teams)/[a-zA-Z0-9_.~%-]+/?)$' -or
        [Uri]::UnescapeDataString($siteUri.AbsolutePath) -match '(?:\.{2}|[\\:#?])') {
        throw 'SiteUrl must be an HTTPS SharePoint site collection URL, without query, fragment or subsite.'
    }
    $certificate = Get-CompanyEnrollmentCertificate $CertificateThumbprint
    $scopes = @('Application.ReadWrite.All', 'AppRoleAssignment.ReadWrite.All', 'Sites.FullControl.All')
    $graphAppId = '00000003-0000-0000-c000-000000000000'
    $credentialAdded = $false; $appPermissionAdded = $false; $sitePermissionAdded = $false
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    try {
        if ($null -ne (Get-MgContext)) { Disconnect-MgGraph -ErrorAction Stop | Out-Null }
        Write-Host 'Sign in to Microsoft with an IT account authorized to manage this app, Graph app consent, and SharePoint site permissions.'
        Connect-MgGraph -TenantId $TenantId -Scopes $scopes -ContextScope Process -Environment Global -NoWelcome -ErrorAction Stop | Out-Null
        Assert-CompanyEnrollmentContext $TenantId $scopes
        # Single-object $select is essential: collection reads omit public key bytes.
        $appUri = "https://graph.microsoft.com/v1.0/applications(appId='$ClientId')?" + '$select=id,appId,displayName,keyCredentials,requiredResourceAccess'
        $app = Invoke-MgGraphRequest -Method GET -Uri $appUri -OutputType PSObject -ErrorAction Stop
        $state = Get-CompanyEnrollmentAppState $app $ClientId
        $principal = Get-CompanyEnrollmentPrincipal $ClientId
        if ($principal.appOwnerOrganizationId -ine $TenantId) { throw 'Runtime service principal is not owned by the pinned tenant.' }
        $graph = Get-CompanyEnrollmentPrincipal $graphAppId
        $roles = @($graph.appRoles | Where-Object { $_.value -eq 'Sites.Selected' -and $_.isEnabled -and 'Application' -in $_.allowedMemberTypes })
        if ($roles.Count -ne 1) { throw 'Graph did not return one enabled Sites.Selected application role.' }
        $selectedId = [string]$roles[0].id
        Assert-CompanyEnrollmentGuid $selectedId 'Sites.Selected role ID'
        $assignmentsUri = 'https://graph.microsoft.com/v1.0/servicePrincipals/' + $principal.id + '/appRoleAssignments'
        $assignments = @(Get-CompanyEnrollmentCollection $assignmentsUri)
        Assert-CompanyEnrollmentRoles $state $assignments $graph.id $selectedId $principal.id
        $resolveUri = 'https://graph.microsoft.com/v1.0/sites/' + $siteUri.Host + ':' + $siteUri.AbsolutePath.TrimEnd('/')
        if ($siteUri.AbsolutePath -eq '/') { $resolveUri += '/' }
        $site = Invoke-MgGraphRequest -Method GET -Uri $resolveUri -OutputType PSObject -ErrorAction Stop
        if (-not $site.id -or ([string]$site.webUrl).TrimEnd('/') -ine $siteUri.AbsoluteUri.TrimEnd('/')) { throw 'Resolved site does not match the intended SiteUrl.' }
        $permissionsUri = 'https://graph.microsoft.com/v1.0/sites/' + [Uri]::EscapeDataString([string]$site.id) + '/permissions'
        $permissions = @(Get-CompanyEnrollmentCollection $permissionsUri)
        $siteGrant = Get-CompanyEnrollmentSiteGrant $permissions $ClientId

        $sameKey = @($state.keyCredentials | Where-Object { $_.key -ceq $certificate.key })
        if ($sameKey.Count -gt 1) { throw 'Duplicate certificate credentials require IT review.' }
        if ($sameKey.Count -eq 1 -and ($sameKey[0].type -ne 'AsymmetricX509Cert' -or $sameKey[0].usage -ne 'Verify' -or
            [DateTimeOffset]$sameKey[0].startDateTime -gt [DateTimeOffset]::UtcNow -or [DateTimeOffset]$sameKey[0].endDateTime -le [DateTimeOffset]::UtcNow)) {
            throw 'The existing certificate credential is not valid for signing; IT must review it.'
        }
        $patch = @{}
        if ($sameKey.Count -eq 0) { $patch.keyCredentials = @($state.keyCredentials) + @($certificate) }
        $resources = @($state.requiredResourceAccess)
        $graphResources = @($resources | Where-Object resourceAppId -eq $graphAppId)
        if ($graphResources.Count -gt 1) { throw 'Duplicate Graph requiredResourceAccess entries require IT review.' }
        $manifestSelected = @($graphResources | ForEach-Object { $_.resourceAccess } | Where-Object { $_.id -eq $selectedId -and $_.type -eq 'Role' })
        if ($manifestSelected.Count -eq 0) {
            # Clone before adding; preserve all other APIs, delegated scopes and keys.
            $resources = @($resources | ConvertTo-Json -Depth 40 | ConvertFrom-Json)
            if ($graphResources.Count -eq 0) { $resources += [pscustomobject]@{ resourceAppId = $graphAppId; resourceAccess = @([pscustomobject]@{ id = $selectedId; type = 'Role' }) } }
            else {
                $entry = $resources | Where-Object resourceAppId -eq $graphAppId
                $entry.resourceAccess = @($entry.resourceAccess) + @([pscustomobject]@{ id = $selectedId; type = 'Role' })
            }
            $patch.requiredResourceAccess = $resources
        }
        if ($patch.Count -gt 0) {
            Write-Warning 'Serialize enrollment for this app across all computers: concurrent edits are not fully race-proof. Graph application PATCH has no documented ETag concurrency guarantee; re-read and verification cannot close the race window.'
            $current = Invoke-MgGraphRequest -Method GET -Uri $appUri -OutputType PSObject -ErrorAction Stop
            $currentState = Get-CompanyEnrollmentAppState $current $ClientId
            if ((Get-CompanyEnrollmentFingerprint $state) -cne (Get-CompanyEnrollmentFingerprint $currentState)) { throw 'Application credentials or requiredResourceAccess changed before write; stop and retry serially.' }
            $expected = Get-CompanyEnrollmentAppState $app $ClientId
            foreach ($name in $patch.Keys) { $expected.$name = $patch[$name] }
            $headers = @{}
            if ($current.'@odata.etag') { $headers['If-Match'] = [string]$current.'@odata.etag' }
            Assert-CompanyEnrollmentContext $TenantId $scopes
            Invoke-MgGraphRequest -Method PATCH -Uri ('https://graph.microsoft.com/v1.0/applications/' + $state.id) -Headers $headers -Body (ConvertTo-Json -InputObject $patch -Depth 40 -Compress) -ContentType 'application/json' -ErrorAction Stop | Out-Null
            $after = Invoke-MgGraphRequest -Method GET -Uri $appUri -OutputType PSObject -ErrorAction Stop
            $state = Get-CompanyEnrollmentAppState $after $ClientId
            if ((Get-CompanyEnrollmentFingerprint $expected) -cne (Get-CompanyEnrollmentFingerprint $state)) { throw 'Application verification failed after write; no rollback attempted. IT must inspect concurrent changes.' }
            $credentialAdded = $patch.ContainsKey('keyCredentials')
        }

        $currentAssignments = @(Get-CompanyEnrollmentCollection $assignmentsUri)
        Assert-CompanyEnrollmentRoles $state $currentAssignments $graph.id $selectedId $principal.id
        if ((Get-CompanyEnrollmentFingerprint $assignments) -cne (Get-CompanyEnrollmentFingerprint $currentAssignments)) { throw 'App role assignments changed during enrollment; retry serially.' }
        if (@($currentAssignments | Where-Object { $_.resourceId -eq $graph.id -and $_.appRoleId -eq $selectedId }).Count -eq 0) {
            Assert-CompanyEnrollmentContext $TenantId $scopes
            $grantBody = @{ principalId = $principal.id; resourceId = $graph.id; appRoleId = $selectedId }
            Invoke-MgGraphRequest -Method POST -Uri ('https://graph.microsoft.com/v1.0/servicePrincipals/' + $graph.id + '/appRoleAssignedTo') -Body (ConvertTo-Json -InputObject $grantBody -Compress) -ContentType 'application/json' -ErrorAction Stop | Out-Null
            $appPermissionAdded = $true
        }
        $afterAssignments = @(Get-CompanyEnrollmentCollection $assignmentsUri)
        Assert-CompanyEnrollmentRoles $state $afterAssignments $graph.id $selectedId $principal.id
        if (@($afterAssignments | Where-Object { $_.resourceId -eq $graph.id -and $_.appRoleId -eq $selectedId }).Count -ne 1) { throw 'Graph app permission verification failed; retry after propagation.' }
        foreach ($old in $assignments) {
            if (@($afterAssignments | Where-Object { (Get-CompanyEnrollmentFingerprint $_) -ceq (Get-CompanyEnrollmentFingerprint $old) }).Count -ne 1) { throw 'Existing app role assignment verification failed.' }
        }
        $currentPermissions = @(Get-CompanyEnrollmentCollection $permissionsUri)
        if ((Get-CompanyEnrollmentFingerprint $permissions) -cne (Get-CompanyEnrollmentFingerprint $currentPermissions)) { throw 'Site permissions changed during enrollment; retry serially.' }
        if ($null -eq $siteGrant) {
            Assert-CompanyEnrollmentContext $TenantId $scopes
            $grantBody = @{ roles = @('write'); grantedToIdentities = @(@{ application = @{ id = $ClientId; displayName = [string]$app.displayName } }) }
            Invoke-MgGraphRequest -Method POST -Uri $permissionsUri -Body (ConvertTo-Json -InputObject $grantBody -Depth 10 -Compress) -ContentType 'application/json' -ErrorAction Stop | Out-Null
            $sitePermissionAdded = $true
        }
        $afterPermissions = @(Get-CompanyEnrollmentCollection $permissionsUri)
        if ($null -eq (Get-CompanyEnrollmentSiteGrant $afterPermissions $ClientId)) { throw 'Site permission verification failed; retry after propagation.' }
        foreach ($old in $permissions) {
            if (@($afterPermissions | Where-Object { (Get-CompanyEnrollmentFingerprint $_) -ceq (Get-CompanyEnrollmentFingerprint $old) }).Count -ne 1) { throw 'Existing site permission verification failed.' }
        }
        [pscustomobject]@{
            Status = $(if ($patch.Count -gt 0 -or $appPermissionAdded -or $sitePermissionAdded) { 'Enrolled' } else { 'AlreadyEnrolled' })
            TenantId = $TenantId; ClientId = $ClientId; CertificateThumbprint = $CertificateThumbprint.ToUpperInvariant()
            ApplicationObjectId = $state.id; SiteId = [string]$site.id; SiteUrl = [string]$site.webUrl
            CredentialAdded = $credentialAdded; AppPermissionAdded = $appPermissionAdded; SitePermissionAdded = $sitePermissionAdded
        }
    }
    finally { Disconnect-MgGraph -ErrorAction Stop | Out-Null }
}

if (-not $LoadFunctionsOnly) {
    Register-CompanyBackupCredential -TenantId $TenantId -ClientId $ClientId -CertificateThumbprint $CertificateThumbprint -SiteUrl $SiteUrl
}
