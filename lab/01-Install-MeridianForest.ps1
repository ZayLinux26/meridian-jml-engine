#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Promotes MFG-DC01 to the first domain controller of meridianfg.internal.
.DESCRIPTION
    Run once on the VM in an elevated Windows PowerShell or PowerShell 7 window.
    The server reboots when promotion finishes. Sign back in as
    MERIDIAN\mfgadmin (same password as the local admin).

    .internal is the ICANN-reserved TLD for private networks (2024), so the lab
    avoids both .local (mDNS clashes) and a public domain you do not own.
#>
[CmdletBinding()]
param(
    [string]$DomainName = 'meridianfg.internal',
    [string]$NetbiosName = 'MERIDIAN'
)
$ErrorActionPreference = 'Stop'

Write-Host "Installing AD DS and DNS roles..." -ForegroundColor Cyan
Install-WindowsFeature -Name AD-Domain-Services, DNS -IncludeManagementTools | Format-Table -AutoSize

$dsrm = Read-Host -AsSecureString 'Directory Services Restore Mode (DSRM) password'

Write-Host "Promoting to a new forest: $DomainName ($NetbiosName)" -ForegroundColor Cyan
Import-Module ADDSDeployment
Install-ADDSForest `
    -DomainName $DomainName `
    -DomainNetbiosName $NetbiosName `
    -ForestMode WinThreshold `
    -DomainMode WinThreshold `
    -InstallDns `
    -SafeModeAdministratorPassword $dsrm `
    -NoRebootOnCompletion:$false `
    -Force
