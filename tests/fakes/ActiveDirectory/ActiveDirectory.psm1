# Test double for the ActiveDirectory module. Implements only the cmdlets and
# parameters the JML engine uses, backed by $global:FakeDir.AD, so the live
# provider code path can be exercised on any OS in CI.

$script:Map = @{ givenname = 'GivenName'; sn = 'Surname'; displayname = 'DisplayName'; department = 'Department'; title = 'Title'
    physicaldeliveryofficename = 'Office'; manager = 'Manager'; description = 'Description'; employeetype = 'employeeType' }

function Get-Store { if (-not $global:FakeDir) { throw 'FakeDir not initialised' }; $global:FakeDir.AD }

function Find-FakeUser {
    param($Identity)
    $s = Get-Store
    if ($s.Users.ContainsKey([string]$Identity)) { return $s.Users[[string]$Identity] }
    foreach ($u in $s.Users.Values) { if ($u.DistinguishedName -ieq [string]$Identity) { return $u } }
    throw "Cannot find an object with identity: '$Identity' under: 'DC=meridianfg,DC=internal'."
}

function ConvertTo-FakeAdObject {
    param($u)
    $o = [ordered]@{
        SamAccountName = $u.SamAccountName; DistinguishedName = $u.DistinguishedName; Enabled = $u.Enabled
        UserPrincipalName = $u.UserPrincipalName; GivenName = $u.GivenName; Surname = $u.Surname
    }
    # Like the real module, unset optional attributes are simply absent.
    foreach ($k in @('EmployeeID', 'employeeType', 'DisplayName', 'Department', 'Title', 'Office', 'Manager', 'Description')) {
        if ($u[$k]) { $o[$k] = $u[$k] }
    }
    $groups = @((Get-Store).Groups.Keys | Where-Object { (Get-Store).Groups[$_].Contains($u.SamAccountName) } | ForEach-Object { "CN=$_,OU=Groups,OU=Meridian,DC=meridianfg,DC=internal" })
    if ($groups.Count) { $o.MemberOf = $groups }
    [pscustomobject]$o
}

function Get-ADUser {
    [CmdletBinding()]
    param([Parameter(Position = 0)]$Identity, [string]$LDAPFilter, [string]$Filter, [string]$SearchBase, [string]$SearchScope, [string[]]$Properties, [string]$Server)
    $s = Get-Store
    if ($Identity) { return ConvertTo-FakeAdObject (Find-FakeUser $Identity) }
    if ($LDAPFilter -eq '(employeeID=*)') {
        return @($s.Users.Values | Where-Object { $_.EmployeeID -and $_.DistinguishedName.EndsWith($SearchBase, [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { ConvertTo-FakeAdObject $_ })
    }
    if ($LDAPFilter -match '^\(\|\(sAMAccountName=(.+?)\)\(userPrincipalName=(.+?)\)\)$') {
        $sam = $Matches[1]; $upn = $Matches[2]
        return @($s.Users.Values | Where-Object { $_.SamAccountName -ieq $sam -or $_.UserPrincipalName -ieq $upn } | ForEach-Object { ConvertTo-FakeAdObject $_ })
    }
    throw "Fake Get-ADUser does not support filter '$LDAPFilter$Filter'"
}

function New-ADUser {
    [CmdletBinding()]
    param($Name, $SamAccountName, $UserPrincipalName, $Path, $GivenName, $Surname, $DisplayName, $Department, $Title, $Office, $Manager,
        [securestring]$AccountPassword, [bool]$ChangePasswordAtLogon, [bool]$Enabled, [hashtable]$OtherAttributes, $Server)
    $s = Get-Store
    if ($s.Users.ContainsKey($SamAccountName)) { throw 'The specified account already exists' }
    if (-not $AccountPassword) { throw 'Password required by fake' }
    if ($Manager) { [void](Find-FakeUser $Manager) }
    $s.Users[$SamAccountName] = @{
        SamAccountName = $SamAccountName; DistinguishedName = "CN=$Name,$Path"; Enabled = $Enabled; UserPrincipalName = $UserPrincipalName
        GivenName = $GivenName; Surname = $Surname; DisplayName = $DisplayName; Department = $Department; Title = $Title; Office = $Office
        Manager = $Manager; Description = $null; EmployeeID = $OtherAttributes.employeeID; employeeType = $OtherAttributes.employeeType
    }
}

function Set-ADUser {
    [CmdletBinding()]
    param([Parameter(Position = 0)]$Identity, [hashtable]$Replace, [string[]]$Clear, $Server)
    $u = Find-FakeUser $Identity
    if ($Replace) { foreach ($k in $Replace.Keys) { $u[$script:Map[$k.ToLower()]] = $Replace[$k] } }
    foreach ($k in @($Clear)) { if ($k) { $u[$script:Map[$k.ToLower()]] = $null } }
}

function Rename-ADObject { [CmdletBinding()] param($Identity, $NewName, $Server)
    $u = Find-FakeUser $Identity
    $u.DistinguishedName = "CN=$NewName," + ($u.DistinguishedName -replace '^.+?(?<!\\),', '')
}
function Move-ADObject { [CmdletBinding()] param($Identity, $TargetPath, $Server)
    $u = Find-FakeUser $Identity
    $u.DistinguishedName = (($u.DistinguishedName -split '(?<!\\),', 2)[0]) + ",$TargetPath"
}
function Add-ADGroupMember { [CmdletBinding()] param($Identity, $Members, $Server)
    $g = (Get-Store).Groups[$Identity]; if ($null -eq $g) { throw "Cannot find an object with identity: '$Identity'" }
    [void](Find-FakeUser $Members); [void]$g.Add($Members)
}
function Remove-ADGroupMember { [CmdletBinding(SupportsShouldProcess)] param($Identity, $Members, $Server)
    $g = (Get-Store).Groups[$Identity]; if ($null -eq $g) { throw "Cannot find an object with identity: '$Identity'" }
    [void]$g.Remove($Members)
}
function Disable-ADAccount { [CmdletBinding()] param($Identity, $Server) (Find-FakeUser $Identity).Enabled = $false }
function Enable-ADAccount { [CmdletBinding()] param($Identity, $Server) (Find-FakeUser $Identity).Enabled = $true }
function Set-ADAccountPassword { [CmdletBinding()] param($Identity, [switch]$Reset, [securestring]$NewPassword, $Server)
    if (-not $NewPassword) { throw 'no password' }; (Find-FakeUser $Identity).PwdLastSet = Get-Date
}
function Remove-ADUser { [CmdletBinding(SupportsShouldProcess)] param($Identity, $Server)
    $u = Find-FakeUser $Identity
    foreach ($g in (Get-Store).Groups.Values) { [void]$g.Remove($u.SamAccountName) }
    [void](Get-Store).Users.Remove($u.SamAccountName)
}

Export-ModuleMember -Function Get-ADUser, New-ADUser, Set-ADUser, Rename-ADObject, Move-ADObject, Add-ADGroupMember, Remove-ADGroupMember, Disable-ADAccount, Enable-ADAccount, Set-ADAccountPassword, Remove-ADUser
