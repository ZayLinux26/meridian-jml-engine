# Core helpers: configuration, logging, access model, naming, secrets.

function Import-JmlConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { throw "Config file not found: $Path" }
    $configFile = (Resolve-Path -LiteralPath $Path).Path
    $configDir = Split-Path -Path $configFile -Parent
    $cfg = Import-PowerShellDataFile -LiteralPath $configFile

    foreach ($key in @('Organization', 'AD', 'Graph', 'Safety', 'Paths', 'AccessModelPath')) {
        if (-not $cfg.ContainsKey($key)) { throw "Config is missing required key '$key'." }
    }
    foreach ($key in @('BaseOU', 'UsersOU', 'DisabledOU', 'UpnSuffix')) {
        if ([string]::IsNullOrWhiteSpace($cfg.AD[$key])) { throw "Config AD.$key is required." }
    }

    # Relative paths resolve against the config file's folder so runs behave the
    # same from a scheduled task, a pipeline agent, or an interactive shell.
    $resolve = {
        param($p)
        if ([System.IO.Path]::IsPathRooted($p)) { return $p }
        return [System.IO.Path]::GetFullPath((Join-Path -Path $configDir -ChildPath $p))
    }
    $cfg.AccessModelPath = & $resolve $cfg.AccessModelPath
    foreach ($k in @($cfg.Paths.Keys)) { $cfg.Paths[$k] = & $resolve $cfg.Paths[$k] }

    if (-not (Test-Path -LiteralPath $cfg.AccessModelPath)) { throw "Access model not found: $($cfg.AccessModelPath)" }
    $accessModel = Get-Content -LiteralPath $cfg.AccessModelPath -Raw | ConvertFrom-Json -AsHashtable

    foreach ($section in @('Global', 'EmploymentType', 'Department', 'JobTitle')) {
        if (-not $accessModel.ContainsKey($section)) { $accessModel[$section] = @{} }
    }
    if (-not $cfg.Safety.ContainsKey('MaxLeaversPerRun')) { $cfg.Safety.MaxLeaversPerRun = 10 }
    if (-not $cfg.Safety.ContainsKey('MaxLeaverPercent')) { $cfg.Safety.MaxLeaverPercent = 25 }
    if (-not $cfg.Safety.ContainsKey('PreHireDays')) { $cfg.Safety.PreHireDays = 14 }

    [pscustomobject]@{ Config = $cfg; AccessModel = $accessModel }
}

function Initialize-JmlContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][hashtable]$AccessModel,
        [ValidateSet('Live', 'Simulated')][string]$Provider = 'Live',
        [string]$RunId,
        [switch]$Quiet
    )
    if (-not $RunId) {
        $RunId = '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 6))
    }
    foreach ($dir in $Config.Paths.Values) {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    }
    $script:Jml.Config = $Config
    $script:Jml.AccessModel = $AccessModel
    $script:Jml.Provider = $Provider
    $script:Jml.RunId = $RunId
    $script:Jml.LogFile = Join-Path -Path $Config.Paths.Logs -ChildPath "run-$RunId.jsonl"
    $script:Jml.FaultInjection = $null
    $script:Jml.EntraCache = @{}
    $script:Jml.Quiet = [bool]$Quiet
}

function Write-JmlLog {
    [CmdletBinding()]
    param(
        [ValidateSet('INFO', 'WARN', 'ERROR', 'AUDIT', 'DEBUG')][string]$Level = 'INFO',
        [Parameter(Mandatory)][string]$Message,
        [string]$EmployeeId,
        [string]$Action,
        [hashtable]$Data
    )
    $entry = [ordered]@{
        timestamp  = (Get-Date).ToUniversalTime().ToString('o')
        runId      = $script:Jml.RunId
        level      = $Level
        employeeId = $EmployeeId
        action     = $Action
        message    = $Message
    }
    if ($Data) { $entry.data = $Data }
    if ($script:Jml.LogFile) {
        ($entry | ConvertTo-Json -Compress -Depth 8) | Add-Content -LiteralPath $script:Jml.LogFile -Encoding utf8
    }
    if ($Level -eq 'DEBUG') { Write-Verbose $Message; return }
    if ($script:Jml.Quiet) { return }
    $color = switch ($Level) { 'WARN' { 'Yellow' } 'ERROR' { 'Red' } 'AUDIT' { 'DarkCyan' } default { 'Gray' } }
    $prefix = if ($EmployeeId) { "[$Level][$EmployeeId]" } else { "[$Level]" }
    Write-Host "$prefix $Message" -ForegroundColor $color
}

function Get-JmlLayer {
    # Case-insensitive lookup inside an access model section.
    param([hashtable]$Section, [string]$Key)
    if (-not $Section -or [string]::IsNullOrWhiteSpace($Key)) { return $null }
    foreach ($k in $Section.Keys) { if ($k -ieq $Key) { return $Section[$k] } }
    return $null
}

