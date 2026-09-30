#Requires -Version 7.2
#Requires -Modules ActiveDirectory
<#
.SYNOPSIS
    Delegates the exact AD rights the JML engine needs to GG-MFG-JML-Operators,
    scoped to OU=Meridian. Nothing at the domain root, no Domain Admins.
.DESCRIPTION
    In the lab you can run the engine as your domain admin, but a real
    deployment runs it under a gMSA or a dedicated service identity that is a
    member of GG-MFG-JML-Operators. These ACEs are all it gets:

      OU=Users, OU=Disabled Users   Create / delete user objects (joiners, moves, joiner rollback)
      user objects under Meridian   Read / write properties, Reset Password
      group objects under Groups    Write the member attribute only

    Run -WhatIf first to print the dsacls commands without applying them.
#>
[CmdletBinding(SupportsShouldProcess)]
param([string]$OperatorsGroup = 'GG-MFG-JML-Operators')
$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory

$domain = Get-ADDomain
$root = "OU=Meridian,$($domain.DistinguishedName)"
$principal = "$($domain.NetBIOSName)\$OperatorsGroup"

$grants = @(
    @{ Target = "OU=Users,$root"; Args = @('/I:T', '/G', "${principal}:CCDC;user") }
    @{ Target = "OU=Disabled Users,$root"; Args = @('/I:T', '/G', "${principal}:CCDC;user") }
    @{ Target = $root; Args = @('/I:S', '/G', "${principal}:RPWP;;user") }
    @{ Target = $root; Args = @('/I:S', '/G', "${principal}:CA;Reset Password;user") }
    @{ Target = "OU=Groups,$root"; Args = @('/I:S', '/G', "${principal}:RPWP;member;group") }
)

foreach ($g in $grants) {
    $display = "dsacls `"$($g.Target)`" $($g.Args -join ' ')"
    if ($PSCmdlet.ShouldProcess($g.Target, $display)) {
        & dsacls.exe $g.Target @($g.Args) | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "dsacls failed: $display" }
        Write-Host "  granted  $display" -ForegroundColor Green
    }
}
Write-Host "`nReview: ADUC > View > Advanced Features > OU=Meridian > Properties > Security > Advanced." -ForegroundColor Cyan
