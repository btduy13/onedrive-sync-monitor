# Offline contract tests. Run with Windows PowerShell 5.1; no Graph module or tenant needed.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

# Install all external boundaries BEFORE loading the helper: accidental live calls fail closed.
function Import-Module { param($Name) if ($Name -ne 'Microsoft.Graph.Authentication') { throw 'Unexpected import' } }
function Connect-MgGraph {
    param($TenantId, $Scopes, $ContextScope, $Environment, [switch]$NoWelcome, [switch]$UseDeviceAuthentication)
    $script:connect = $PSBoundParameters
    if ($script:connectFails) { throw 'Mock interactive sign-in cancelled' }
}
function Disconnect-MgGraph { $script:disconnects++ }
function Get-MgContext { return $script:context }
function Get-Item {
    param($LiteralPath)
    if ($LiteralPath -ne ('Cert:\CurrentUser\My\' + $script:thumb)) { throw 'Unexpected certificate path' }
    return $script:certificate
}
function Copy-TestValue($Value) { return ($Value | ConvertTo-Json -Depth 40 -Compress | ConvertFrom-Json) }
function Invoke-MgGraphRequest {
    param($Method, $Uri, $Body, $ContentType, $OutputType, $Headers)
    $script:calls += [pscustomobject]@{ Method = $Method; Uri = $Uri; Body = $Body; Headers = $Headers }
    if ($Method -eq 'GET') {
        if ($Uri -like '*/applications(*') {
            if ($Uri -notlike '*$select=*keyCredentials*') { throw 'Application read MUST select keyCredentials' }
            $script:appReads++
            if ($script:appReads -eq 2 -and $script:concurrentApp) { $script:app.keyCredentials += Copy-TestValue $script:otherKey }
            return Copy-TestValue $script:app
        }
        if ($Uri.StartsWith('https://graph.microsoft.com/v1.0/servicePrincipals?')) {
            if ([Uri]::UnescapeDataString($Uri) -like "*appId eq '$script:graphAppId'*") { return @{ value = @($script:graph) } }
            return @{ value = @($script:principal) }
        }
        if ($Uri -like '*/appRoleAssignments*') {
            if ($script:roleNext -and $Uri -notlike '*skiptoken*') { return @{ value = @(); '@odata.nextLink' = $script:roleNext } }
            return @{ value = @($script:assignments) }
        }
        if ($Uri -like '*/permissions*') {
            $script:permissionReads++
            if ($script:permissionReads -eq 2 -and $script:concurrentPermission) { $script:permissions += New-TestPermission $script:client 'write' }
            if ($script:permissionNext -and $Uri -notlike '*skiptoken*') { return @{ value = @(); '@odata.nextLink' = $script:permissionNext } }
            return @{ value = @($script:permissions) }
        }
        if ($Uri -like '*/sites/*') { return Copy-TestValue $script:site }
    }
    if ($Method -eq 'PATCH' -and $Uri -eq ('https://graph.microsoft.com/v1.0/applications/' + $script:app.id)) {
        if ($script:patchFails) { throw 'Mock conditional update failed' }
        $patch = $Body | ConvertFrom-Json
        foreach ($property in $patch.PSObject.Properties) {
            if ($property.Name -notin @('keyCredentials', 'requiredResourceAccess')) { throw 'Unexpected application change' }
            $script:app.($property.Name) = $property.Value
        }
        if ($script:dropKeyAfterWrite) { $script:app.keyCredentials = @($script:app.keyCredentials | Select-Object -Last 1) }
        return
    }
    if ($Method -eq 'POST' -and $Uri -eq ('https://graph.microsoft.com/v1.0/servicePrincipals/' + $script:graph.id + '/appRoleAssignedTo')) {
        $grant = $Body | ConvertFrom-Json
        if ($grant.principalId -ne $script:principal.id -or $grant.resourceId -ne $script:graph.id -or $grant.appRoleId -ne $script:selected) { throw 'Wrong app assignment' }
        if ($script:postFails) { throw 'Mock grant failed' }
        $grant | Add-Member NoteProperty id 'assignment-new'
        $script:assignments += $grant
        return $grant
    }
    if ($Method -eq 'POST' -and $Uri -eq ('https://graph.microsoft.com/v1.0/sites/' + [Uri]::EscapeDataString($script:site.id) + '/permissions')) {
        $grant = $Body | ConvertFrom-Json
        if (@($grant.roles).Count -ne 1 -or $grant.roles[0] -ne 'write' -or @($grant.grantedToIdentities).Count -ne 1 -or $grant.grantedToIdentities[0].application.id -ne $script:client) { throw 'Wrong site grant' }
        $grant | Add-Member NoteProperty id 'permission-new'
        $script:permissions += $grant
        return $grant
    }
    throw "Unexpected mock request: $Method $Uri"
}

$script:tenant = '11111111-1111-1111-1111-111111111111'
$script:client = '22222222-2222-2222-2222-222222222222'
$script:thumb = 'AABBCCDDEEFF00112233445566778899AABBCCDD'
$script:graphAppId = '00000003-0000-0000-c000-000000000000'
$script:selected = '883ea226-0bf2-4a8f-9f9d-92c9162a727d'
$script:inputs = @{ TenantId = $script:tenant; ClientId = $script:client; CertificateThumbprint = $script:thumb; SiteUrl = 'https://example.sharepoint.com/sites/Backup' }
$script:otherKey = [pscustomobject]@{ keyId = '77777777-7777-7777-7777-777777777777'; key = 'BAUG'; customKeyIdentifier = 'AQID'; type = 'AsymmetricX509Cert'; usage = 'Verify'; displayName = 'Existing machine'; startDateTime = '2025-01-01T00:00:00Z'; endDateTime = '2030-01-01T00:00:00Z' }
function New-TestPermission($Client, $Role) {
    return [pscustomobject]@{ id = 'permission-' + $Client; roles = @($Role); grantedToIdentitiesV2 = @(@{ application = @{ id = $Client } }) }
}
function Reset-TestState {
    $script:calls = @(); $script:connect = $null; $script:disconnects = 0; $script:appReads = 0; $script:permissionReads = 0
    $script:connectFails = $false; $script:patchFails = $false; $script:postFails = $false; $script:dropKeyAfterWrite = $false
    $script:concurrentApp = $false; $script:concurrentPermission = $false; $script:roleNext = $null; $script:permissionNext = $null
    $script:context = [pscustomobject]@{ TenantId = $script:tenant; ClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e'; AuthType = 'Delegated'; ContextScope = 'Process'; Environment = 'Global'; Scopes = @('Application.ReadWrite.All', 'AppRoleAssignment.ReadWrite.All', 'Sites.FullControl.All') }
    $script:certificate = [pscustomobject]@{ Thumbprint = $script:thumb; HasPrivateKey = $true; NotBefore = [DateTime]::UtcNow.AddDays(-1); NotAfter = [DateTime]::UtcNow.AddYears(1) }
    $script:certificate | Add-Member ScriptMethod Export { param($Type) if ($Type -ne [Security.Cryptography.X509Certificates.X509ContentType]::Cert) { throw 'Private export prohibited' }; return [byte[]]@(1,2,3) }
    $script:certificate | Add-Member ScriptMethod GetCertHash { return [byte[]]@(170,187,204) }
    $script:app = [pscustomobject]@{ id = '33333333-3333-3333-3333-333333333333'; appId = $script:client; displayName = 'Company backup'; keyCredentials = @(); requiredResourceAccess = @(@{ resourceAppId = '88888888-8888-8888-8888-888888888888'; resourceAccess = @(@{ id = '99999999-9999-9999-9999-999999999999'; type = 'Scope' }) }) }
    $script:principal = [pscustomobject]@{ id = '44444444-4444-4444-4444-444444444444'; appId = $script:client; appOwnerOrganizationId = $script:tenant }
    $script:graph = [pscustomobject]@{ id = '55555555-5555-5555-5555-555555555555'; appId = $script:graphAppId; appRoles = @(@{ id = $script:selected; value = 'Sites.Selected'; isEnabled = $true; allowedMemberTypes = @('Application') }) }
    $script:site = [pscustomobject]@{ id = 'example.sharepoint.com,site-guid,web-guid'; webUrl = $script:inputs.SiteUrl }
    $script:assignments = @(); $script:permissions = @()
}
function Assert-Test($Condition, $Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
    $message = $null
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
    Assert-Test ($null -ne $message -and $message -like $Pattern) "Expected error '$Pattern'; got '$message'"
}
function Invoke-TestEnrollment { Register-CompanyBackupCredential @script:inputs -WarningAction SilentlyContinue }
function Assert-NoWrites { Assert-Test (@($script:calls | Where-Object Method -ne GET).Count -eq 0) 'Unexpected Graph mutation' }
function Test-Case($Name, [scriptblock]$Action) {
    Reset-TestState
    try { & $Action; $script:passed++; Write-Host "PASS: $Name" }
    catch { $script:failed++; Write-Host "FAIL: $Name -- $($_.Exception.Message)" }
}

Reset-TestState
. (Join-Path $PSScriptRoot 'Register-CompanyBackupCredential.ps1') -LoadFunctionsOnly
Assert-Test ($script:calls.Count -eq 0 -and $null -eq $script:connect) 'LoadFunctionsOnly must not authenticate'
$script:passed = 0; $script:failed = 0

Test-Case 'First key, role and intended site write enrollment; process browser login and cleanup' {
    $result = Invoke-TestEnrollment
    Assert-Test ($result.Status -eq 'Enrolled' -and $result.CredentialAdded -and $result.AppPermissionAdded -and $result.SitePermissionAdded) 'Incorrect status'
    Assert-Test ($script:connect.ContextScope -eq 'Process' -and -not $script:connect.UseDeviceAuthentication -and $script:connect.TenantId -eq $script:tenant) 'Wrong login flow'
    Assert-Test (($script:connect.Scopes | Sort-Object) -join ',' -eq 'Application.ReadWrite.All,AppRoleAssignment.ReadWrite.All,Sites.FullControl.All') 'Unexpected delegated scopes'
    Assert-Test ($script:disconnects -ge 1) 'Admin session not disconnected'
    Assert-Test ($script:app.keyCredentials[0].key -ceq 'AQID') 'Expected public certificate only'
}
Test-Case 'Preserves existing public keys and resource access; repeat is idempotent' {
    $script:app.keyCredentials = @(Copy-TestValue $script:otherKey)
    $before = $script:app.requiredResourceAccess | ConvertTo-Json -Depth 20 -Compress
    Invoke-TestEnrollment | Out-Null
    Assert-Test ($script:app.keyCredentials.Count -eq 2 -and $script:app.keyCredentials[0].key -ceq 'BAUG') 'Existing key lost'
    Assert-Test (($script:app.requiredResourceAccess[0] | ConvertTo-Json -Depth 20 -Compress) -ceq $before) 'Other API access changed'
    $script:calls = @()
    Assert-Test ((Invoke-TestEnrollment).Status -eq 'AlreadyEnrolled') 'Repeat not idempotent'
    Assert-NoWrites
}
Test-Case 'Fails closed on missing existing key bytes' {
    $script:app.keyCredentials = @(Copy-TestValue $script:otherKey); $script:app.keyCredentials[0].key = $null
    Assert-Throws { Invoke-TestEnrollment } '*key bytes*'; Assert-NoWrites
    Assert-Test ($script:disconnects -ge 1) 'No cleanup'
}
Test-Case 'Wrong tenant rejected' { $script:context.TenantId = $script:client; Assert-Throws { Invoke-TestEnrollment } '*context*'; Assert-NoWrites }
Test-Case 'App-only admin context rejected' { $script:context.AuthType = 'AppOnly'; Assert-Throws { Invoke-TestEnrollment } '*context*'; Assert-NoWrites }
Test-Case 'Missing delegated scope rejected' { $script:context.Scopes = @('Application.ReadWrite.All'); Assert-Throws { Invoke-TestEnrollment } '*scope*'; Assert-NoWrites }
Test-Case 'Wrong application rejected' { $script:app.appId = $script:tenant; Assert-Throws { Invoke-TestEnrollment } '*application*'; Assert-NoWrites }
Test-Case 'Foreign-owned runtime principal rejected' { $script:principal.appOwnerOrganizationId = $script:client; Assert-Throws { Invoke-TestEnrollment } '*principal*'; Assert-NoWrites }
Test-Case 'Wrong resolved site rejected' { $script:site.webUrl = 'https://example.sharepoint.com/sites/Other'; Assert-Throws { Invoke-TestEnrollment } '*site*'; Assert-NoWrites }
Test-Case 'Broad manifest Graph role rejected without removing it' {
    $script:app.requiredResourceAccess += @{ resourceAppId = $script:graphAppId; resourceAccess = @(@{ id = $script:tenant; type = 'Role' }) }
    Assert-Throws { Invoke-TestEnrollment } '*Graph*role*'; Assert-NoWrites
}
Test-Case 'Broad assigned Graph role on later page rejected' {
    $script:assignments = @(@{ id = 'old'; principalId = $script:principal.id; resourceId = $script:graph.id; appRoleId = $script:tenant })
    $script:roleNext = 'https://graph.microsoft.com/v1.0/servicePrincipals/' + $script:principal.id + '/appRoleAssignments?$skiptoken=next'
    Assert-Throws { Invoke-TestEnrollment } '*Graph*role*'; Assert-NoWrites
}
Test-Case 'Existing write on later page avoids duplicate site grant; unrelated permission preserved' {
    $script:permissions = @((New-TestPermission $script:tenant 'fullcontrol'), (New-TestPermission $script:client 'write'))
    $script:permissionNext = 'https://graph.microsoft.com/v1.0/sites/' + [Uri]::EscapeDataString($script:site.id) + '/permissions?$skiptoken=next'
    $result = Invoke-TestEnrollment
    Assert-Test (-not $result.SitePermissionAdded -and $script:permissions.Count -eq 2) 'Duplicate or destructive site write'
}
foreach ($role in @('read', 'fullcontrol')) {
    Test-Case "Conflicting existing $role permission requires IT review" {
        $script:permissions = @(New-TestPermission $script:client $role)
        Assert-Throws { Invoke-TestEnrollment } '*site*permission*'; Assert-NoWrites
    }
}
Test-Case 'Foreign pagination origin rejected before following it' {
    $script:permissionNext = 'https://evil.example/permissions'
    Assert-Throws { Invoke-TestEnrollment } '*Graph*URL*'; Assert-NoWrites
    Assert-Test (@($script:calls | Where-Object Uri -like '*evil*').Count -eq 0) 'Untrusted URL requested'
}
Test-Case 'Pagination cycle bounded' {
    $script:permissionNext = 'https://graph.microsoft.com/v1.0/sites/' + [Uri]::EscapeDataString($script:site.id) + '/permissions'
    Assert-Throws { Invoke-TestEnrollment } '*pagination*'; Assert-NoWrites
}
Test-Case 'Concurrent application edit detected before PATCH' {
    $script:concurrentApp = $true
    Assert-Throws { Invoke-TestEnrollment } '*changed*'; Assert-NoWrites
}
Test-Case 'Lost old key detected after PATCH; no later grants' {
    $script:app.keyCredentials = @(Copy-TestValue $script:otherKey); $script:dropKeyAfterWrite = $true
    Assert-Throws { Invoke-TestEnrollment } '*verification*'
    Assert-Test (@($script:calls | Where-Object Method -eq POST).Count -eq 0) 'Continued after failed verification'
}
Test-Case 'Concurrent site grant detected before POST instead of duplicating' {
    $script:concurrentPermission = $true
    Assert-Throws { Invoke-TestEnrollment } '*changed*'
    Assert-Test (@($script:calls | Where-Object { $_.Method -eq 'POST' -and $_.Uri -like '*/permissions' }).Count -eq 0) 'Duplicate site grant'
}
Test-Case 'Conditional update failure and cancelled sign-in both clean up' {
    $script:patchFails = $true; Assert-Throws { Invoke-TestEnrollment } '*conditional*'
    Assert-Test ($script:disconnects -ge 1) 'PATCH failure leaked admin context'
    Reset-TestState; $script:connectFails = $true; Assert-Throws { Invoke-TestEnrollment } '*cancelled*'
    Assert-Test ($script:disconnects -ge 1) 'Sign-in cancellation skipped cleanup'; Assert-NoWrites
}
Test-Case 'Invalid certificate fails before interactive login' {
    $script:certificate.HasPrivateKey = $false
    Assert-Throws { Invoke-TestEnrollment } '*certificate*'
    Assert-Test ($null -eq $script:connect) 'Signed in before local validation'
}
Test-Case 'No ETag warns about concurrent enrollment' {
    $warnings = @()
    Register-CompanyBackupCredential @script:inputs -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null
    Assert-Test (($warnings -join ' ') -like '*concurrent*') 'Missing concurrency warning'
}
Write-Host "Enrollment tests: $script:passed passed; $script:failed failed. PowerShell $($PSVersionTable.PSVersion). No live tenant calls."
if ($script:failed) { throw 'Enrollment tests failed.' }
