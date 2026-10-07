# Executor.
#
# One identity is one unit of work. Two execution policies:
#
#   Atomic (Joiner, Mover, Rehire, Reconcile)
#     Actions run in order. On the first failure the executor stops and runs
#     the compensating (undo) action for everything that already succeeded, in
#     reverse order. The identity ends up either fully changed or back where it
#     started, never half-provisioned.
#
#   FailSecure (Leaver)
#     Rolling back a termination would hand access back to someone who should
#     not have it, so leavers never auto-rollback. Every action is attempted
#     even if an earlier one fails. Containment actions are flagged Critical.
#     Result is Completed, Contained (containment done, cleanup pending), or
#     ContainmentFailed (page someone). Two guards keep a re-run honest:
#       - if a Critical step fails, non-critical cleanup is held back, so the
#         next plan still contains the containment step and retries it;
#       - the Commit step (leaver stamp) only runs when nothing failed, so an
#         unfinished leaver is never marked finished.

function Invoke-JmlDirectoryAction {
    param(
        [Parameter(Mandatory)][string]$System,
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][hashtable]$Params,
        [string]$EmployeeId,
        [switch]$SkipFaultInjection
    )
    $fi = $script:Jml.FaultInjection
    if (-not $SkipFaultInjection -and $fi -and $fi.Key -ieq "$System.$Type" -and (-not $fi.EmployeeId -or $fi.EmployeeId -ieq $EmployeeId)) {
        throw "[FAULT INJECTION] Simulated failure of $System.$Type"
    }
    if ($System -eq 'AD') { return Invoke-JmlAdOperation -Type $Type -Params $Params }
    return Invoke-JmlEntraOperation -Type $Type -Params $Params
}

