[CmdletBinding()]
param(
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
$tenantId = 'a2f1a70f-1bf7-48c7-9b0f-c0d3f912a76e'
$appId = '14d82eec-204b-4c2f-b7e8-296a70dab67e' # Microsoft Graph Command Line Tools
$graphAppId = '00000003-0000-0000-c000-000000000000'
$targetUpn = 'archive@warramali.au'
$requiredScopes = @('Sites.Read.All', 'Files.ReadWrite.All')

function Get-GraphCollection {
    param([string]$Uri)
    $items = @()
    while ($Uri) {
        $parsed = [Uri]$Uri
        if ($parsed.Scheme -ne 'https' -or $parsed.Host -ne 'graph.microsoft.com' -or
            -not $parsed.AbsolutePath.StartsWith('/v1.0/', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Refusing unexpected Graph nextLink.'
        }
        $page = Invoke-MgGraphRequest -Method GET -Uri $Uri -OutputType PSObject -ErrorAction Stop
        $items += @($page.value)
        $Uri = [string]$page.'@odata.nextLink'
    }
    return $items
}

function Get-OneServicePrincipal {
    param([string]$ApplicationId)
    $filter = [Uri]::EscapeDataString("appId eq '$ApplicationId'")
    $uri = 'https://graph.microsoft.com/v1.0/servicePrincipals?$filter={0}&$select=id,appId,displayName,oauth2PermissionScopes' -f $filter
    $matches = @(Get-GraphCollection -Uri $uri)
    if ($matches.Count -ne 1 -or [string]$matches[0].appId -ine $ApplicationId) {
        throw "Expected one service principal for $ApplicationId; found $($matches.Count)."
    }
    return $matches[0]
}

Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
Connect-MgGraph -TenantId $tenantId -Scopes @('Directory.Read.All') -ContextScope Process -UseDeviceAuthentication -NoWelcome -ErrorAction Stop | Out-Null
$context = Get-MgContext
if ($null -eq $context -or $context.TenantId -ine $tenantId -or $context.ClientId -ine $appId) {
    throw 'Signed-in tenant or Microsoft Graph Command Line Tools app does not match the expected target.'
}
if ($context.Account -ieq $targetUpn) { throw 'Sign in with the Duy administrator account, not the archive target account.' }

$client = Get-OneServicePrincipal -ApplicationId $appId
$resource = Get-OneServicePrincipal -ApplicationId $graphAppId
$userUri = 'https://graph.microsoft.com/v1.0/users/{0}?$select=id,userPrincipalName,mail,displayName' -f [Uri]::EscapeDataString($targetUpn)
$user = Invoke-MgGraphRequest -Method GET -Uri $userUri -OutputType PSObject -ErrorAction Stop
if (-not $user.id -or ($user.userPrincipalName -ine $targetUpn -and $user.mail -ine $targetUpn)) {
    throw "The resolved user is not $targetUpn. No consent was changed."
}
foreach ($scope in $requiredScopes) {
    $definition = @($resource.oauth2PermissionScopes | Where-Object { $_.value -eq $scope -and $_.isEnabled })
    if ($definition.Count -ne 1) { throw "Graph does not publish the expected delegated scope $scope." }
}

$filter = [Uri]::EscapeDataString("clientId eq '$($client.id)'")
$grantsUri = 'https://graph.microsoft.com/v1.0/oauth2PermissionGrants?$filter={0}' -f $filter
$grants = @(Get-GraphCollection -Uri $grantsUri | Where-Object { $_.resourceId -eq $resource.id })
$personal = @($grants | Where-Object { $_.consentType -eq 'Principal' -and $_.principalId -eq $user.id })
if ($personal.Count -gt 1) { throw 'Multiple personal grants found; stop for manual review.' }
$orgScopes = @($grants | Where-Object { $_.consentType -eq 'AllPrincipals' } | ForEach-Object { @([string]$_.scope -split '\s+' | Where-Object { $_ }) })
$personalScopes = if ($personal.Count -eq 1) { @([string]$personal[0].scope -split '\s+' | Where-Object { $_ }) } else { @() }
$missing = @($requiredScopes | Where-Object { $_ -notin $orgScopes -and $_ -notin $personalScopes })

Write-Host "Administrator: $($context.Account)"
Write-Host "Tenant: $($context.TenantId)"
Write-Host "Client app: $($client.displayName) ($($client.appId))"
Write-Host "Client service-principal object: $($client.id)"
Write-Host "Target user: $($user.userPrincipalName) ($($user.id))"
Write-Host "Already granted for target: $(($requiredScopes | Where-Object { $_ -notin $missing }) -join ', ')"
Write-Host "Missing for target: $($missing -join ', ')"
if ($missing.Count -eq 0) { Write-Host 'No change is needed. If sign-in still fails, inspect the Entra sign-in log for the exact reason.'; return }

$newPersonalScopes = @(($personalScopes + $missing) | Sort-Object -Unique)
$operation = if ($personal.Count -eq 1) { 'PATCH existing personal grant' } else { 'POST new personal grant' }
Write-Host "Proposed action: $operation; consentType=Principal; scopes=$(($newPersonalScopes) -join ' ')"
if (-not $Apply) { Write-Host 'DRY RUN ONLY. Rerun with -Apply after verifying every ID and scope above.'; return }

$expectedConfirmation = "GRANT $targetUpn"
Write-Warning 'Applying requires the high-privilege DelegatedPermissionGrant.ReadWrite.All scope for the ADMIN session. Review any new consent prompt carefully; do not grant it tenant-wide just to run this helper.'
$confirmation = Read-Host "Type '$expectedConfirmation' to apply this per-user grant"
if ($confirmation -cne $expectedConfirmation) { throw 'Confirmation did not match; no consent was changed.' }

Disconnect-MgGraph | Out-Null
Connect-MgGraph -TenantId $tenantId -Scopes @('Directory.Read.All', 'DelegatedPermissionGrant.ReadWrite.All') -ContextScope Process -UseDeviceAuthentication -NoWelcome -ErrorAction Stop | Out-Null
$writeContext = Get-MgContext
if ($null -eq $writeContext -or $writeContext.TenantId -ine $tenantId -or
    $writeContext.ClientId -ine $appId -or $writeContext.Account -ine $context.Account -or
    'DelegatedPermissionGrant.ReadWrite.All' -notin @($writeContext.Scopes)) {
    throw 'The administrator session changed or lacks the grant-management scope. No consent was changed.'
}
$currentGrants = @(Get-GraphCollection -Uri $grantsUri | Where-Object { $_.resourceId -eq $resource.id -and $_.consentType -eq 'Principal' -and $_.principalId -eq $user.id })
if ($currentGrants.Count -ne $personal.Count -or
    ($personal.Count -eq 1 -and ($currentGrants[0].id -ne $personal[0].id -or $currentGrants[0].scope -ne $personal[0].scope))) {
    throw 'The target user grant changed after preview. Rerun the dry run before applying.'
}

if ($personal.Count -eq 1) {
    $uri = 'https://graph.microsoft.com/v1.0/oauth2PermissionGrants/{0}' -f [Uri]::EscapeDataString([string]$personal[0].id)
    $body = @{ scope = ($newPersonalScopes -join ' ') } | ConvertTo-Json -Compress
    Invoke-MgGraphRequest -Method PATCH -Uri $uri -Body $body -ContentType 'application/json' -ErrorAction Stop | Out-Null
}
else {
    $body = @{
        clientId = [string]$client.id
        resourceId = [string]$resource.id
        consentType = 'Principal'
        principalId = [string]$user.id
        scope = ($newPersonalScopes -join ' ')
    } | ConvertTo-Json -Compress
    Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/oauth2PermissionGrants' -Body $body -ContentType 'application/json' -ErrorAction Stop | Out-Null
}
Write-Host 'Per-user delegated consent applied. Reconnect on the other machine as archive@warramali.au; do not use the admin account for cloud backup.'
