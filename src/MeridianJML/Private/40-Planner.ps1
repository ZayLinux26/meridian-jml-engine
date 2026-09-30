# Desired-state planner.
#
# The planner reads the HR snapshot and the current directory state and emits a
# list of discrete actions per identity. It never writes. Because every action
# comes from a diff between "what HR says" and "what the directory has", a
# second run over the same feed produces an empty plan. That is where the
# idempotency comes from: there is no "already done?" flag to get out of sync.

function New-JmlAction {
    param(
        [Parameter(Mandatory)][ValidateSet('AD', 'Entra')][string]$System,
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][hashtable]$Params,
        [switch]$Critical,
        [switch]$Commit,
        [hashtable]$Undo
    )
    [pscustomobject]@{
        Seq         = 0
        System      = $System
        Type        = $Type
        Key         = "$System.$Type"
        Description = $Description
        Params      = $Params
        Critical    = [bool]$Critical
        Commit      = [bool]$Commit
        Reversible  = [bool]$Undo
        Undo        = $Undo
        Status      = 'Pending'
        Error       = $null
        StartedAt   = $null
        CompletedAt = $null
    }
}

function Add-JmlAction {
    param([Parameter(Mandatory)]$Item, [Parameter(Mandatory)]$Action)
    $Action.Seq = $Item.Actions.Count + 1
    $Item.Actions.Add($Action)
}

function New-JmlPlanItem {
    param([Parameter(Mandatory)]$Record)
    [pscustomobject]@{
        EmployeeId    = $Record.EmployeeId
        DisplayName   = $Record.DisplayName
        IdentityType  = $Record.IdentityType
        Status        = $Record.Status
        Department    = $Record.Department
        Operation     = 'NoChange'
        Result        = 'NotRun'
        AccountExists = $false
        Account       = $null
        Actions       = [System.Collections.Generic.List[object]]::new()
        Notes         = [System.Collections.Generic.List[string]]::new()
    }
}

function New-JmlPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Records,
        [datetime]$Today = [datetime]::UtcNow.Date
    )
    $script:Jml.EntraCache = @{}
    $adIndex = Get-JmlAdUserIndex
    $reserved = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $items = [System.Collections.Generic.List[object]]::new()
    $planned = @{}   # EmployeeId -> DN for hybrid joiners created earlier in this run

    foreach ($r in (Sort-JmlRecordsByManager -Records $Records)) {
        try {
            if ($r.IdentityType -eq 'Hybrid') {
                $item = Get-JmlHybridPlan -Record $r -AdIndex $adIndex -Today $Today -Reserved $reserved -Planned $planned
                $create = @($item.Actions | Where-Object Key -eq 'AD.CreateUser')
                if ($create.Count) { $planned[$r.EmployeeId] = "CN=$($create[0].Params.Attributes.displayName),$($create[0].Params.Path)" }
            }
            else { $item = Get-JmlCloudOnlyPlan -Record $r -Today $Today -Reserved $reserved }
        }
        catch {
            $item = New-JmlPlanItem -Record $r
            $item.Operation = 'PlanError'
            $item.Notes.Add("Planning failed: $($_.Exception.Message)")
            Write-JmlLog -Level ERROR -EmployeeId $r.EmployeeId -Message "Planning failed: $($_.Exception.Message)"
        }
        $items.Add($item)
    }

    # Orphans: enabled accounts carrying an employeeID that HR no longer sends.
    # These are reported for review and never disabled automatically. A missing
    # row usually means a broken extract, not a termination.
    $feedIds = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Records.EmployeeId), [StringComparer]::OrdinalIgnoreCase)
    $orphans = @(foreach ($k in $adIndex.Keys) {
            $u = $adIndex[$k]
            if ($u.Enabled -and -not $feedIds.Contains($k)) {
                [pscustomobject]@{ EmployeeId = $k; SamAccountName = $u.SamAccountName; DistinguishedName = $u.DistinguishedName }
            }
        })
    [pscustomobject]@{ Items = $items.ToArray(); Orphans = $orphans }
}

