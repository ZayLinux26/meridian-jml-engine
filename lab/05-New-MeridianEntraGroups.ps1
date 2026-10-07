#Requires -Version 7.2
<#
.SYNOPSIS
    Creates the cloud-only Entra security groups named in the access model.
.DESCRIPTION
    Idempotent. Uses a delegated admin sign-in (browser) because the JML
    app is deliberately not allowed to create groups.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TenantId,
    [string]$AccessModelPath = (Join-Path $PSScriptRoot '..\config\access-model.json')
)
$ErrorActionPreference = 'Stop'
Import-Module Microsoft.Graph.Authentication
Connect-MgGraph -TenantId $TenantId -Scopes 'Group.ReadWrite.All' -NoWelcome

$am = Get-Content -LiteralPath $AccessModelPath -Raw | ConvertFrom-Json -AsHashtable
$layers = @($am.Global) + @($am.EmploymentType.Values) + @($am.Department.Values) + @($am.JobTitle.Values)
$names = @($layers | ForEach-Object { $_.Entra } | Where-Object { $_ } | Sort-Object -Unique)

foreach ($n in $names) {
    $hit = (Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$n'&`$select=id").value
    if ($hit) { Write-Host "  = $n" -ForegroundColor DarkGray; continue }
    $body = @{
        displayName     = $n
        description     = 'Meridian birthright group. Membership managed by the JML engine; do not edit by hand.'
        mailEnabled     = $false
        mailNickname    = ($n -replace '[^A-Za-z0-9]', '').ToLower()
        securityEnabled = $true
    } | ConvertTo-Json
    $g = Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/groups' -Body $body -ContentType 'application/json'
    Write-Host "  + $n ($($g.id))" -ForegroundColor Green
}
Disconnect-MgGraph | Out-Null
