function Import-JmlHrFeed {
    <#
    .SYNOPSIS
        Loads and validates an HR snapshot feed (CSV).
    .DESCRIPTION
        Every row is validated before anything touches a directory. Rows that fail
        validation are rejected and reported, never partially processed. Duplicate
        EmployeeIds reject every copy, because guessing which row HR meant is how
        the wrong person gets access.
    .OUTPUTS
        PSCustomObject with Records, Rejected and Sha256.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$AccessModel = $script:Jml.AccessModel
    )
    if (-not (Test-Path -LiteralPath $Path)) { throw "HR feed not found: $Path" }
    $required = @('EmployeeId', 'GivenName', 'Surname', 'Department', 'JobTitle', 'ManagerId', 'Office', 'EmploymentType', 'Status', 'EffectiveDate')
    $rows = @(Import-Csv -LiteralPath $Path)
    if ($rows.Count -eq 0) { throw 'HR feed is empty. Refusing to run against an empty snapshot.' }

    $columns = $rows[0].PSObject.Properties.Name
    $missing = @($required | Where-Object { $_ -notin $columns })
    if ($missing.Count) { throw "HR feed is missing required columns: $($missing -join ', ')" }

    $dupes = @($rows | Group-Object EmployeeId | Where-Object Count -gt 1 | ForEach-Object Name)
    $records = [System.Collections.Generic.List[object]]::new()
    $rejected = [System.Collections.Generic.List[object]]::new()
    $line = 1

    foreach ($row in $rows) {
        $line++
        $errors = [System.Collections.Generic.List[string]]::new()
        $get = { param($n) ([string]$row.$n).Trim() }

        $id = & $get 'EmployeeId'
        if ($id -notmatch '^[A-Za-z0-9-]{3,16}$') { $errors.Add("EmployeeId '$id' is not a valid identifier") }
        if ($id -in $dupes) { $errors.Add("EmployeeId '$id' appears more than once in the feed") }
        foreach ($n in @('GivenName', 'Surname', 'Department', 'JobTitle')) {
            if (-not (& $get $n)) { $errors.Add("$n is empty") }
        }
        $status = & $get 'Status'
        if ($status -notin @('Active', 'Terminated')) { $errors.Add("Status '$status' must be Active or Terminated") }
        $etype = & $get 'EmploymentType'
        if ($etype -notin @('Employee', 'Contractor')) { $errors.Add("EmploymentType '$etype' must be Employee or Contractor") }
        $dept = & $get 'Department'
        if ($AccessModel -and $dept -and -not (Get-JmlLayer -Section $AccessModel.Department -Key $dept)) {
            $errors.Add("Department '$dept' has no entry in the access model")
        }
        $effective = [datetime]::MinValue
        $okDate = [datetime]::TryParseExact((& $get 'EffectiveDate'), 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$effective)
        if (-not $okDate) { $errors.Add("EffectiveDate '$(& $get 'EffectiveDate')' must be yyyy-MM-dd") }
        $mgr = & $get 'ManagerId'
        if ($mgr -and $mgr -eq $id) { $errors.Add('Worker cannot be their own manager') }

        if ($errors.Count) {
            $rejected.Add([pscustomobject]@{ Line = $line; EmployeeId = $id; Reasons = ($errors -join '; ') })
            continue
        }
        $given = & $get 'GivenName'
        $sur = & $get 'Surname'
        $records.Add([pscustomobject]@{
                EmployeeId     = $id
                GivenName      = $given
                Surname        = $sur
                DisplayName    = "$given $sur"
                Department     = $dept
                JobTitle       = & $get 'JobTitle'
                ManagerId      = $mgr
                Office         = & $get 'Office'
                EmploymentType = $etype
                IdentityType   = if ($etype -eq 'Contractor') { 'CloudOnly' } else { 'Hybrid' }
                Status         = $status
                EffectiveDate  = $effective.Date
            })
    }
    [pscustomobject]@{
        Records  = $records.ToArray()
        Rejected = $rejected.ToArray()
        Sha256   = Get-JmlSha256 -Path $Path
    }
}