function Sort-JmlRecordsByManager {
    # Managers before their reports, so a bulk day-one load can set the manager
    # attribute in the same run instead of waiting for the next one.
    param([object[]]$Records)
    $byId = @{}; foreach ($r in $Records) { $byId[$r.EmployeeId] = $r }
    $depth = @{}
    $getDepth = {
        param($id, $seen)
        if ($depth.ContainsKey($id)) { return $depth[$id] }
        $rec = $byId[$id]
        if (-not $rec -or -not $rec.ManagerId -or -not $byId.ContainsKey($rec.ManagerId) -or $seen.Contains($id)) { $depth[$id] = 0; return 0 }
        [void]$seen.Add($id)
        $d = 1 + (& $getDepth $rec.ManagerId $seen)
        $depth[$id] = $d
        return $d
    }
    foreach ($r in $Records) { [void](& $getDepth $r.EmployeeId ([System.Collections.Generic.HashSet[string]]::new())) }
    $i = 0
    return @($Records | ForEach-Object { [pscustomobject]@{ R = $_; D = $depth[$_.EmployeeId]; I = $i++ } } | Sort-Object D, I | ForEach-Object R)
}

function Get-JmlAttributeChanges {
    param([hashtable]$Current, [hashtable]$Desired, [string[]]$CaseInsensitive = @())
    $changes = @{}
    foreach ($k in $Desired.Keys) {
        $ci = $k -in $CaseInsensitive
        if (-not (Test-JmlValueEqual -A $Current[$k] -B $Desired[$k] -CaseInsensitive:$ci)) {
            $changes[$k] = @{ From = $Current[$k]; To = $Desired[$k] }
        }
    }
    return $changes
}

function Invert-JmlChanges {
    param([hashtable]$Changes)
    $inv = @{}
    foreach ($k in $Changes.Keys) { $inv[$k] = @{ From = $Changes[$k].To; To = $Changes[$k].From } }
    return $inv
}

function Format-JmlChanges {
    param([hashtable]$Changes)
    (@($Changes.Keys | Sort-Object) | ForEach-Object {
        $from = if ($Changes[$_].From) { $Changes[$_].From } else { '<empty>' }
        $to = if ($Changes[$_].To) { $Changes[$_].To } else { '<empty>' }
        if ($_ -eq 'manager') { $from = ($from -split ',')[0]; $to = ($to -split ',')[0] }
        "$_ '$from' -> '$to'"
    }) -join '; '
}

