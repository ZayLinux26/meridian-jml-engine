#Requires -Version 7.2
<#
.SYNOPSIS
    Creates the MFG-JML-Engine app registration with a certificate credential
    and grants admin consent for exactly two Microsoft Graph application
    permissions.
.DESCRIPTION
    Permissions and why:
      User.ReadWrite.All         read users, create/update cloud-only contractors,
                                 set managers, revoke sign-in sessions
      GroupMember.ReadWrite.All  add/remove members of the Entra birthright groups

    No Directory.ReadWrite.All, no RoleManagement, no client secret. The
    private key is created non-exportable in the current user's certificate
    store on this server, so the credential cannot be copied off the box.

    Sign-in uses device code: open the URL it prints on your Mac, enter the
    code, and sign in as a Global Administrator (or Privileged Role
    Administrator + Application Administrator).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TenantId,
    [string]$AppName = 'MFG-JML-Engine',
    [int]$CertValidityMonths = 12
)
$ErrorActionPreference = 'Stop'
if (-not (Get-Module -ListAvailable Microsoft.Graph.Authentication)) {
    Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force
}
Import-Module Microsoft.Graph.Authentication

Connect-MgGraph -TenantId $TenantId -Scopes 'Application.ReadWrite.All', 'AppRoleAssignment.ReadWrite.All' -UseDeviceCode -NoWelcome
$graphAppId = '00000003-0000-0000-c000-000000000000'
$wanted = @('User.ReadWrite.All', 'GroupMember.ReadWrite.All')

# 1. Certificate (non-exportable private key)
Write-Host "Creating certificate CN=$AppName ..." -ForegroundColor Cyan
$cert = New-SelfSignedCertificate -Subject "CN=$AppName" -CertStoreLocation 'Cert:\CurrentUser\My' `
    -KeyExportPolicy NonExportable -KeySpec Signature -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 `
    -NotAfter (Get-Date).AddMonths($CertValidityMonths)

# 2. Resolve Graph app role ids
$graphSp = (Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$graphAppId'&`$select=id,appRoles").value[0]
$roles = @(foreach ($w in $wanted) {
        $r = $graphSp.appRoles | Where-Object { $_.value -eq $w -and $_.allowedMemberTypes -contains 'Application' }
        if (-not $r) { throw "Graph app role $w not found" }
        [pscustomobject]@{ Name = $w; Id = $r.id }
    })

# 3. App registration (reuse if it already exists)
$existing = (Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=displayName eq '$AppName'&`$select=id,appId,keyCredentials").value
$keyCred = @{
    type        = 'AsymmetricX509Cert'
    usage       = 'Verify'
    key         = [Convert]::ToBase64String($cert.RawData)
    displayName = "CN=$AppName $(Get-Date -Format yyyy-MM-dd)"
}
$rra = @(@{ resourceAppId = $graphAppId; resourceAccess = @($roles | ForEach-Object { @{ id = $_.Id; type = 'Role' } }) })

if ($existing) {
    $app = $existing[0]
    # Graph never returns existing private-key material, so a PATCH replaces the
    # credential set. Re-running this script therefore rotates the certificate.
    Write-Host "App $AppName exists ($($app.appId)); rotating to the new certificate." -ForegroundColor Yellow
    Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/v1.0/applications/$($app.id)" -Body (@{ keyCredentials = @($keyCred); requiredResourceAccess = $rra } | ConvertTo-Json -Depth 6) -ContentType 'application/json'
}
else {
    Write-Host "Creating app registration $AppName ..." -ForegroundColor Cyan
    $body = @{
        displayName            = $AppName
        signInAudience         = 'AzureADMyOrg'
        notes                  = 'Meridian JML lifecycle engine. App-only, certificate credential. Owner: IAM Engineering.'
        keyCredentials         = @($keyCred)
        requiredResourceAccess = $rra
    }
    $app = Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/applications' -Body ($body | ConvertTo-Json -Depth 6) -ContentType 'application/json'
}

# 4. Service principal
$sp = (Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$($app.appId)'").value | Select-Object -First 1
if (-not $sp) {
    Start-Sleep -Seconds 5
    $sp = Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/servicePrincipals' -Body (@{ appId = $app.appId } | ConvertTo-Json) -ContentType 'application/json'
}

# 5. Admin consent = app role assignments on the Graph service principal
$assigned = @((Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($sp.id)/appRoleAssignments").value | ForEach-Object { $_.appRoleId })
foreach ($r in $roles) {
    if ($r.Id -in $assigned) { Write-Host "  = $($r.Name) already consented" -ForegroundColor DarkGray; continue }
    $b = @{ principalId = $sp.id; resourceId = $graphSp.id; appRoleId = $r.Id } | ConvertTo-Json
    [void](Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($graphSp.id)/appRoleAssignedTo" -Body $b -ContentType 'application/json')
    Write-Host "  + $($r.Name) consented" -ForegroundColor Green
}

Disconnect-MgGraph | Out-Null
Write-Host "`nPaste this into config\jml.config.psd1 (Graph section):" -ForegroundColor Cyan
Write-Host "        TenantId              = '$TenantId'"
Write-Host "        ClientId              = '$($app.appId)'"
Write-Host "        CertificateThumbprint = '$($cert.Thumbprint)'"
