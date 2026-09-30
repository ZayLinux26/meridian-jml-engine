function Show-JmlRun {
    <#
    .SYNOPSIS
        Prints the audit trail for a run from its journal.
    .EXAMPLE
        Show-JmlRun -ConfigPath ./config/jml.config.psd1 -RunId 20261002-091500-a1b2c3 -EmployeeId 100008
    .EXAMPLE
        Show-JmlRun -ConfigPath ./config/jml.config.psd1 -List
    #>
    [CmdletBinding(DefaultParameterSetName = 'One')]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory, ParameterSetName = 'One')][string]$RunId,
        [Parameter(ParameterSetName = 'One')][string[]]$EmployeeId,
        [Parameter(Mandatory, ParameterSetName = 'List')][switch]$List
    )
    $cfg = (Import-JmlConfig -Path $ConfigPath).Config
    $dir = $cfg.Paths.Journal

    if ($List) {
        Get-ChildItem -LiteralPath $dir -Filter '*.json' | Sort-Object LastWriteTime | ForEach-Object {
            $j = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -AsHashtable
            [pscustomobject]@{
                RunId    = $j.RunId
                Mode     = $j.Mode
                Status   = $j['Status']
                Provider = $j.Provider
                Operator = $j.Operator
                Finished = $j.CompletedAt
                Feed     = if ($j['Feed']) { Split-Path -Leaf $j.Feed.Path } else { "rollback of $($j['RollbackOf'])" }
            }
        }
        return
    }

    $path = Join-Path -Path $dir -ChildPath "$RunId.json"
    if (-not (Test-Path -LiteralPath $path)) { throw "Journal not found: $path" }
    $j = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
    Write-Host ''
    Write-Host "  Run $($j.RunId)   Mode: $($j.Mode)   Status: $($j['Status'])   Operator: $($j.Operator)" -ForegroundColor White
    if ($j['Feed']) { Write-Host "  Feed: $(Split-Path -Leaf $j.Feed.Path)   SHA256: $($j.Feed.Sha256)" -ForegroundColor Gray }
    if ($j['FaultInjection']) { Write-Host "  Fault injection: $($j.FaultInjection.Key) $($j.FaultInjection.EmployeeId)" -ForegroundColor DarkYellow }
    foreach ($i in @($j.Items | Where-Object { (-not $EmployeeId -or $_.EmployeeId -in $EmployeeId) -and @($_.Actions).Count })) {
        Write-Host ''
        Write-Host "  $($i.EmployeeId)  $($i.DisplayName)  Operation: $($i.Operation)  Result: $($i.Result)" -ForegroundColor Cyan
        foreach ($a in $i.Actions) {
            $c = switch ($a.Status) { 'Succeeded' { 'Green' } 'Failed' { 'Red' } 'Compensated' { 'Yellow' } default { 'DarkGray' } }
            $t = if ($a.StartedAt) { ([datetime]$a.StartedAt).ToUniversalTime().ToString('HH:mm:ss.fff') + 'Z' } else { '-------------' }
            $crit = if ($a.Critical) { '*' } else { ' ' }
            Write-Host ("    {0} {1:00}{2} {3,-12} {4,-24} {5}" -f $t, [int]$a.Seq, $crit, $a.Status, "$($a.System).$($a.Type)", $a.Description) -ForegroundColor $c
            if ($a.Error) { Write-Host "                   -> $($a.Error)" -ForegroundColor Red }
        }
        foreach ($n in @($i.Notes)) { Write-Host "    note: $n" -ForegroundColor DarkYellow }
    }
    Write-Host ''
}