function Invoke-JmlPlanItem {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Item)

    if ($Item.Actions.Count -eq 0) { $Item.Result = 'NoAction'; return $Item }
    $policy = if ($Item.Operation -eq 'Leaver') { 'FailSecure' } else { 'Atomic' }
    $done = [System.Collections.Generic.List[object]]::new()
    Write-JmlLog -Level AUDIT -EmployeeId $Item.EmployeeId -Message "$($Item.Operation) start ($policy, $($Item.Actions.Count) actions)"

    foreach ($a in $Item.Actions) {
        if ($policy -eq 'FailSecure') {
            $criticalDown = @($Item.Actions | Where-Object { $_.Status -eq 'Failed' -and $_.Critical }).Count
            $anyDown = @($Item.Actions | Where-Object { $_.Status -eq 'Failed' }).Count
            if (($criticalDown -and -not $a.Critical) -or ($a.Commit -and $anyDown)) {
                $a.Status = 'Skipped'
                $why = if ($criticalDown) { 'containment failed; cleanup held so the next run retries containment first' } else { 'commit marker held until every step succeeds' }
                Write-JmlLog -Level WARN -EmployeeId $Item.EmployeeId -Action $a.Key -Message "SKIP $($a.Key): $why"
                continue
            }
        }
        $a.StartedAt = (Get-Date).ToUniversalTime().ToString('o')
        try {
            $out = Invoke-JmlDirectoryAction -System $a.System -Type $a.Type -Params $a.Params -EmployeeId $Item.EmployeeId
            if ($a.Key -eq 'Entra.CreateUser' -and $out -is [string] -and $out) {
                # Later steps referenced the user by UPN. Swap in the new object id
                # so they do not depend on the UPN index having replicated yet.
                foreach ($later in $Item.Actions) {
                    foreach ($bag in @($later.Params, $(if ($later.Undo) { $later.Undo.Params }))) {
                        if ($bag -and $bag.ContainsKey('UserRef') -and $bag.UserRef -ieq $a.Params.Upn) { $bag.UserRef = $out }
                    }
                }
                $a.Params.CreatedId = $out
            }
            $a.Status = 'Succeeded'
            $a.CompletedAt = (Get-Date).ToUniversalTime().ToString('o')
            $done.Add($a)
            Write-JmlLog -Level AUDIT -EmployeeId $Item.EmployeeId -Action $a.Key -Message "OK   $($a.Key): $($a.Description)"
        }
        catch {
            $a.Status = 'Failed'
            $a.Error = $_.Exception.Message
            $a.CompletedAt = (Get-Date).ToUniversalTime().ToString('o')
            Write-JmlLog -Level ERROR -EmployeeId $Item.EmployeeId -Action $a.Key -Message "FAIL $($a.Key): $($a.Error)"
            if ($policy -eq 'Atomic') { break }
        }
    }

    $failed = @($Item.Actions | Where-Object Status -eq 'Failed')
    if ($policy -eq 'Atomic') {
        if (-not $failed.Count) { $Item.Result = 'Completed'; return $Item }
        foreach ($a in $Item.Actions) { if ($a.Status -eq 'Pending') { $a.Status = 'NotStarted' } }
        Write-JmlLog -Level WARN -EmployeeId $Item.EmployeeId -Message "Rolling back $($done.Count) completed action(s)"
        $rollbackOk = $true
        for ($i = $done.Count - 1; $i -ge 0; $i--) {
            $a = $done[$i]
            if (-not $a.Undo) { $a.Status = 'Irreversible'; $rollbackOk = $false; continue }
            try {
                [void](Invoke-JmlDirectoryAction -System $a.Undo.System -Type $a.Undo.Type -Params $a.Undo.Params -EmployeeId $Item.EmployeeId -SkipFaultInjection)
                $a.Status = 'Compensated'
                Write-JmlLog -Level AUDIT -EmployeeId $Item.EmployeeId -Action "$($a.Undo.System).$($a.Undo.Type)" -Message "UNDO $($a.Key) compensated"
            }
            catch {
                $a.Status = 'CompensationFailed'
                $a.Error = "Compensation failed: $($_.Exception.Message)"
                $rollbackOk = $false
                Write-JmlLog -Level ERROR -EmployeeId $Item.EmployeeId -Action $a.Key -Message "UNDO FAILED $($a.Key): $($_.Exception.Message)"
            }
        }
        $Item.Result = if ($rollbackOk) { 'RolledBack' } else { 'RollbackFailed' }
        return $Item
    }

    # FailSecure
    $criticalFailed = @($failed | Where-Object Critical)
    $Item.Result = if ($criticalFailed.Count) { 'ContainmentFailed' } elseif ($failed.Count) { 'Contained' } else { 'Completed' }
    $pending = @($Item.Actions | Where-Object { $_.Status -in @('Failed', 'Skipped') }).Count
    if ($Item.Result -eq 'ContainmentFailed') {
        Write-JmlLog -Level ERROR -EmployeeId $Item.EmployeeId -Message 'CONTAINMENT FAILED. Worker may still have access. Escalate to the SOC.'
    }
    elseif ($Item.Result -eq 'Contained') {
        Write-JmlLog -Level WARN -EmployeeId $Item.EmployeeId -Message "Access contained. $pending action(s) pending; the next run completes them."
    }
    return $Item
}

function Save-JmlJournal {
    param([Parameter(Mandatory)][hashtable]$Journal, [string]$Name)
    if (-not $Name) { $Name = "$($Journal.RunId).json" }
    $path = Join-Path -Path $script:Jml.Config.Paths.Journal -ChildPath $Name
    $Journal | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $path -Encoding utf8
    return $path
}

function Export-JmlReport {
    param([Parameter(Mandatory)][object[]]$Items, [Parameter(Mandatory)][string]$RunId)
    $path = Join-Path -Path $script:Jml.Config.Paths.Reports -ChildPath "report-$RunId.csv"
    $Items | ForEach-Object {
        [pscustomobject]@{
            RunId        = $RunId
            EmployeeId   = $_.EmployeeId
            DisplayName  = $_.DisplayName
            IdentityType = $_.IdentityType
            Account      = $_.Account
            Operation    = $_.Operation
            Result       = $_.Result
            Planned      = $_.Actions.Count
            Succeeded    = @($_.Actions | Where-Object Status -eq 'Succeeded').Count
            Failed       = @($_.Actions | Where-Object Status -eq 'Failed').Count
            Notes        = ($_.Notes -join ' | ')
        }
    } | Export-Csv -LiteralPath $path -NoTypeInformation -Encoding utf8
    return $path
}
