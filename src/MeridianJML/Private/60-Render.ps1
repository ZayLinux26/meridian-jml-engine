# Console rendering. Kept separate so the engine stays quiet under -Quiet and in tests.

$script:JmlOpColor = @{
    Joiner = 'Green'; Mover = 'Cyan'; Leaver = 'Magenta'; Rehire = 'Yellow'; Reconcile = 'Blue'
    NoChange = 'DarkGray'; Deferred = 'DarkYellow'; PendingSync = 'DarkCyan'; PlanError = 'Red'
}
$script:JmlResultColor = @{
    Completed = 'Green'; NoAction = 'DarkGray'; NotRun = 'DarkGray'; RolledBack = 'Yellow'; RollbackFailed = 'Red'
    Contained = 'Yellow'; ContainmentFailed = 'Red'; Skipped = 'DarkGray'
}

function Write-JmlBanner {
    param([string]$Title, [string[]]$Lines)
    if ($script:Jml.Quiet) { return }
    $bar = '=' * 96
    Write-Host ''
    Write-Host $bar -ForegroundColor DarkCyan
    Write-Host "  $Title" -ForegroundColor White
    foreach ($l in $Lines) { Write-Host "  $l" -ForegroundColor Gray }
    Write-Host $bar -ForegroundColor DarkCyan
}

function Write-JmlItemTable {
    param([object[]]$Items, [switch]$ShowResult)
    if ($script:Jml.Quiet) { return }
    $fmt = '  {0,-8} {1,-18} {2,-14} {3,-9} {4,-11} {5,7}  {6}'
    Write-Host ''
    Write-Host ($fmt -f 'EmpId', 'Name', 'Account', 'Type', 'Operation', 'Actions', $(if ($ShowResult) { 'Result' } else { '' })) -ForegroundColor White
    Write-Host ($fmt -f '-----', '----', '-------', '----', '---------', '-------', $(if ($ShowResult) { '------' } else { '' })) -ForegroundColor DarkGray
    foreach ($i in $Items) {
        $name = if ($i.DisplayName.Length -gt 18) { $i.DisplayName.Substring(0, 17) + '.' } else { $i.DisplayName }
        $acct = [string]$i.Account; if ($acct.Length -gt 14) { $acct = ($acct -split '@')[0] }; if ($acct.Length -gt 14) { $acct = $acct.Substring(0, 13) + '.' }
        $color = if ($ShowResult -and $script:JmlResultColor.ContainsKey($i.Result)) { $script:JmlResultColor[$i.Result] } else { $script:JmlOpColor[$i.Operation] }
        if (-not $color) { $color = 'Gray' }
        Write-Host ($fmt -f $i.EmployeeId, $name, $acct, $i.IdentityType, $i.Operation, $i.Actions.Count, $(if ($ShowResult) { $i.Result } else { '' })) -ForegroundColor $color
    }
}

function Write-JmlActionDetail {
    param([object[]]$Items, [switch]$ShowStatus)
    if ($script:Jml.Quiet) { return }
    foreach ($i in ($Items | Where-Object { $_.Actions.Count -gt 0 -or $_.Notes.Count -gt 0 })) {
        Write-Host ''
        $opColor = $script:JmlOpColor[$i.Operation]; if (-not $opColor) { $opColor = 'Gray' }
        Write-Host ("  {0}  {1}  [{2}]" -f $i.EmployeeId, $i.DisplayName, $i.Operation) -ForegroundColor $opColor
        foreach ($a in $i.Actions) {
            $crit = if ($a.Critical) { '*' } else { ' ' }
            $status = if ($ShowStatus) { '{0,-18}' -f $a.Status } else { '' }
            $c = switch ($a.Status) { 'Succeeded' { 'Green' } 'Failed' { 'Red' } 'Compensated' { 'Yellow' } 'NotStarted' { 'DarkGray' } 'CompensationFailed' { 'Red' } default { 'Gray' } }
            Write-Host ("    {0:00}{1} {2}[{3,-5}] {4,-17} {5}" -f $a.Seq, $crit, $status, $a.System, $a.Type, $a.Description) -ForegroundColor $c
            if ($ShowStatus -and $a.Error) { Write-Host "        -> $($a.Error)" -ForegroundColor Red }
        }
        foreach ($n in $i.Notes) { Write-Host "    note: $n" -ForegroundColor DarkYellow }
    }
}

function Get-JmlCounts {
    param([object[]]$Items, [string]$Property)
    $h = [ordered]@{}
    foreach ($g in ($Items | Group-Object -Property $Property | Sort-Object Name)) { $h[$g.Name] = $g.Count }
    return $h
}
