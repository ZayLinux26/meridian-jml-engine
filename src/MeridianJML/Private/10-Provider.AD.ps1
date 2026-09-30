# On-prem Active Directory provider. Every AD read and write in the engine goes
# through these functions, so the planner never calls the AD module directly and
# the simulated provider can stand in for it during tests and demos.

$script:JmlAdAttributes = @('givenName', 'sn', 'displayName', 'department', 'title', 'physicalDeliveryOfficeName', 'employeeType', 'manager', 'description')

function Get-JmlAdServerSplat {
    $server = $script:Jml.Config.AD['Server']
    if ($server) { return @{ Server = $server } }
    return @{}
}

function ConvertTo-JmlAdUser {
    param($AdObject)
    # Unset AD attributes are simply absent from the object, so read defensively
    # (the module runs under StrictMode).
    $get = { param($n) $p = $AdObject.PSObject.Properties[$n]; if ($p) { $p.Value } else { $null } }
    $groups = @(foreach ($dn in @(& $get 'MemberOf')) { if ($dn -match '^CN=(.+?)(?<!\\),') { $Matches[1] -replace '\\', '' } })
    [pscustomobject]@{
        SamAccountName    = & $get 'SamAccountName'
        DistinguishedName = & $get 'DistinguishedName'
        ParentOU          = Get-JmlParentContainer (& $get 'DistinguishedName')
        Enabled           = [bool](& $get 'Enabled')
        UserPrincipalName = & $get 'UserPrincipalName'
        EmployeeId        = [string](& $get 'EmployeeID')
        Description       = [string](& $get 'Description')
        Attributes        = @{
            givenName                  = & $get 'GivenName'
            sn                         = & $get 'Surname'
            displayName                = & $get 'DisplayName'
            department                 = & $get 'Department'
            title                      = & $get 'Title'
            physicalDeliveryOfficeName = & $get 'Office'
            employeeType               = & $get 'employeeType'
            manager                    = & $get 'Manager'
            description                = & $get 'Description'
        }
        Groups            = [string[]]$groups
    }
}

function Get-JmlAdUserIndex {
    # One LDAP query for the whole managed population instead of one per record.
    [CmdletBinding()]
    param()
    $index = @{}
    if ($script:Jml.Provider -eq 'Simulated') {
        foreach ($u in $script:Jml.SimState.AD.Users.Values) {
            if (-not $u.EmployeeId) { continue }
            if (-not $u.DistinguishedName.EndsWith($script:Jml.Config.AD.BaseOU, [StringComparison]::OrdinalIgnoreCase)) { continue }
            if ($index.ContainsKey($u.EmployeeId)) { throw "Anchor integrity violation: employeeID '$($u.EmployeeId)' is on more than one AD account." }
            $index[$u.EmployeeId] = ConvertTo-JmlSimAdUser $u
        }
        return $index
    }
    $props = @('EmployeeID', 'employeeType', 'Department', 'Title', 'Office', 'Manager', 'Description', 'MemberOf', 'DisplayName', 'UserPrincipalName')
    $srv = Get-JmlAdServerSplat
    $users = Get-ADUser -LDAPFilter '(employeeID=*)' -SearchBase $script:Jml.Config.AD.BaseOU -SearchScope Subtree -Properties $props @srv
    foreach ($u in $users) {
        $id = [string]$u.EmployeeID
        if ($index.ContainsKey($id)) { throw "Anchor integrity violation: employeeID '$id' is on more than one AD account ($($index[$id].SamAccountName), $($u.SamAccountName))." }
        $index[$id] = ConvertTo-JmlAdUser $u
    }
    return $index
}

function Test-JmlAdNameTaken {
    # Uniqueness is checked across the whole domain, including accounts outside OU=Meridian.
    param([Parameter(Mandatory)][string]$SamAccountName, [Parameter(Mandatory)][string]$UserPrincipalName)
    if ($script:Jml.Provider -eq 'Simulated') {
        if ($script:Jml.SimState.AD.Users.ContainsKey($SamAccountName)) { return $true }
        foreach ($u in $script:Jml.SimState.AD.Users.Values) { if ($u.UserPrincipalName -ieq $UserPrincipalName) { return $true } }
        return $false
    }
    $srv = Get-JmlAdServerSplat
    $hit = Get-ADUser -LDAPFilter "(|(sAMAccountName=$SamAccountName)(userPrincipalName=$UserPrincipalName))" @srv
    return [bool]$hit
}

