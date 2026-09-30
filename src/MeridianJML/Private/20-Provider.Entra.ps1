# Microsoft Entra ID provider over Microsoft Graph v1.0.
#
# Calls go through Invoke-MgGraphRequest (Microsoft.Graph.Authentication) rather
# than the per-resource SDK cmdlets. One module to load, exact control over
# $select / $filter / headers, and no assembly version clashes between the
# Graph sub-modules on a shared automation host.

$script:JmlGraphUserSelect = 'id,userPrincipalName,accountEnabled,onPremisesSyncEnabled,employeeId,employeeType,givenName,surname,displayName,department,jobTitle,officeLocation,signInSessionsValidFromDateTime'

function Get-JmlHttpStatus {
    param($ErrorRecord)
    $resp = $ErrorRecord.Exception.PSObject.Properties['Response']
    if ($resp -and $resp.Value -and $resp.Value.PSObject.Properties['StatusCode']) { return [int]$resp.Value.StatusCode }
    if ($ErrorRecord.Exception.Message -match '\b(400|401|403|404|409|429|500|502|503|504)\b') { return [int]$Matches[1] }
    return 0
}

function Invoke-JmlGraph {
    # Thin wrapper with retry on throttling (429) and transient 5xx, honouring
    # Retry-After when Graph sends it.
    [CmdletBinding()]
    param(
        [ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')][string]$Method = 'GET',
        [Parameter(Mandatory)][string]$Uri,
        $Body,
        [hashtable]$Headers = @{},
        [switch]$AllowNotFound,
        [int]$MaxAttempts = 4
    )
    $full = if ($Uri -like 'https://*') { $Uri } else { "https://graph.microsoft.com/v1.0/$Uri" }
    $req = @{ Method = $Method; Uri = $full; Headers = $Headers; OutputType = 'Hashtable'; ErrorAction = 'Stop' }
    if ($null -ne $Body) { $req.Body = ($Body | ConvertTo-Json -Depth 6 -Compress); $req.ContentType = 'application/json' }
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try { return Invoke-MgGraphRequest @req }
        catch {
            $status = Get-JmlHttpStatus $_
            if ($status -eq 404 -and $AllowNotFound) { return $null }
            if ($status -in @(429, 500, 502, 503, 504) -and $attempt -lt $MaxAttempts) {
                $delay = [Math]::Pow(2, $attempt)
                Write-JmlLog -Level DEBUG -Message "Graph $status on $Method $Uri, retry $attempt in ${delay}s"
                Start-Sleep -Seconds $delay
                continue
            }
            throw
        }
    }
}

function Get-JmlGraphPaged {
    param([Parameter(Mandatory)][string]$Uri, [hashtable]$Headers = @{})
    $items = [System.Collections.Generic.List[object]]::new()
    $next = $Uri
    while ($next) {
        $page = Invoke-JmlGraph -Uri $next -Headers $Headers
        foreach ($v in @($page.value)) { $items.Add($v) }
        $next = $page['@odata.nextLink']
    }
    return , $items.ToArray()
}

function ConvertTo-JmlEntraUser {
    param([hashtable]$U, [string[]]$GroupIds, [string]$ManagerId)
    [pscustomobject]@{
        Id                      = $U.id
        UserPrincipalName       = $U.userPrincipalName
        AccountEnabled          = [bool]$U.accountEnabled
        OnPremisesSyncEnabled   = [bool]$U.onPremisesSyncEnabled
        EmployeeId              = $U.employeeId
        SignInSessionsValidFrom = ConvertTo-JmlUtcDate $U.signInSessionsValidFromDateTime
        ManagerId               = $ManagerId
        GroupIds                = [string[]]@($GroupIds)
        Attributes              = @{
            givenName      = $U.givenName
            surname        = $U.surname
            displayName    = $U.displayName
            department     = $U.department
            jobTitle       = $U.jobTitle
            officeLocation = $U.officeLocation
            employeeType   = $U.employeeType
        }
    }
}

