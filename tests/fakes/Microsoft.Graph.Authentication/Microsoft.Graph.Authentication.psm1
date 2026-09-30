# Test double for Microsoft.Graph.Authentication. Emulates the Graph v1.0
# endpoints the JML engine calls, backed by $global:FakeDir.Graph, including
# 404s shaped like the real SDK's HttpResponseException (.Response.StatusCode).

class FakeGraphHttpException : System.Exception {
    [object]$Response
    FakeGraphHttpException([string]$message, [int]$code) : base($message) {
        $this.Response = [pscustomobject]@{ StatusCode = $code }
    }
}

$script:Select = @('id', 'userPrincipalName', 'accountEnabled', 'onPremisesSyncEnabled', 'employeeId', 'employeeType', 'givenName', 'surname', 'displayName', 'department', 'jobTitle', 'officeLocation', 'signInSessionsValidFromDateTime')

function Get-MgContext {
    if ($global:FakeDir -and $global:FakeDir.GraphConnected) {
        return [pscustomobject]@{ TenantId = '00000000-0000-0000-0000-00000000fake'; ClientId = '11111111-1111-1111-1111-11111111fake'; AuthType = 'AppOnly' }
    }
    return $null
}

function Connect-MgGraph {
    [CmdletBinding()] param($TenantId, $ClientId, $CertificateThumbprint, [switch]$NoWelcome)
    $global:FakeDir.GraphConnected = $true
}

function Get-FakeGraphUser {
    param([string]$Ref)
    $users = $global:FakeDir.Graph.Users
    if ($users.ContainsKey($Ref)) { return $users[$Ref] }
    foreach ($u in $users.Values) { if ($u.userPrincipalName -ieq $Ref) { return $u } }
    throw [FakeGraphHttpException]::new("Resource '$Ref' does not exist or one of its queried reference-property objects are not present.", 404)
}

function ConvertTo-FakeUserView { param($u) $h = @{}; foreach ($k in $script:Select) { $h[$k] = $u[$k] }; $h }