function Get-JmlDesiredGroups {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Record,
        [Parameter(Mandatory)][ValidateSet('AD', 'Entra')][string]$System
    )
    $am = $script:Jml.AccessModel
    $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $layers = @(
        $am.Global
        (Get-JmlLayer -Section $am.EmploymentType -Key $Record.EmploymentType)
        (Get-JmlLayer -Section $am.Department -Key $Record.Department)
        (Get-JmlLayer -Section $am.JobTitle -Key $Record.JobTitle)
    )
    foreach ($layer in $layers) {
        if ($layer -and $layer.ContainsKey($System)) {
            foreach ($g in @($layer[$System])) { if ($g) { [void]$set.Add([string]$g) } }
        }
    }
    return , ([string[]]@($set))
}

function Get-JmlManagedGroups {
    # Every group named anywhere in the access model. The engine only ever
    # removes memberships of groups it owns, so hand-granted or privileged
    # access is never silently stripped from an active worker.
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('AD', 'Entra')][string]$System, [hashtable]$AccessModel = $script:Jml.AccessModel)
    $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $layers = [System.Collections.Generic.List[object]]::new()
    $layers.Add($AccessModel.Global)
    foreach ($section in @('EmploymentType', 'Department', 'JobTitle')) {
        foreach ($v in $AccessModel[$section].Values) { $layers.Add($v) }
    }
    foreach ($layer in $layers) {
        if ($layer -and $layer.ContainsKey($System)) {
            foreach ($g in @($layer[$System])) { if ($g) { [void]$set.Add([string]$g) } }
        }
    }
    return , ([string[]]@($set))
}

function ConvertTo-JmlAsciiName {
    param([string]$Value)
    if (-not $Value) { return '' }
    $normalized = $Value.Normalize([Text.NormalizationForm]::FormD)
    $sb = [Text.StringBuilder]::new()
    foreach ($ch in $normalized.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($ch)
        }
    }
    return ($sb.ToString() -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
}

function New-JmlSamAccountName {
    # first initial + surname, 20 char AD limit, numeric suffix on collision.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GivenName,
        [Parameter(Mandatory)][string]$Surname,
        [string]$Prefix = '',
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]]$Reserved,
        [Parameter(Mandatory)][scriptblock]$IsTaken
    )
    $first = ConvertTo-JmlAsciiName $GivenName
    $last = ConvertTo-JmlAsciiName $Surname
    if (-not $first -or -not $last) { throw "Cannot derive an account name from '$GivenName $Surname'." }
    $base = "$Prefix$($first.Substring(0, 1))$last"
    for ($i = 1; $i -lt 100; $i++) {
        $suffix = if ($i -eq 1) { '' } else { [string]$i }
        $max = 20 - $suffix.Length
        $candidate = ($base.Substring(0, [Math]::Min($base.Length, $max))) + $suffix
        if ($Reserved.Contains($candidate)) { continue }
        if (& $IsTaken $candidate) { continue }
        [void]$Reserved.Add($candidate)
        return $candidate
    }
    throw "Could not find a free account name for '$GivenName $Surname'."
}

function New-JmlRandomPassword {
    # 24 chars, all four character classes. Generated at execution time, never
    # logged, never written to the journal. Onboarding uses a Temporary Access
    # Pass or a helpdesk reset, so nobody needs to see this value.
    [OutputType([securestring])]
    param([int]$Length = 24)
    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!@#$%^&*-_=+?')
    $all = -join $sets
    $chars = [System.Collections.Generic.List[char]]::new()
    foreach ($s in $sets) { $chars.Add($s[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($s.Length)]) }
    while ($chars.Count -lt $Length) { $chars.Add($all[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($all.Length)]) }
    $shuffled = $chars | Sort-Object { [System.Security.Cryptography.RandomNumberGenerator]::GetInt32([int]::MaxValue) }
    $secure = [securestring]::new()
    foreach ($c in $shuffled) { $secure.AppendChar($c) }
    $secure.MakeReadOnly()
    return $secure
}

function ConvertTo-JmlUtcDate {
    param($Value)
    if ($null -eq $Value -or ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value))) { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime }
    return [datetime]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)
}

function Test-JmlValueEqual {
    # Null and empty string are the same thing to a directory.
    param($A, $B, [switch]$CaseInsensitive)
    $a1 = if ($null -eq $A) { '' } else { ([string]$A).Trim() }
    $b1 = if ($null -eq $B) { '' } else { ([string]$B).Trim() }
    if ($CaseInsensitive) { return $a1 -ieq $b1 }
    return $a1 -ceq $b1
}

function Get-JmlParentContainer {
    param([string]$DistinguishedName)
    return ($DistinguishedName -replace '^.+?(?<!\\),', '')
}

function Get-JmlSha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}