function Get-JmlEntraUser {
    <#
        Finds a user by employeeId first (the immutable HR anchor), then falls back
        to UPN. The fallback covers sync configurations that do not flow
        employeeID, but a UPN hit that carries a different employeeId is treated
        as a collision, never as a match.
    #>
    [CmdletBinding()]
    param([string]$EmployeeId, [string]$UserPrincipalName, [switch]$IncludeManager, [switch]$NoCache)

    $cacheKey = "$EmployeeId|$UserPrincipalName|$([bool]$IncludeManager)"
    if (-not $NoCache -and $script:Jml.EntraCache.ContainsKey($cacheKey)) { return $script:Jml.EntraCache[$cacheKey] }

    if ($script:Jml.Provider -eq 'Simulated') {
        $result = Get-JmlSimEntraUser -EmployeeId $EmployeeId -UserPrincipalName $UserPrincipalName
        $script:Jml.EntraCache[$cacheKey] = $result
        return $result
    }

    $raw = $null
    if ($EmployeeId) {
        $filter = [uri]::EscapeDataString("employeeId eq '$($EmployeeId -replace "'", "''")'")
        $hits = Invoke-JmlGraph -Uri "users?`$filter=$filter&`$select=$script:JmlGraphUserSelect&`$count=true" -Headers @{ ConsistencyLevel = 'eventual' }
        $values = @($hits.value)
        if ($values.Count -gt 1) { throw "Anchor integrity violation: employeeId '$EmployeeId' is on $($values.Count) Entra users." }
        if ($values.Count -eq 1) { $raw = $values[0] }
    }
    if (-not $raw -and $UserPrincipalName) {
        $raw = Invoke-JmlGraph -Uri "users/$([uri]::EscapeDataString($UserPrincipalName))?`$select=$script:JmlGraphUserSelect" -AllowNotFound
        if ($raw -and $EmployeeId -and $raw.employeeId -and $raw.employeeId -ne $EmployeeId) {
            throw "UPN '$UserPrincipalName' belongs to employeeId '$($raw.employeeId)', not '$EmployeeId'. Refusing to match."
        }
    }
    if (-not $raw) { $script:Jml.EntraCache[$cacheKey] = $null; return $null }

    # memberOf also returns directory roles and administrative units; keep groups only.
    $groups = @(foreach ($m in (Get-JmlGraphPaged -Uri "users/$($raw.id)/memberOf?`$select=id,displayName")) { if ($m['@odata.type'] -eq '#microsoft.graph.group') { $m } })
    $managerId = $null
    if ($IncludeManager) {
        $mgr = Invoke-JmlGraph -Uri "users/$($raw.id)/manager?`$select=id" -AllowNotFound
        if ($mgr) { $managerId = $mgr.id }
    }
    $result = ConvertTo-JmlEntraUser -U $raw -GroupIds @($groups | ForEach-Object { $_.id }) -ManagerId $managerId
    $script:Jml.EntraCache[$cacheKey] = $result
    return $result
}

function Resolve-JmlEntraGroupMap {
    # Resolves every managed Entra group name to an object id once per run and
    # fails fast if the access model names a group that does not exist.
    [CmdletBinding()]
    param()
    $script:Jml.EntraGroupMap = @{}
    $script:Jml.EntraGroupById = @{}
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($name in (Get-JmlManagedGroups -System Entra)) {
        $id = $null
        if ($script:Jml.Provider -eq 'Simulated') {
            foreach ($k in $script:Jml.SimState.Entra.Groups.Keys) { if ($script:Jml.SimState.Entra.Groups[$k] -ieq $name) { $id = $k } }
        }
        else {
            $f = [uri]::EscapeDataString("displayName eq '$($name -replace "'", "''")'")
            $hits = @((Invoke-JmlGraph -Uri "groups?`$filter=$f&`$select=id,displayName").value)
            if ($hits.Count -gt 1) { throw "Entra group name '$name' is ambiguous ($($hits.Count) groups). Rename or use unique names." }
            if ($hits.Count -eq 1) { $id = $hits[0].id }
        }
        if ($id) { $script:Jml.EntraGroupMap[$name] = $id; $script:Jml.EntraGroupById[$id] = $name }
        else { $missing.Add($name) }
    }
    if ($missing.Count) { throw "Access model references Entra groups that do not exist: $($missing -join ', '). Run lab/05-New-MeridianEntraGroups.ps1." }
}

function Resolve-JmlEntraUserId {
    param([Parameter(Mandatory)][string]$UserRef)
    if ($UserRef -match '^[0-9a-fA-F-]{36}$') { return $UserRef }
    if ($script:Jml.Provider -eq 'Simulated') {
        foreach ($u in $script:Jml.SimState.Entra.Users.Values) { if ($u.UserPrincipalName -ieq $UserRef) { return $u.Id } }
        throw "Entra user '$UserRef' not found."
    }
    $u = Invoke-JmlGraph -Uri "users/$([uri]::EscapeDataString($UserRef))?`$select=id"
    return $u.id
}

function Test-JmlEntraUpnTaken {
    param([Parameter(Mandatory)][string]$UserPrincipalName)
    if ($script:Jml.Provider -eq 'Simulated') {
        foreach ($u in $script:Jml.SimState.Entra.Users.Values) { if ($u.UserPrincipalName -ieq $UserPrincipalName) { return $true } }
        return $false
    }
    return [bool](Invoke-JmlGraph -Uri "users/$([uri]::EscapeDataString($UserPrincipalName))?`$select=id" -AllowNotFound)
}

function Invoke-JmlEntraOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][hashtable]$Params
    )
    if ($script:Jml.Provider -eq 'Simulated') { return Invoke-JmlSimEntraOperation -Type $Type -Params $Params }

    switch ($Type) {
        'CreateUser' {
            $a = $Params.Attributes
            $body = @{
                accountEnabled    = [bool]$Params.Enabled
                userPrincipalName = $Params.Upn
                mailNickname      = $Params.MailNickname
                employeeId        = $Params.EmployeeId
                usageLocation     = $Params.UsageLocation
                passwordProfile   = @{
                    forceChangePasswordNextSignIn = $true
                    password                      = [System.Net.NetworkCredential]::new('', (New-JmlRandomPassword)).Password
                }
            }
            foreach ($k in $a.Keys) { if ($a[$k]) { $body[$k] = $a[$k] } }
            $created = Invoke-JmlGraph -Method POST -Uri 'users' -Body $body
            return $created.id
        }
        'DeleteUser' {
            [void](Invoke-JmlGraph -Method DELETE -Uri "users/$([uri]::EscapeDataString($Params.UserRef))" -AllowNotFound)
        }
        'SetAttributes' {
            $body = @{}
            foreach ($k in $Params.Changes.Keys) {
                $to = $Params.Changes[$k].To
                $body[$k] = if ([string]::IsNullOrEmpty([string]$to)) { $null } else { $to }
            }
            [void](Invoke-JmlGraph -Method PATCH -Uri "users/$(Resolve-JmlEntraUserId $Params.UserRef)" -Body $body)
        }
        'DisableUser' { [void](Invoke-JmlGraph -Method PATCH -Uri "users/$(Resolve-JmlEntraUserId $Params.UserRef)" -Body @{ accountEnabled = $false }) }
        'EnableUser' { [void](Invoke-JmlGraph -Method PATCH -Uri "users/$(Resolve-JmlEntraUserId $Params.UserRef)" -Body @{ accountEnabled = $true }) }
        'RevokeSessions' { [void](Invoke-JmlGraph -Method POST -Uri "users/$(Resolve-JmlEntraUserId $Params.UserRef)/revokeSignInSessions") }
        'SetManager' {
            $uid = Resolve-JmlEntraUserId $Params.UserRef
            [void](Invoke-JmlGraph -Method PUT -Uri "users/$uid/manager/`$ref" -Body @{ '@odata.id' = "https://graph.microsoft.com/v1.0/users/$($Params.ManagerId)" })
        }
        'ClearManager' {
            $uid = Resolve-JmlEntraUserId $Params.UserRef
            [void](Invoke-JmlGraph -Method DELETE -Uri "users/$uid/manager/`$ref" -AllowNotFound)
        }
        'AddGroupMember' {
            $uid = Resolve-JmlEntraUserId $Params.UserRef
            try {
                [void](Invoke-JmlGraph -Method POST -Uri "groups/$($Params.GroupId)/members/`$ref" -Body @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$uid" })
            }
            catch { if ($_.Exception.Message -notmatch 'already exist') { throw } }
        }
        'RemoveGroupMember' {
            $uid = Resolve-JmlEntraUserId $Params.UserRef
            [void](Invoke-JmlGraph -Method DELETE -Uri "groups/$($Params.GroupId)/members/$uid/`$ref" -AllowNotFound)
        }
        default { throw "Unknown Entra operation '$Type'." }
    }
}
