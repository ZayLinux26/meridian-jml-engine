# Simulated directory provider.
#
# An in-memory AD + Entra pair, persisted to a JSON file between runs, with a
# stand-in for the Entra Cloud Sync cycle. It exists so the engine's logic
# (idempotency, rollback, circuit breaker, fault handling) can be tested in CI
# and demonstrated on any machine, including a Mac with no domain controller.
# It is not used when -Simulated is absent.

function New-JmlSimulatedState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$AccessModel)
    $entraGroups = @{}
    foreach ($g in (Get-JmlManagedGroups -System Entra -AccessModel $AccessModel)) { $entraGroups[[guid]::NewGuid().ToString()] = $g }
    @{
        AD    = @{ Users = @{}; Groups = [string[]](Get-JmlManagedGroups -System AD -AccessModel $AccessModel) }
        Entra = @{ Users = @{}; Groups = $entraGroups }
    }
}

function Import-JmlSimulatedState {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][hashtable]$AccessModel)
    if (Test-Path -LiteralPath $Path) {
        return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable)
    }
    return (New-JmlSimulatedState -AccessModel $AccessModel)
}

function Save-JmlSimulatedState {
    param([Parameter(Mandatory)][string]$Path)
    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $script:Jml.SimState | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding utf8
}

function ConvertTo-JmlSimAdUser {
    param([hashtable]$U)
    [pscustomobject]@{
        SamAccountName    = $U.SamAccountName
        DistinguishedName = $U.DistinguishedName
        ParentOU          = Get-JmlParentContainer $U.DistinguishedName
        Enabled           = [bool]$U.Enabled
        UserPrincipalName = $U.UserPrincipalName
        EmployeeId        = $U.EmployeeId
        Description       = [string]$U.Attributes['description']
        Attributes        = & { $h = @{}; foreach ($k in $script:JmlAdAttributes) { $h[$k] = $U.Attributes[$k] }; $h }
        Groups            = [string[]]@($U.Groups)
    }
}

function Get-JmlSimAdUserRecord {
    param([string]$Sam)
    $u = $script:Jml.SimState.AD.Users[$Sam]
    if (-not $u) { throw "Cannot find an object with identity: '$Sam'." }
    return $u
}

function Invoke-JmlSimAdOperation {
    param([string]$Type, [hashtable]$Params)
    $state = $script:Jml.SimState.AD
    switch ($Type) {
        'CreateUser' {
            if ($state.Users.ContainsKey($Params.Sam)) { throw "The account '$($Params.Sam)' already exists." }
            $attrs = @{}
            foreach ($k in $script:JmlAdAttributes) { $attrs[$k] = $Params.Attributes[$k] }
            $state.Users[$Params.Sam] = @{
                SamAccountName    = $Params.Sam
                DistinguishedName = "CN=$($Params.Attributes.displayName),$($Params.Path)"
                Enabled           = [bool]$Params.Enabled
                UserPrincipalName = $Params.Upn
                EmployeeId        = $Params.EmployeeId
                Attributes        = $attrs
                Groups            = @()
            }
        }
        'RemoveUser' { [void]$state.Users.Remove($Params.Sam) }
        'SetAttributes' {
            $u = Get-JmlSimAdUserRecord $Params.Sam
            foreach ($k in $Params.Changes.Keys) { $u.Attributes[$k] = $Params.Changes[$k].To }
            if ($Params.Changes.ContainsKey('displayName') -and $Params.Changes.displayName.To) {
                $u.DistinguishedName = "CN=$($Params.Changes.displayName.To),$(Get-JmlParentContainer $u.DistinguishedName)"
            }
        }
        'AddGroupMember' {
            if ($Params.Group -notin $state.Groups) { throw "Cannot find group '$($Params.Group)'." }
            $u = Get-JmlSimAdUserRecord $Params.Sam
            if ($Params.Group -notin @($u.Groups)) { $u.Groups = @(@($u.Groups) + $Params.Group) }
        }
        'RemoveGroupMember' {
            $u = Get-JmlSimAdUserRecord $Params.Sam
            $u.Groups = @(@($u.Groups) | Where-Object { $_ -ine $Params.Group })
        }
        'DisableUser' { (Get-JmlSimAdUserRecord $Params.Sam).Enabled = $false }
        'EnableUser' { (Get-JmlSimAdUserRecord $Params.Sam).Enabled = $true }
        'MoveUser' {
            $u = Get-JmlSimAdUserRecord $Params.Sam
            $cn = ($u.DistinguishedName -split '(?<!\\),', 2)[0]
            $u.DistinguishedName = "$cn,$($Params.TargetOU)"
        }
        'ResetPassword' { (Get-JmlSimAdUserRecord $Params.Sam).PwdLastSet = (Get-Date).ToUniversalTime().ToString('o') }
        default { throw "Unknown AD operation '$Type'." }
    }
}