function Invoke-MgGraphRequest {
    [CmdletBinding()]
    param([string]$Method = 'GET', [string]$Uri, [hashtable]$Headers, $Body, [string]$ContentType, [string]$OutputType)
    $g = $global:FakeDir.Graph
    $g.Calls.Add("$Method $Uri")
    $path = [uri]::UnescapeDataString(($Uri -replace '^https://graph.microsoft.com/v1.0/', ''))
    $data = if ($Body) { $Body | ConvertFrom-Json -AsHashtable } else { $null }
    $route = ($path -split '\?', 2)[0]

    switch -Regex ("$Method $route") {
        '^GET users$' {
            if ($path -notmatch "employeeId eq '([^']+)'") { throw 'fake: unsupported users query' }
            if ($Headers.ConsistencyLevel -ne 'eventual') { throw [FakeGraphHttpException]::new('Request_UnsupportedQuery: employeeId filter needs ConsistencyLevel eventual', 400) }
            $id = $Matches[1]
            return @{ value = @($g.Users.Values | Where-Object { $_.employeeId -eq $id } | ForEach-Object { ConvertTo-FakeUserView $_ }) }
        }
        '^GET groups$' {
            if ($path -notmatch "displayName eq '([^']+)'") { throw 'fake: unsupported groups query' }
            $n = $Matches[1]
            return @{ value = @($g.Groups.Values | Where-Object { $_.displayName -eq $n } | ForEach-Object { @{ id = $_.id; displayName = $_.displayName } }) }
        }
        '^GET users/([^/]+)/memberOf$' {
            $u = Get-FakeGraphUser $Matches[1]
            $vals = @($g.Groups.Values | Where-Object { $_.members.Contains($u.id) } | ForEach-Object { @{ '@odata.type' = '#microsoft.graph.group'; id = $_.id; displayName = $_.displayName } })
            $vals += @{ '@odata.type' = '#microsoft.graph.directoryRole'; id = 'role-1'; displayName = 'Fake Role' }
            return @{ value = $vals }
        }
        '^GET users/([^/]+)/manager$' {
            $u = Get-FakeGraphUser $Matches[1]
            if (-not $u.managerId) { throw [FakeGraphHttpException]::new('Resource manager does not exist', 404) }
            return @{ id = $u.managerId }
        }
        '^GET users/([^/]+)$' { return (ConvertTo-FakeUserView (Get-FakeGraphUser $Matches[1])) }
        '^POST users$' {
            foreach ($u in $g.Users.Values) { if ($u.userPrincipalName -ieq $data.userPrincipalName) { throw [FakeGraphHttpException]::new('Another object with the same value for property userPrincipalName already exists.', 400) } }
            if (-not $data.passwordProfile.password) { throw [FakeGraphHttpException]::new('password required', 400) }
            $id = [guid]::NewGuid().ToString()
            $u = @{ id = $id; onPremisesSyncEnabled = $null; signInSessionsValidFromDateTime = (Get-Date).ToUniversalTime().ToString('o'); managerId = $null }
            foreach ($k in $data.Keys) { if ($k -ne 'passwordProfile') { $u[$k] = $data[$k] } }
            $g.Users[$id] = $u
            return (ConvertTo-FakeUserView $u)
        }
        '^PATCH users/([^/]+)$' {
            $u = Get-FakeGraphUser $Matches[1]
            if ($u.onPremisesSyncEnabled) { throw [FakeGraphHttpException]::new('Unable to update the specified properties for on-premises mastered Directory Sync objects', 400) }
            foreach ($k in $data.Keys) { $u[$k] = $data[$k] }
            return $null
        }
        '^DELETE users/([^/]+)$' { $u = Get-FakeGraphUser $Matches[1]; [void]$g.Users.Remove($u.id); return $null }
        '^POST users/([^/]+)/revokeSignInSessions$' {
            (Get-FakeGraphUser $Matches[1]).signInSessionsValidFromDateTime = (Get-Date).ToUniversalTime().ToString('o'); return @{ value = $true }
        }
        '^PUT users/([^/]+)/manager/\$ref$' {
            $u = Get-FakeGraphUser $Matches[1]
            $mid = ($data.'@odata.id' -split '/')[-1]; [void](Get-FakeGraphUser $mid); $u.managerId = $mid; return $null
        }
        '^DELETE users/([^/]+)/manager/\$ref$' {
            $u = Get-FakeGraphUser $Matches[1]
            if (-not $u.managerId) { throw [FakeGraphHttpException]::new('no manager', 404) }
            $u.managerId = $null; return $null
        }
        '^POST groups/([^/]+)/members/\$ref$' {
            $grp = $g.Groups[$Matches[1]]; if (-not $grp) { throw [FakeGraphHttpException]::new('group not found', 404) }
            $uid = ($data.'@odata.id' -split '/')[-1]
            if ($grp.members.Contains($uid)) { throw [FakeGraphHttpException]::new('One or more added object references already exist for the following modified properties: members.', 400) }
            [void]$grp.members.Add($uid); return $null
        }
        '^DELETE groups/([^/]+)/members/([^/]+)/\$ref$' {
            $grp = $g.Groups[$Matches[1]]
            if (-not $grp.members.Contains($Matches[2])) { throw [FakeGraphHttpException]::new('member not found', 404) }
            [void]$grp.members.Remove($Matches[2]); return $null
        }
        default { throw "fake Graph: unsupported $Method $path" }
    }
}

function Invoke-FakeCloudSync {
    # One Cloud Sync cycle from the fake AD into the fake Entra.
    $ad = $global:FakeDir.AD; $g = $global:FakeDir.Graph
    foreach ($u in $ad.Users.Values) {
        $e = $g.Users.Values | Where-Object { $_.onPremisesSyncEnabled -and $_.onPremSam -eq $u.SamAccountName } | Select-Object -First 1
        if (-not $e) {
            $id = [guid]::NewGuid().ToString()
            $e = @{ id = $id; onPremisesSyncEnabled = $true; onPremSam = $u.SamAccountName; signInSessionsValidFromDateTime = (Get-Date).AddDays(-30).ToUniversalTime().ToString('o') }
            $g.Users[$id] = $e
        }
        $e.userPrincipalName = $u.UserPrincipalName; $e.accountEnabled = $u.Enabled; $e.employeeId = $u.EmployeeID
        $e.givenName = $u.GivenName; $e.surname = $u.Surname; $e.displayName = $u.DisplayName; $e.department = $u.Department
        $e.jobTitle = $u.Title; $e.officeLocation = $u.Office; $e.employeeType = $u.employeeType
        $mgr = if ($u.Manager) { $ad.Users.Values | Where-Object DistinguishedName -eq $u.Manager | Select-Object -First 1 }
        $e.managerId = if ($mgr) { ($g.Users.Values | Where-Object { $_.onPremSam -eq $mgr.SamAccountName } | Select-Object -First 1).id } else { $null }
    }
    foreach ($e in @($g.Users.Values | Where-Object onPremisesSyncEnabled)) {
        if (-not $ad.Users.ContainsKey($e.onPremSam)) { [void]$g.Users.Remove($e.id) }
    }
}

Export-ModuleMember -Function Get-MgContext, Connect-MgGraph, Invoke-MgGraphRequest, Invoke-FakeCloudSync
