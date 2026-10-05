#Requires -Version 7.2
#Requires -Modules ActiveDirectory
<#
.SYNOPSIS
    Builds the Meridian Financial Group OU tree, UPN suffix and birthright groups.
.DESCRIPTION
    Idempotent: safe to run again, it only creates what is missing.

      OU=Meridian
        OU=Users
          OU=Finance | Technology | Operations | HR | Compliance
        OU=Disabled Users
        OU=Groups
        OU=Service Accounts

    Groups follow AGDLP. The engine puts users into GG-* (global) groups only.
    Resource permissions hang off DL-* (domain local) groups that nest the GG-*
    groups, so file shares and apps never reference users directly.
.PARAMETER UpnSuffix
    Your Entra tenant domain, for example contoso.onmicrosoft.com. Synced users
    need a UPN suffix that is verified in the tenant.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$UpnSuffix,
    [string]$AccessModelPath = (Join-Path $PSScriptRoot '..\config\access-model.json')
)
$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory

$domainDn = (Get-ADDomain).DistinguishedName
$root = "OU=Meridian,$domainDn"

function New-OuIfMissing {
    param([string]$Name, [string]$Path)
    $dn = "OU=$Name,$Path"
    if (-not (Get-ADOrganizationalUnit -LDAPFilter "(distinguishedName=$dn)" -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name $Name -Path $Path -ProtectedFromAccidentalDeletion $true
        Write-Host "  + OU  $dn" -ForegroundColor Green
    }
    else { Write-Host "  = OU  $dn" -ForegroundColor DarkGray }
}

function New-GroupIfMissing {
    param([string]$Name, [ValidateSet('Global', 'DomainLocal')][string]$Scope, [string]$Description)
    if (-not (Get-ADGroup -Filter "Name -eq '$Name'" -ErrorAction SilentlyContinue)) {
        New-ADGroup -Name $Name -SamAccountName $Name -GroupScope $Scope -GroupCategory Security -Path "OU=Groups,$root" -Description $Description
        Write-Host "  + GRP $Name ($Scope)" -ForegroundColor Green
    }
    else { Write-Host "  = GRP $Name" -ForegroundColor DarkGray }
}

Write-Host "`nDNS forwarder on the domain controller (Azure recursive resolver)" -ForegroundColor Cyan
# Runs from the management server, so target the DC explicitly.
$dc = (Get-ADDomainController -Discover -Service PrimaryDC).HostName | Select-Object -First 1
if (Get-Command Get-DnsServerForwarder -ErrorAction SilentlyContinue) {
    $fwd = @((Get-DnsServerForwarder -ComputerName $dc).IPAddress | ForEach-Object { $_.IPAddressToString })
    if ($fwd -notcontains '168.63.129.16') { Add-DnsServerForwarder -ComputerName $dc -IPAddress 168.63.129.16; Write-Host "  + 168.63.129.16 on $dc" -ForegroundColor Green }
    else { Write-Host "  = 168.63.129.16 on $dc" -ForegroundColor DarkGray }
}
else { Write-Host '  skipped (DNS tools not installed; run Install-WindowsFeature RSAT-DNS-Server to manage it from here)' -ForegroundColor DarkYellow }

Write-Host "`nUPN suffix" -ForegroundColor Cyan
$forest = Get-ADForest
if ($forest.UPNSuffixes -notcontains $UpnSuffix) {
    Set-ADForest -Identity $forest -UPNSuffixes @{ Add = $UpnSuffix }
    Write-Host "  + $UpnSuffix" -ForegroundColor Green
}
else { Write-Host "  = $UpnSuffix" -ForegroundColor DarkGray }

Write-Host "`nOrganizational units" -ForegroundColor Cyan
New-OuIfMissing -Name 'Meridian' -Path $domainDn
foreach ($ou in @('Users', 'Disabled Users', 'Groups', 'Service Accounts')) { New-OuIfMissing -Name $ou -Path $root }

$am = Get-Content -LiteralPath $AccessModelPath -Raw | ConvertFrom-Json -AsHashtable
foreach ($dept in $am.Department.Keys) { New-OuIfMissing -Name $dept -Path "OU=Users,$root" }

Write-Host "`nBirthright groups (from access model)" -ForegroundColor Cyan
$layers = @($am.Global) + @($am.EmploymentType.Values) + @($am.Department.Values) + @($am.JobTitle.Values)
$ggs = @($layers | ForEach-Object { $_.AD } | Where-Object { $_ } | Sort-Object -Unique)
foreach ($g in $ggs) { New-GroupIfMissing -Name $g -Scope Global -Description 'JML engine managed birthright group' }

Write-Host "`nResource groups (AGDLP nesting)" -ForegroundColor Cyan
$dl = [ordered]@{
    'DL-MFG-FS-Finance-RW'         = 'GG-MFG-Finance'
    'DL-MFG-FS-IT-RW'              = 'GG-MFG-Technology'
    'DL-MFG-FS-Operations-RW'      = 'GG-MFG-Operations'
    'DL-MFG-FS-HR-Confidential-RW' = 'GG-MFG-HR'
    'DL-MFG-FS-Compliance-RW'      = 'GG-MFG-Compliance'
    'DL-MFG-App-SWIFT-Release'     = 'GG-MFG-Treasury-WireRelease'
    'DL-MFG-App-Actimize-Cases'    = 'GG-MFG-AML-CaseMgmt'
}
foreach ($name in $dl.Keys) {
    New-GroupIfMissing -Name $name -Scope DomainLocal -Description "Resource permission group, nests $($dl[$name])"
    $members = @(Get-ADGroupMember -Identity $name | ForEach-Object SamAccountName)
    if ($members -notcontains $dl[$name]) { Add-ADGroupMember -Identity $name -Members $dl[$name]; Write-Host "      nest $($dl[$name]) -> $name" -ForegroundColor Green }
}

Write-Host "`nJML operators group (delegation target)" -ForegroundColor Cyan
New-GroupIfMissing -Name 'GG-MFG-JML-Operators' -Scope Global -Description 'Accounts allowed to run the JML engine. Delegated rights on OU=Meridian only.'

Write-Host "`nDone. Open Active Directory Users and Computers to review OU=Meridian." -ForegroundColor Cyan