function Invoke-JmlSimulatedCloudSync {
    <#
        Stand-in for one Entra Cloud Sync cycle: AD users under the scoped OU are
        created or updated in Entra as synced objects (onPremisesSyncEnabled),
        and synced objects whose AD source is gone are deleted.
    #>
    [CmdletBinding()]
    param()
    $ad = $script:Jml.SimState.AD.Users
    $entra = $script:Jml.SimState.Entra.Users
    $created = 0; $updated = 0; $deleted = 0
    $bySam = @{}
    foreach ($e in $entra.Values) { if ($e.OnPremisesSyncEnabled) { $bySam[$e.OnPremSam] = $e } }

    foreach ($u in $ad.Values) {
        if (-not $u.DistinguishedName.EndsWith($script:Jml.Config.AD.BaseOU, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $e = $bySam[$u.SamAccountName]
        if (-not $e) {
            $id = [guid]::NewGuid().ToString()
            $e = @{ Id = $id; OnPremisesSyncEnabled = $true; OnPremSam = $u.SamAccountName; Groups = @(); ManagerId = $null; SignInSessionsValidFrom = (Get-Date).ToUniversalTime().AddDays(-30).ToString('o'); Attributes = @{} }
            $entra[$id] = $e
            $created++
        }
        else { $updated++ }
        $e.UserPrincipalName = $u.UserPrincipalName
        $e.AccountEnabled = [bool]$u.Enabled
        $e.EmployeeId = $u.EmployeeId
        $e.Attributes = @{
            givenName = $u.Attributes['givenName']; surname = $u.Attributes['sn']; displayName = $u.Attributes['displayName']
            department = $u.Attributes['department']; jobTitle = $u.Attributes['title']; officeLocation = $u.Attributes['physicalDeliveryOfficeName']
            employeeType = $u.Attributes['employeeType']
        }
    }
    foreach ($sam in @($bySam.Keys)) {
        if (-not $ad.ContainsKey($sam)) { [void]$entra.Remove($bySam[$sam].Id); $deleted++ }
    }
    [pscustomobject]@{ Created = $created; Updated = $updated; Deleted = $deleted }
}

function Get-JmlSimEntraUser {
    param([string]$EmployeeId, [string]$UserPrincipalName)
    $match = $null
    $hits = @($script:Jml.SimState.Entra.Users.Values | Where-Object { $EmployeeId -and $_.EmployeeId -eq $EmployeeId })
    if ($hits.Count -gt 1) { throw "Anchor integrity violation: employeeId '$EmployeeId' is on $($hits.Count) Entra users." }
    if ($hits.Count -eq 1) { $match = $hits[0] }
    if (-not $match -and $UserPrincipalName) {
        $match = @($script:Jml.SimState.Entra.Users.Values | Where-Object { $_.UserPrincipalName -ieq $UserPrincipalName }) | Select-Object -First 1
        if ($match -and $EmployeeId -and $match.EmployeeId -and $match.EmployeeId -ne $EmployeeId) {
            throw "UPN '$UserPrincipalName' belongs to employeeId '$($match.EmployeeId)', not '$EmployeeId'. Refusing to match."
        }
    }
    if (-not $match) { return $null }
    $raw = @{
        id = $match.Id; userPrincipalName = $match.UserPrincipalName; accountEnabled = $match.AccountEnabled
        onPremisesSyncEnabled = $match.OnPremisesSyncEnabled; employeeId = $match.EmployeeId
        signInSessionsValidFromDateTime = $match.SignInSessionsValidFrom
    }
    foreach ($k in $match.Attributes.Keys) { $raw[$k] = $match.Attributes[$k] }
    return (ConvertTo-JmlEntraUser -U $raw -GroupIds @($match.Groups) -ManagerId $match.ManagerId)
}

function Get-JmlSimEntraUserRecord {
    param([string]$UserRef)
    $id = Resolve-JmlEntraUserId $UserRef
    $u = $script:Jml.SimState.Entra.Users[$id]
    if (-not $u) { throw "Entra user '$UserRef' not found." }
    return $u
}

function Invoke-JmlSimEntraOperation {
    param([string]$Type, [hashtable]$Params)
    $users = $script:Jml.SimState.Entra.Users
    switch ($Type) {
        'CreateUser' {
            if (Test-JmlEntraUpnTaken -UserPrincipalName $Params.Upn) { throw "Another object with the same value for property userPrincipalName already exists." }
            $id = [guid]::NewGuid().ToString()
            $users[$id] = @{
                Id = $id; UserPrincipalName = $Params.Upn; AccountEnabled = [bool]$Params.Enabled; OnPremisesSyncEnabled = $false
                EmployeeId = $Params.EmployeeId; Groups = @(); ManagerId = $null
                SignInSessionsValidFrom = (Get-Date).ToUniversalTime().ToString('o'); Attributes = $Params.Attributes.Clone()
            }
            return $id
        }
        'DeleteUser' {
            $hit = @($users.Values | Where-Object { $_.UserPrincipalName -ieq $Params.UserRef -or $_.Id -eq $Params.UserRef }) | Select-Object -First 1
            if ($hit) { [void]$users.Remove($hit.Id) }
        }
        'SetAttributes' {
            $u = Get-JmlSimEntraUserRecord $Params.UserRef
            if ($u.OnPremisesSyncEnabled) { throw 'Unable to update the specified properties for on-premises mastered Directory Sync objects.' }
            foreach ($k in $Params.Changes.Keys) { $u.Attributes[$k] = $Params.Changes[$k].To }
        }
        'DisableUser' {
            $u = Get-JmlSimEntraUserRecord $Params.UserRef
            if ($u.OnPremisesSyncEnabled) { throw 'Unable to update the specified properties for on-premises mastered Directory Sync objects.' }
            $u.AccountEnabled = $false
        }
        'EnableUser' {
            $u = Get-JmlSimEntraUserRecord $Params.UserRef
            if ($u.OnPremisesSyncEnabled) { throw 'Unable to update the specified properties for on-premises mastered Directory Sync objects.' }
            $u.AccountEnabled = $true
        }
        'RevokeSessions' { (Get-JmlSimEntraUserRecord $Params.UserRef).SignInSessionsValidFrom = (Get-Date).ToUniversalTime().ToString('o') }
        'SetManager' {
            if (-not $users.ContainsKey($Params.ManagerId)) { throw "Manager '$($Params.ManagerId)' not found." }
            (Get-JmlSimEntraUserRecord $Params.UserRef).ManagerId = $Params.ManagerId
        }
        'ClearManager' { (Get-JmlSimEntraUserRecord $Params.UserRef).ManagerId = $null }
        'AddGroupMember' {
            if (-not $script:Jml.SimState.Entra.Groups.ContainsKey($Params.GroupId)) { throw "Group '$($Params.GroupId)' not found." }
            $u = Get-JmlSimEntraUserRecord $Params.UserRef
            if ($Params.GroupId -notin @($u.Groups)) { $u.Groups = @(@($u.Groups) + $Params.GroupId) }
        }
        'RemoveGroupMember' {
            $u = Get-JmlSimEntraUserRecord $Params.UserRef
            $u.Groups = @(@($u.Groups) | Where-Object { $_ -ne $Params.GroupId })
        }
        default { throw "Unknown Entra operation '$Type'." }
    }
}
