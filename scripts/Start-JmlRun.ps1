#Requires -Version 7.2
<#
.SYNOPSIS
    Unattended entry point for a scheduler (Task Scheduler, Azure Automation
    Hybrid Worker, a pipeline agent). Maps run outcomes to exit codes so the
    scheduler and the SOC alerting can tell them apart.

    0  success
    1  one or more identities rolled back, or cleanup pending (retry next run)
    2  safety limit tripped, nothing changed (a human must check the feed)
    3  leaver containment failed (page the on-call)
    4  engine error before or during planning
.EXAMPLE
    pwsh -File scripts/Start-JmlRun.ps1 -FeedPath \\hr-sftp\exports\workers.csv -Apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$FeedPath,
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\jml.config.psd1'),
    [switch]$Apply
)
Import-Module (Join-Path $PSScriptRoot '..\src\MeridianJML\MeridianJML.psd1') -Force
try {
    $r = Invoke-JmlRun -ConfigPath $ConfigPath -FeedPath $FeedPath -Apply:$Apply -PassThru
}
catch {
    Write-Error $_
    if ($_.Exception.Message -like 'SAFETY LIMIT*') { exit 2 }
    exit 4
}
if (@($r.Items | Where-Object Result -eq 'ContainmentFailed').Count) { exit 3 }
if (@($r.Items | Where-Object { $_.Result -in @('RolledBack', 'RollbackFailed', 'Contained') -or $_.Operation -eq 'PlanError' }).Count) { exit 1 }
exit 0
