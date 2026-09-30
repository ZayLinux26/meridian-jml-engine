function Invoke-JmlRun {
    <#
    .SYNOPSIS
        Runs the Joiner-Mover-Leaver engine against an HR snapshot.
    .DESCRIPTION
        Plan mode (the default) reads everything, writes nothing, and saves the
        plan as change evidence. -Apply executes the plan. Both modes write a
        JSON Lines log, a journal and a CSV report under the configured output
        folders, stamped with the same RunId.
    .PARAMETER ConfigPath
        Path to the .psd1 engine config.
    .PARAMETER FeedPath
        HR snapshot CSV.
    .PARAMETER Apply
        Execute the plan. Without it, nothing is changed.
    .PARAMETER Simulated
        Use the in-memory simulated directory instead of AD and Graph.
    .PARAMETER OverrideSafetyLimit
        Proceed even if the leaver circuit breaker trips. Every override is
        journaled with the operator name.
    .PARAMETER SimulateFailure
        Lab only. Makes one action type fail (for example AD.MoveUser) to
        demonstrate rollback and fail-secure behaviour.
    .EXAMPLE
        Invoke-JmlRun -ConfigPath ./config/jml.config.psd1 -FeedPath ./data/hr-feed-day1.csv
    .EXAMPLE
        Invoke-JmlRun -ConfigPath ./config/jml.config.psd1 -FeedPath ./data/hr-feed-day3.csv -Apply -SimulateFailure AD.MoveUser -SimulateFailureFor 100008
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$FeedPath,
        [switch]$Apply,
        [switch]$Simulated,
        [string]$SimulationStatePath,
        [switch]$OverrideSafetyLimit,
        [ValidatePattern('^(AD|Entra)\.[A-Za-z]+$')][string]$SimulateFailure,
        [string]$SimulateFailureFor,
        [datetime]$AsOfDate = [datetime]::UtcNow.Date,
        [switch]$Quiet,
        [switch]$PassThru
    )

    $loaded = Import-JmlConfig -Path $ConfigPath
    $provider = if ($Simulated) { 'Simulated' } else { 'Live' }
    Initialize-JmlContext -Config $loaded.Config -AccessModel $loaded.AccessModel -Provider $provider -Quiet:$Quiet
    $cfg = $script:Jml.Config
    $runId = $script:Jml.RunId
    $started = (Get-Date).ToUniversalTime()
    $mode = if ($Apply) { 'APPLY' } else { 'PLAN (dry run, no changes)' }

    Write-JmlBanner -Title "$($cfg.Organization) | Joiner-Mover-Leaver Engine" -Lines @(
        "Run $runId   Mode: $mode   Provider: $provider   As of: $($AsOfDate.ToString('yyyy-MM-dd'))"
    )

    # ---- Connect / load directory ----
    if ($Simulated) {
        if (-not $SimulationStatePath) { $SimulationStatePath = Join-Path -Path $cfg.Paths.Simulation -ChildPath 'sim-state.json' }
        $script:Jml.SimStatePath = [System.IO.Path]::GetFullPath($SimulationStatePath)
        $script:Jml.SimState = Import-JmlSimulatedState -Path $script:Jml.SimStatePath -AccessModel $script:Jml.AccessModel
        $sync = Invoke-JmlSimulatedCloudSync
        Write-JmlLog -Message "Simulated Cloud Sync cycle: $($sync.Created) created, $($sync.Updated) updated, $($sync.Deleted) deleted in Entra"
    }
    else {
        Import-Module ActiveDirectory -ErrorAction Stop -Verbose:$false
        if (-not (Get-Command Get-MgContext -ErrorAction SilentlyContinue) -or -not (Get-MgContext)) { [void](Connect-JmlGraph -ConfigPath $ConfigPath) }
        $ctx = Get-MgContext
        Write-JmlLog -Message "Graph: tenant $($ctx.TenantId), app $($ctx.ClientId), auth $($ctx.AuthType)"
    }

    # ---- Feed ----
    $feed = Import-JmlHrFeed -Path $FeedPath
    Write-JmlLog -Message "Feed $([System.IO.Path]::GetFileName($FeedPath)): $($feed.Records.Count) valid, $($feed.Rejected.Count) rejected, SHA256 $($feed.Sha256.Substring(0,16))..."
    foreach ($rej in $feed.Rejected) { Write-JmlLog -Level WARN -EmployeeId $rej.EmployeeId -Message "Rejected feed line $($rej.Line): $($rej.Reasons)" }

    Resolve-JmlEntraGroupMap

    # ---- Plan ----
    $plan = New-JmlPlan -Records $feed.Records -Today $AsOfDate
    $items = $plan.Items
    foreach ($o in $plan.Orphans) {
        Write-JmlLog -Level WARN -EmployeeId $o.EmployeeId -Message "Orphan: $($o.SamAccountName) is enabled but not in the HR feed. Flagged for review, not changed."
    }

    # ---- Circuit breaker ----
    $leavers = @($items | Where-Object Operation -eq 'Leaver').Count
    $population = [Math]::Max(1, @($items | Where-Object AccountExists).Count)
    $pct = [Math]::Round(($leavers / $population) * 100, 1)
    $tripped = ($leavers -gt $cfg.Safety.MaxLeaversPerRun) -or ($leavers -gt 1 -and $pct -gt $cfg.Safety.MaxLeaverPercent)
    $safety = [ordered]@{
        Leavers = $leavers; Population = $population; LeaverPercent = $pct
        MaxLeaversPerRun = $cfg.Safety.MaxLeaversPerRun; MaxLeaverPercent = $cfg.Safety.MaxLeaverPercent
        Tripped = $tripped; Overridden = $false
    }

    Write-JmlItemTable -Items $items
    Write-JmlActionDetail -Items $items

    $journal = [ordered]@{
        RunId          = $runId
        Mode           = if ($Apply) { 'Apply' } else { 'Plan' }
        Provider       = $provider
        Operator       = '{0}\{1}' -f [Environment]::MachineName, [Environment]::UserName
        StartedAt      = $started.ToString('o')
        CompletedAt    = $null
        AsOfDate       = $AsOfDate.ToString('yyyy-MM-dd')
        Feed           = [ordered]@{ Path = (Resolve-Path -LiteralPath $FeedPath).Path; Sha256 = $feed.Sha256; Valid = $feed.Records.Count; Rejected = $feed.Rejected }
        Safety         = $safety
        FaultInjection = $null
        Orphans        = $plan.Orphans
        Items          = $items
        Summary        = $null
        Status         = 'Planned'
    }

    if ($tripped) {
        $msg = "SAFETY LIMIT: $leavers leavers ($pct% of $population existing identities) exceeds MaxLeaversPerRun=$($cfg.Safety.MaxLeaversPerRun) / MaxLeaverPercent=$($cfg.Safety.MaxLeaverPercent)%."
        if ($Apply -and -not $OverrideSafetyLimit) {
            Write-JmlLog -Level ERROR -Message "$msg Run aborted before any change. Verify the feed with HR, then re-run with -OverrideSafetyLimit if it is genuine."
            $journal.Status = 'AbortedBySafetyLimit'
            $journal.CompletedAt = (Get-Date).ToUniversalTime().ToString('o')
            [void](Save-JmlJournal -Journal $journal)
            throw [System.InvalidOperationException]::new($msg)
        }
        if ($Apply) { $safety.Overridden = $true; Write-JmlLog -Level WARN -Message "$msg OVERRIDDEN by $($journal.Operator)." }
        else { Write-JmlLog -Level WARN -Message "$msg Apply would be blocked." }
    }

    # ---- Execute ----
    if ($Apply) {
        if ($SimulateFailure) {
            $script:Jml.FaultInjection = @{ Key = $SimulateFailure; EmployeeId = $SimulateFailureFor }
            $journal.FaultInjection = $script:Jml.FaultInjection
            Write-JmlLog -Level WARN -Message "Fault injection armed: $SimulateFailure $(if ($SimulateFailureFor) { "for $SimulateFailureFor" } else { 'for all identities' })"
        }
        # Leavers go first: removing access outranks granting it.
        $ordered = @($items | Where-Object Operation -eq 'Leaver') + @($items | Where-Object Operation -ne 'Leaver')
        if (-not $Quiet) { Write-Host '' }
        foreach ($i in $ordered) {
            if ($i.Operation -eq 'PlanError') { $i.Result = 'Skipped'; continue }
            [void](Invoke-JmlPlanItem -Item $i)
        }
        if ($Simulated) { Save-JmlSimulatedState -Path $script:Jml.SimStatePath }
        $journal.Status = 'Applied'
        Write-JmlBanner -Title 'Results' -Lines @()
        Write-JmlItemTable -Items $items -ShowResult
        $problems = @($items | Where-Object { $_.Result -in @('RolledBack', 'RollbackFailed', 'Contained', 'ContainmentFailed') })
        if ($problems.Count) { Write-JmlActionDetail -Items $problems -ShowStatus }
    }

    $journal.CompletedAt = (Get-Date).ToUniversalTime().ToString('o')
    $journal.Summary = [ordered]@{
        Operations = Get-JmlCounts -Items $items -Property Operation
        Results    = if ($Apply) { Get-JmlCounts -Items $items -Property Result } else { $null }
        Actions    = ($items | Measure-Object -Property { $_.Actions.Count } -Sum).Sum
        Orphans    = @($plan.Orphans).Count
    }
    $journalPath = Save-JmlJournal -Journal $journal
    $reportPath = Export-JmlReport -Items $items -RunId $runId

    $opSummary = ($journal.Summary.Operations.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '  '
    $lines = @("Operations: $opSummary", "Total actions: $($journal.Summary.Actions)   Orphans flagged: $($journal.Summary.Orphans)")
    if ($Apply) { $lines += 'Results: ' + (($journal.Summary.Results.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '  ') }
    $lines += "Journal: $journalPath", "Report:  $reportPath", "Log:     $($script:Jml.LogFile)"
    Write-JmlBanner -Title "Run $runId complete" -Lines $lines

    $result = [pscustomobject]@{
        RunId       = $runId
        Mode        = $journal.Mode
        Items       = $items
        Orphans     = $plan.Orphans
        Rejected    = $feed.Rejected
        Safety      = [pscustomobject]$safety
        JournalPath = $journalPath
        ReportPath  = $reportPath
        LogPath     = $script:Jml.LogFile
    }
    if ($PassThru) { return $result }
}