function Get-JmlHybridPlan {
    param($Record, [hashtable]$AdIndex, [datetime]$Today, $Reserved, [hashtable]$Planned = @{})
    $cfg = $script:Jml.Config
    $item = New-JmlPlanItem -Record $Record
    $ad = $AdIndex[$Record.EmployeeId]
    $deptOU = "OU=$($Record.Department),$($cfg.AD.UsersOU)"
    $effective = $Record.EffectiveDate

    if ($ad) { $item.AccountExists = $true; $item.Account = $ad.SamAccountName }

    if ($Record.Status -eq 'Terminated') {
        if (-not $ad) { $item.Notes.Add('No AD account found for this terminated worker. Nothing to deprovision.'); return $item }
        if ($effective -gt $Today) { $item.Operation = 'Deferred'; $item.Notes.Add("Termination scheduled for $($effective.ToString('yyyy-MM-dd')).") ; return $item }
        return (Add-JmlHybridLeaverActions -Item $item -Ad $ad -Effective $effective)
    }

    # ---- Active worker ----
    if (-not $ad -and $effective -gt $Today.AddDays($cfg.Safety.PreHireDays)) {
        $item.Operation = 'Deferred'
        $item.Notes.Add("Start date $($effective.ToString('yyyy-MM-dd')) is outside the $($cfg.Safety.PreHireDays)-day pre-hire window.")
        return $item
    }
    $shouldEnable = $effective -le $Today

    $desired = @{
        givenName                  = $Record.GivenName
        sn                         = $Record.Surname
        displayName                = $Record.DisplayName
        department                 = $Record.Department
        title                      = $Record.JobTitle
        physicalDeliveryOfficeName = $Record.Office
        employeeType               = $Record.EmploymentType
    }
    if ($Record.ManagerId) {
        $mgr = $AdIndex[$Record.ManagerId]
        if ($mgr) { $desired.manager = $mgr.DistinguishedName }
        elseif ($Planned.ContainsKey($Record.ManagerId)) { $desired.manager = $Planned[$Record.ManagerId] }
        else { $item.Notes.Add("Manager $($Record.ManagerId) has no AD account yet. Manager left unchanged; it converges on the next run.") }
    }
    else { $desired.manager = $null }

    $desiredAd = Get-JmlDesiredGroups -Record $Record -System AD
    $desiredEntra = Get-JmlDesiredGroups -Record $Record -System Entra

    if (-not $ad) {
        $item.Operation = 'Joiner'
        $upnSuffix = $cfg.AD.UpnSuffix
        $sam = New-JmlSamAccountName -GivenName $Record.GivenName -Surname $Record.Surname -Reserved $Reserved -IsTaken {
            param($c) (Test-JmlAdNameTaken -SamAccountName $c -UserPrincipalName "$c@$upnSuffix") -or (Test-JmlEntraUpnTaken -UserPrincipalName "$c@$upnSuffix")
        }
        $upn = "$sam@$upnSuffix"
        $item.Account = $sam
        $state = if ($shouldEnable) { 'enabled' } else { 'disabled until start date' }
        Add-JmlAction $item (New-JmlAction -System AD -Type CreateUser -Description "Create $sam ($upn) in $deptOU, $state" `
                -Params @{ Sam = $sam; Upn = $upn; Path = $deptOU; EmployeeId = $Record.EmployeeId; Enabled = $shouldEnable; Attributes = $desired } `
                -Undo @{ System = 'AD'; Type = 'RemoveUser'; Params = @{ Sam = $sam } })
        foreach ($g in $desiredAd) {
            Add-JmlAction $item (New-JmlAction -System AD -Type AddGroupMember -Description "Add to $g" -Params @{ Sam = $sam; Group = $g } `
                    -Undo @{ System = 'AD'; Type = 'RemoveGroupMember'; Params = @{ Sam = $sam; Group = $g } })
        }
        if ($desiredEntra.Count) {
            $item.Notes.Add("Entra groups ($($desiredEntra -join ', ')) apply on the next run, after Cloud Sync creates the cloud object.")
        }
        return $item
    }

    # ---- Existing account: diff ----
    $sam = $ad.SamAccountName
    $isRehire = (-not $ad.Enabled) -and (($ad.ParentOU -ieq $cfg.AD.DisabledOU) -or ($ad.Description -like 'Terminated*'))
    $changes = Get-JmlAttributeChanges -Current $ad.Attributes -Desired $desired -CaseInsensitive @('manager')
    if ($ad.Description -like 'Terminated*') { $changes.description = @{ From = $ad.Description; To = $null } }
    $hrChange = $changes.Count -gt 0

    if ($changes.Count) {
        Add-JmlAction $item (New-JmlAction -System AD -Type SetAttributes -Description (Format-JmlChanges $changes) `
                -Params @{ Sam = $sam; Changes = $changes } -Undo @{ System = 'AD'; Type = 'SetAttributes'; Params = @{ Sam = $sam; Changes = (Invert-JmlChanges $changes) } })
    }
    if ($ad.ParentOU -ine $deptOU) {
        $hrChange = $true
        Add-JmlAction $item (New-JmlAction -System AD -Type MoveUser -Description "Move to $deptOU" -Params @{ Sam = $sam; TargetOU = $deptOU } `
                -Undo @{ System = 'AD'; Type = 'MoveUser'; Params = @{ Sam = $sam; TargetOU = $ad.ParentOU } })
    }
    if ($shouldEnable -and -not $ad.Enabled) {
        Add-JmlAction $item (New-JmlAction -System AD -Type EnableUser -Description 'Enable account' -Params @{ Sam = $sam } `
                -Undo @{ System = 'AD'; Type = 'DisableUser'; Params = @{ Sam = $sam } })
    }

    $managedAd = Get-JmlManagedGroups -System AD
    foreach ($g in $desiredAd) {
        if ($g -notin $ad.Groups) {
            Add-JmlAction $item (New-JmlAction -System AD -Type AddGroupMember -Description "Add to $g" -Params @{ Sam = $sam; Group = $g } `
                    -Undo @{ System = 'AD'; Type = 'RemoveGroupMember'; Params = @{ Sam = $sam; Group = $g } })
        }
    }
    foreach ($g in $ad.Groups) {
        if ($g -in $managedAd -and $g -notin $desiredAd) {
            Add-JmlAction $item (New-JmlAction -System AD -Type RemoveGroupMember -Description "Remove from $g (no longer entitled)" -Params @{ Sam = $sam; Group = $g } `
                    -Undo @{ System = 'AD'; Type = 'AddGroupMember'; Params = @{ Sam = $sam; Group = $g } })
        }
    }

    $pendingSync = $false
    $entra = Get-JmlEntraUser -EmployeeId $Record.EmployeeId -UserPrincipalName $ad.UserPrincipalName
    if ($entra) {
        Add-JmlEntraGroupActions -Item $item -Entra $entra -DesiredNames $desiredEntra
    }
    elseif ($desiredEntra.Count) {
        $pendingSync = $true
        $item.Notes.Add('Cloud object not found yet (waiting on Cloud Sync). Entra groups apply on the next run.')
    }

    $item.Operation = if ($item.Actions.Count -eq 0) { if ($pendingSync) { 'PendingSync' } else { 'NoChange' } }
    elseif ($isRehire) { 'Rehire' }
    elseif ($hrChange) { 'Mover' }
    else { 'Reconcile' }
    if ($isRehire) { $item.Notes.Add('Rehire: credentials were randomised at termination. Issue a Temporary Access Pass for first sign-in.') }
    return $item
}

function Add-JmlEntraGroupActions {
    param($Item, $Entra, [string[]]$DesiredNames, [switch]$Leaver)
    $why = if ($Leaver) { '' } else { ' (no longer entitled)' }
    $desiredIds = @(foreach ($n in $DesiredNames) { $script:Jml.EntraGroupMap[$n] })
    foreach ($n in $DesiredNames) {
        $gid = $script:Jml.EntraGroupMap[$n]
        if ($gid -notin $Entra.GroupIds) {
            Add-JmlAction $Item (New-JmlAction -System Entra -Type AddGroupMember -Description "Add to $n" -Params @{ UserRef = $Entra.Id; GroupId = $gid; GroupName = $n } `
                    -Undo @{ System = 'Entra'; Type = 'RemoveGroupMember'; Params = @{ UserRef = $Entra.Id; GroupId = $gid; GroupName = $n } })
        }
    }
    foreach ($gid in $Entra.GroupIds) {
        if ($script:Jml.EntraGroupById.ContainsKey($gid) -and $gid -notin $desiredIds) {
            $n = $script:Jml.EntraGroupById[$gid]
            Add-JmlAction $Item (New-JmlAction -System Entra -Type RemoveGroupMember -Description "Remove from $n$why" -Params @{ UserRef = $Entra.Id; GroupId = $gid; GroupName = $n } `
                    -Undo @{ System = 'Entra'; Type = 'AddGroupMember'; Params = @{ UserRef = $Entra.Id; GroupId = $gid; GroupName = $n } })
        }
    }
}

function Test-JmlSessionsRevokedSince {
    param($Entra, [datetime]$Since)
    return ($Entra.SignInSessionsValidFrom -and $Entra.SignInSessionsValidFrom -ge $Since)
}

function Add-JmlHybridLeaverActions {
    <#
        Leaver order matters. Containment first (disable the account, kill cloud
        sessions) so the worker loses access even if everything after it fails.
        Cleanup next. The "Terminated" description stamp is written last and acts
        as the commit marker: until it is present, the next run keeps finishing
        the job.
    #>
    param($Item, $Ad, [datetime]$Effective)
    $cfg = $script:Jml.Config
    $sam = $Ad.SamAccountName
    $stamped = $Ad.Description -like 'Terminated*'
    $entra = Get-JmlEntraUser -EmployeeId $Item.EmployeeId -UserPrincipalName $Ad.UserPrincipalName

    if ($Ad.Enabled) {
        Add-JmlAction $Item (New-JmlAction -System AD -Type DisableUser -Description 'Disable AD account (containment)' -Params @{ Sam = $sam } -Critical `
                -Undo @{ System = 'AD'; Type = 'EnableUser'; Params = @{ Sam = $sam } })
    }
    if ($entra) {
        # Revoke until the leaver is committed. The stamp is only written when
        # every step succeeded, so a failed revoke is retried on the next run.
        if (-not $stamped -or $Ad.Enabled) {
            Add-JmlAction $Item (New-JmlAction -System Entra -Type RevokeSessions -Description 'Revoke Entra refresh tokens and sessions (containment)' -Params @{ UserRef = $entra.Id } -Critical)
        }
    }
    else { $Item.Notes.Add('No Entra object found; session revocation not needed.') }

    if (-not $stamped) {
        Add-JmlAction $Item (New-JmlAction -System AD -Type ResetPassword -Description 'Randomise password' -Params @{ Sam = $sam })
    }
    foreach ($g in $Ad.Groups) {
        Add-JmlAction $Item (New-JmlAction -System AD -Type RemoveGroupMember -Description "Remove from $g" -Params @{ Sam = $sam; Group = $g } `
                -Undo @{ System = 'AD'; Type = 'AddGroupMember'; Params = @{ Sam = $sam; Group = $g } })
    }
    if ($entra) { Add-JmlEntraGroupActions -Item $Item -Entra $entra -DesiredNames @() -Leaver }
    if ($Ad.ParentOU -ine $cfg.AD.DisabledOU) {
        Add-JmlAction $Item (New-JmlAction -System AD -Type MoveUser -Description "Move to $($cfg.AD.DisabledOU)" -Params @{ Sam = $sam; TargetOU = $cfg.AD.DisabledOU } `
                -Undo @{ System = 'AD'; Type = 'MoveUser'; Params = @{ Sam = $sam; TargetOU = $Ad.ParentOU } })
    }
    $final = @{}
    if ($Ad.Attributes.manager) { $final.manager = @{ From = $Ad.Attributes.manager; To = $null } }
    if (-not $stamped) {
        $final.description = @{ From = $Ad.Description; To = "Terminated $($Effective.ToString('yyyy-MM-dd')) | JML run $($script:Jml.RunId)" }
    }
    if ($final.Count) {
        Add-JmlAction $Item (New-JmlAction -System AD -Type SetAttributes -Description ("Commit leaver stamp: " + (Format-JmlChanges $final)) `
                -Params @{ Sam = $sam; Changes = $final } -Commit -Undo @{ System = 'AD'; Type = 'SetAttributes'; Params = @{ Sam = $sam; Changes = (Invert-JmlChanges $final) } })
    }
    $Item.Operation = if ($Item.Actions.Count) { 'Leaver' } else { 'NoChange' }
    return $Item
}

function Get-JmlCloudOnlyPlan {
    param($Record, [datetime]$Today, $Reserved)
    $cfg = $script:Jml.Config
    $item = New-JmlPlanItem -Record $Record
    $entra = Get-JmlEntraUser -EmployeeId $Record.EmployeeId -IncludeManager
    $effective = $Record.EffectiveDate
    if ($entra) { $item.AccountExists = $true; $item.Account = $entra.UserPrincipalName }

    if ($Record.Status -eq 'Terminated') {
        if (-not $entra) { $item.Notes.Add('No Entra account found for this terminated contractor. Nothing to deprovision.'); return $item }
        if ($effective -gt $Today) { $item.Operation = 'Deferred'; $item.Notes.Add("Termination scheduled for $($effective.ToString('yyyy-MM-dd')).") ; return $item }
        if ($entra.AccountEnabled) {
            Add-JmlAction $item (New-JmlAction -System Entra -Type DisableUser -Description 'Block sign-in (containment)' -Params @{ UserRef = $entra.Id } -Critical `
                    -Undo @{ System = 'Entra'; Type = 'EnableUser'; Params = @{ UserRef = $entra.Id } })
        }
        # Cloud-only users have no stamp, so containment is repeated while any
        # leaver work remains. A failed revoke keeps cleanup pending (see the
        # executor), which keeps the revoke in the next plan.
        $managedLeft = @($entra.GroupIds | Where-Object { $script:Jml.EntraGroupById.ContainsKey($_) }).Count
        $workLeft = $entra.AccountEnabled -or $managedLeft -or $entra.ManagerId
        if ($workLeft -or -not (Test-JmlSessionsRevokedSince -Entra $entra -Since $effective)) {
            Add-JmlAction $item (New-JmlAction -System Entra -Type RevokeSessions -Description 'Revoke refresh tokens and sessions (containment)' -Params @{ UserRef = $entra.Id } -Critical)
        }
        Add-JmlEntraGroupActions -Item $item -Entra $entra -DesiredNames @() -Leaver
        if ($entra.ManagerId) {
            Add-JmlAction $item (New-JmlAction -System Entra -Type ClearManager -Description 'Clear manager' -Params @{ UserRef = $entra.Id } `
                    -Undo @{ System = 'Entra'; Type = 'SetManager'; Params = @{ UserRef = $entra.Id; ManagerId = $entra.ManagerId } })
        }
        $item.Operation = if ($item.Actions.Count) { 'Leaver' } else { 'NoChange' }
        return $item
    }

    if (-not $entra -and $effective -gt $Today.AddDays($cfg.Safety.PreHireDays)) {
        $item.Operation = 'Deferred'
        $item.Notes.Add("Start date $($effective.ToString('yyyy-MM-dd')) is outside the $($cfg.Safety.PreHireDays)-day pre-hire window.")
        return $item
    }
    $shouldEnable = $effective -le $Today
    $desired = @{
        givenName = $Record.GivenName; surname = $Record.Surname; displayName = $Record.DisplayName
        department = $Record.Department; jobTitle = $Record.JobTitle; officeLocation = $Record.Office; employeeType = $Record.EmploymentType
    }
    $managerId = $null
    if ($Record.ManagerId) {
        $m = Get-JmlEntraUser -EmployeeId $Record.ManagerId
        if ($m) { $managerId = $m.Id } else { $item.Notes.Add("Manager $($Record.ManagerId) not found in Entra yet. Manager converges on a later run.") }
    }
    $desiredEntra = Get-JmlDesiredGroups -Record $Record -System Entra

    if (-not $entra) {
        $item.Operation = 'Joiner'
        $prefix = $cfg.Graph['ContractorPrefix']; if (-not $prefix) { $prefix = 'c-' }
        $suffix = $cfg.AD.UpnSuffix
        $nick = New-JmlSamAccountName -GivenName $Record.GivenName -Surname $Record.Surname -Prefix $prefix -Reserved $Reserved -IsTaken {
            param($c) Test-JmlEntraUpnTaken -UserPrincipalName "$c@$suffix"
        }
        $upn = "$nick@$suffix"
        $item.Account = $upn
        $usage = $cfg.Graph['UsageLocation']; if (-not $usage) { $usage = 'US' }
        Add-JmlAction $item (New-JmlAction -System Entra -Type CreateUser -Description "Create cloud-only user $upn" `
                -Params @{ Upn = $upn; MailNickname = $nick; EmployeeId = $Record.EmployeeId; Enabled = $shouldEnable; UsageLocation = $usage; Attributes = $desired } `
                -Undo @{ System = 'Entra'; Type = 'DeleteUser'; Params = @{ UserRef = $upn } })
        if ($managerId) {
            Add-JmlAction $item (New-JmlAction -System Entra -Type SetManager -Description "Set manager to $($Record.ManagerId)" -Params @{ UserRef = $upn; ManagerId = $managerId } `
                    -Undo @{ System = 'Entra'; Type = 'ClearManager'; Params = @{ UserRef = $upn } })
        }
        foreach ($n in $desiredEntra) {
            $gid = $script:Jml.EntraGroupMap[$n]
            Add-JmlAction $item (New-JmlAction -System Entra -Type AddGroupMember -Description "Add to $n" -Params @{ UserRef = $upn; GroupId = $gid; GroupName = $n } `
                    -Undo @{ System = 'Entra'; Type = 'RemoveGroupMember'; Params = @{ UserRef = $upn; GroupId = $gid; GroupName = $n } })
        }
        return $item
    }

    $isRehire = -not $entra.AccountEnabled
    $changes = Get-JmlAttributeChanges -Current $entra.Attributes -Desired $desired
    if ($changes.Count) {
        Add-JmlAction $item (New-JmlAction -System Entra -Type SetAttributes -Description (Format-JmlChanges $changes) -Params @{ UserRef = $entra.Id; Changes = $changes } `
                -Undo @{ System = 'Entra'; Type = 'SetAttributes'; Params = @{ UserRef = $entra.Id; Changes = (Invert-JmlChanges $changes) } })
    }
    if ($shouldEnable -and -not $entra.AccountEnabled) {
        Add-JmlAction $item (New-JmlAction -System Entra -Type EnableUser -Description 'Enable sign-in' -Params @{ UserRef = $entra.Id } `
                -Undo @{ System = 'Entra'; Type = 'DisableUser'; Params = @{ UserRef = $entra.Id } })
    }
    $managerChanged = $false
    if ($managerId -and $managerId -ne $entra.ManagerId) {
        $managerChanged = $true
        $undo = if ($entra.ManagerId) { @{ System = 'Entra'; Type = 'SetManager'; Params = @{ UserRef = $entra.Id; ManagerId = $entra.ManagerId } } } else { @{ System = 'Entra'; Type = 'ClearManager'; Params = @{ UserRef = $entra.Id } } }
        Add-JmlAction $item (New-JmlAction -System Entra -Type SetManager -Description "Set manager to $($Record.ManagerId)" -Params @{ UserRef = $entra.Id; ManagerId = $managerId } -Undo $undo)
    }
    Add-JmlEntraGroupActions -Item $item -Entra $entra -DesiredNames $desiredEntra

    $item.Operation = if ($item.Actions.Count -eq 0) { 'NoChange' } elseif ($isRehire) { 'Rehire' } elseif ($changes.Count -or $managerChanged) { 'Mover' } else { 'Reconcile' }
    return $item
}
