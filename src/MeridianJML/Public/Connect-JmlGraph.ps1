function Connect-JmlGraph {
    <#
    .SYNOPSIS
        Connects to Microsoft Graph as the JML app registration (app-only,
        certificate credential). No client secrets, no delegated admin session.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfigPath)
    $cfg = (Import-JmlConfig -Path $ConfigPath).Config
    foreach ($k in @('TenantId', 'ClientId', 'CertificateThumbprint')) {
        if ([string]::IsNullOrWhiteSpace($cfg.Graph[$k]) -or $cfg.Graph[$k] -like 'CHANGEME*') { throw "Config Graph.$k is not set. Run lab/04-New-JmlAppRegistration.ps1 and paste its output into the config." }
    }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop -Verbose:$false
    Connect-MgGraph -TenantId $cfg.Graph.TenantId -ClientId $cfg.Graph.ClientId -CertificateThumbprint $cfg.Graph.CertificateThumbprint -NoWelcome -ErrorAction Stop
    $ctx = Get-MgContext
    if ($ctx.AuthType -ne 'AppOnly') { throw "Expected an app-only Graph session, got '$($ctx.AuthType)'." }
    return $ctx
}
