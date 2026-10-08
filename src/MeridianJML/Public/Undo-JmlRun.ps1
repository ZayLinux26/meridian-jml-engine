function Undo-JmlRun {
    <#
    .SYNOPSIS
        Reverses the recorded changes of an applied run, from its journal.
    .DESCRIPTION
        Break-glass tool for a bad run, such as HR terminating the wrong person.
        It replays each succeeded action's recorded before-state in reverse
        order. Irreversible actions (session revocation, password randomisation)
        are listed so the operator knows what still needs a human, for example
        issuing a Temporary Access Pass.

        The HR feed stays the source of truth. If the feed still says
        Terminated, the next scheduled run terminates the worker again. Fix the
        HR record first, or the engine will (correctly) converge back.
    .EXAMPLE
        Undo-JmlRun -ConfigPath ./config/jml.config.psd1 -RunId 20261002-091500-a1b2c3 -EmployeeId 100008 -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$RunId,
        [string[]]$EmployeeId,
        [switch]$Simulated,
        [string]$SimulationStatePath,
        [switch]$Force
    )
    $loaded = Import-JmlConfig -Path $ConfigPath
    $provider = if ($Simulated) { 'Simulated' } else { 'Live' }
    Initialize-JmlContext -Config $loaded.Config -AccessModel $loaded.AccessModel -Provider $provider
    $cfg = $script:Jml.Config

    $journalPath = Join-Path -Path $cfg.Paths.Journal -ChildPath "$RunId.json"
    if (-not (Test-Path -LiteralPath $journalPath)) { throw "Journal not found for run $RunId ($journalPath)." }
    $source = Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json -AsHashtable
    if ($source.Mode -ne 'Apply') { throw "Run $RunId was a $($source.Mode) run. Only applied runs can be undone." }
    $marker = Join-Path -Path $cfg.Paths.Journal -ChildPath "$RunId.undone"
    if ((Test-Path -LiteralPath $marker) -and -not $Force) { throw "Run $RunId has already been undone (see $marker). Use -Force to replay again." }

    if ($Simulated) {
        if (-not $SimulationStatePath) { $SimulationStatePath = Join-Path -Path $cfg.Paths.Simulation -ChildPath 'sim-state.json' }
        $script:Jml.SimStatePath = [System.IO.Path]::GetFullPath($SimulationStatePath)
        $script:Jml.SimState = Import-JmlSimulatedState -Path $script:Jml.SimStatePath -AccessModel $script:Jml.AccessModel
    }
    else {
        Import-Module ActiveDirectory -ErrorAction Stop -Verbose:$false
        if (-not (Get-Command Get-MgContext -ErrorAction SilentlyContinue) -or -not (Get-MgContext)) { [void](Connect-JmlGraph -ConfigPath $ConfigPath) }
    }

    Write-JmlBanner -Title "Rollback of run $RunId" -Lines @("Rollback run $($script:Jml.RunId)   Provider: $provider   Operator: $([Environment]::UserName)")
    $targets = @($source.Items | Where-Object { -not $EmployeeId -or $_.EmployeeId -in $EmployeeId })
    $outItems = [System.Collections.Generic.List[object]]::new()

    foreach ($item in $targets) {
        $succeeded = @($item.Actions | Where-Object { $_.Status -eq 'Succeeded' } | Sort-Object { [int]$_.Seq } -Descending)
        if (-not $succeeded.Count) { continue }
        $record = [ordered]@{ EmployeeId = $item.EmployeeId; DisplayName = $item.DisplayName; SourceOperation = $item.Operation; Steps = [System.Collections.Generic.List[object]]::new() }
        Write-Host ''
        Write-Host "  $($item.EmployeeId)  $($item.DisplayName)  [undo $($item.Operation)]" -ForegroundColor Yellow
        foreach ($a in $succeeded) {
            $step = [ordered]@{ Of = "$($a.System).$($a.Type)"; Description = $a.Description; Reverse = $(if ($a.Undo) { Format-JmlUndoDescription $a.Undo }); Status = $null; Error = $null }
            if (-not $a.Undo) {
                $step.Status = 'Irreversible'
                Write-Host "    [skip] $($a.System).$($a.Type) is irreversible: $($a.Description)" -ForegroundColor DarkYellow
            }
            elseif ($PSCmdlet.ShouldProcess("$($item.EmployeeId) ($($item.DisplayName))", "$($a.Undo.System).$($a.Undo.Type): $(Format-JmlUndoDescription $a.Undo)   (reverses $($a.System).$($a.Type))")) {
                try {
                    [void](Invoke-JmlDirectoryAction -System $a.Undo.System -Type $a.Undo.Type -Params $a.Undo.Params -EmployeeId $item.EmployeeId -SkipFaultInjection)
                    $step.Status = 'Reverted'
                    Write-JmlLog -Level AUDIT -EmployeeId $item.EmployeeId -Action "$($a.Undo.System).$($a.Undo.Type)" -Message "Reverted $($a.System).$($a.Type): $(Format-JmlUndoDescription $a.Undo)"
                }
                catch {
                    $step.Status = 'Failed'; $step.Error = $_.Exception.Message
                    Write-JmlLog -Level ERROR -EmployeeId $item.EmployeeId -Message "Revert of $($a.System).$($a.Type) failed: $($_.Exception.Message)"
                }
            }
            else { $step.Status = 'WhatIf' }
            $record.Steps.Add($step)
        }
        $outItems.Add($record)
    }

    if ($WhatIfPreference) { return }
    if ($Simulated) { Save-JmlSimulatedState -Path $script:Jml.SimStatePath }
    $journal = [ordered]@{
        RunId = $script:Jml.RunId; Mode = 'Rollback'; RollbackOf = $RunId; Provider = $provider
        Operator = '{0}\{1}' -f [Environment]::MachineName, [Environment]::UserName
        CompletedAt = (Get-Date).ToUniversalTime().ToString('o'); Items = $outItems
    }
    $path = Save-JmlJournal -Journal $journal
    Set-Content -LiteralPath $marker -Value "Undone by run $($script:Jml.RunId) at $($journal.CompletedAt)" -Encoding utf8
    $irreversible = @($outItems | ForEach-Object { $_.Steps } | Where-Object { $_.Status -eq 'Irreversible' })
    $lines = @("Rollback journal: $path")
    if ($irreversible.Count) { $lines += "$($irreversible.Count) irreversible step(s) need a human: issue a Temporary Access Pass so the worker can sign in again." }
    Write-JmlBanner -Title 'Rollback complete' -Lines $lines
}