function Invoke-JmlAdOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][hashtable]$Params
    )
    if ($script:Jml.Provider -eq 'Simulated') { return Invoke-JmlSimAdOperation -Type $Type -Params $Params }

    $srv = Get-JmlAdServerSplat
    switch ($Type) {
        'CreateUser' {
            $a = $Params.Attributes
            $other = @{ employeeID = $Params.EmployeeId }
            if ($a.employeeType) { $other.employeeType = $a.employeeType }
            $newArgs = @{
                Name                  = $a.displayName
                SamAccountName        = $Params.Sam
                UserPrincipalName     = $Params.Upn
                Path                  = $Params.Path
                GivenName             = $a.givenName
                Surname               = $a.sn
                DisplayName           = $a.displayName
                Department            = $a.department
                Title                 = $a.title
                Office                = $a.physicalDeliveryOfficeName
                Manager               = $a.manager
                AccountPassword       = New-JmlRandomPassword
                ChangePasswordAtLogon = $true
                Enabled               = [bool]$Params.Enabled
                OtherAttributes       = $other
            }
            foreach ($k in @($newArgs.Keys)) { if ($null -eq $newArgs[$k] -or ($newArgs[$k] -is [string] -and $newArgs[$k] -eq '')) { $newArgs.Remove($k) } }
            New-ADUser @newArgs @srv -ErrorAction Stop
        }
        'RemoveUser' {
            Remove-ADUser -Identity $Params.Sam -Confirm:$false @srv -ErrorAction Stop
        }
        'SetAttributes' {
            $replace = @{}; $clear = [System.Collections.Generic.List[string]]::new()
            foreach ($attr in $Params.Changes.Keys) {
                $to = $Params.Changes[$attr].To
                if ([string]::IsNullOrEmpty([string]$to)) { $clear.Add($attr) } else { $replace[$attr] = $to }
            }
            $setArgs = @{ Identity = $Params.Sam }
            if ($replace.Count) { $setArgs.Replace = $replace }
            if ($clear.Count) { $setArgs.Clear = $clear.ToArray() }
            Set-ADUser @setArgs @srv -ErrorAction Stop
            # CN follows displayName so ADUC and audit exports show the real name.
            if ($Params.Changes.ContainsKey('displayName') -and $Params.Changes.displayName.To) {
                $dn = (Get-ADUser -Identity $Params.Sam @srv -ErrorAction Stop).DistinguishedName
                Rename-ADObject -Identity $dn -NewName $Params.Changes.displayName.To @srv -ErrorAction Stop
            }
        }
        'AddGroupMember' {
            try { Add-ADGroupMember -Identity $Params.Group -Members $Params.Sam @srv -ErrorAction Stop }
            catch { if ($_.Exception.Message -notmatch 'already a member') { throw } }
        }
        'RemoveGroupMember' {
            try { Remove-ADGroupMember -Identity $Params.Group -Members $Params.Sam -Confirm:$false @srv -ErrorAction Stop }
            catch { if ($_.Exception.Message -notmatch 'not a member|does not exist') { throw } }
        }
        'DisableUser' { Disable-ADAccount -Identity $Params.Sam @srv -ErrorAction Stop }
        'EnableUser' { Enable-ADAccount -Identity $Params.Sam @srv -ErrorAction Stop }
        'MoveUser' {
            $dn = (Get-ADUser -Identity $Params.Sam @srv -ErrorAction Stop).DistinguishedName
            if ((Get-JmlParentContainer $dn) -ine $Params.TargetOU) {
                Move-ADObject -Identity $dn -TargetPath $Params.TargetOU @srv -ErrorAction Stop
            }
        }
        'ResetPassword' {
            Set-ADAccountPassword -Identity $Params.Sam -Reset -NewPassword (New-JmlRandomPassword) @srv -ErrorAction Stop
        }
        default { throw "Unknown AD operation '$Type'." }
    }
}
