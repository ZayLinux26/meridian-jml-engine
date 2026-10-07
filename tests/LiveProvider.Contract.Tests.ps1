# Contract tests for the LIVE provider code path (AD module + Microsoft Graph).
#
# The real ActiveDirectory and Microsoft.Graph.Authentication modules are
# swapped for test doubles (tests/fakes) that behave like the real services on
# the points that matter: absent AD attributes, 404s from Graph, 400 on
# duplicate group adds, on-prem mastered objects rejecting cloud writes, and
# employeeId filters requiring ConsistencyLevel: eventual.

Describe 'Live provider contract (AD + Graph doubles)' {

    BeforeAll {
        $repo = Split-Path -Path $PSScriptRoot -Parent
        $script:oldModulePath = $env:PSModulePath
        $env:PSModulePath = (Join-Path $PSScriptRoot 'fakes') + [System.IO.Path]::PathSeparator + $env:PSModulePath
        Import-Module (Join-Path $repo 'src/MeridianJML/MeridianJML.psd1') -Force
        Import-Module Microsoft.Graph.Authentication -Force

        $work = Join-Path ([System.IO.Path]::GetTempPath()) ("jml-contract-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path (Join-Path $work 'config') -Force | Out-Null
        $cfgText = Get-Content (Join-Path $repo 'config/jml.config.example.psd1') -Raw
        $cfgText = $cfgText -replace 'CHANGEME-tenant-guid', '00000000-0000-0000-0000-00000000fake' -replace 'CHANGEME-app-client-id', '11111111-1111-1111-1111-11111111fake' -replace 'CHANGEME-thumbprint', 'ABCDEF'
        Set-Content -Path (Join-Path $work 'config/jml.config.psd1') -Value $cfgText
        Copy-Item (Join-Path $repo 'config/access-model.json') (Join-Path $work 'config/access-model.json')
        $script:cfgPath = Join-Path $work 'config/jml.config.psd1'
        $script:data = Join-Path $repo 'data'

        $am = Get-Content (Join-Path $repo 'config/access-model.json') -Raw | ConvertFrom-Json -AsHashtable
        $adGroups = @{}; $entraGroups = @{}
        foreach ($layer in @($am.Global) + @($am.EmploymentType.Values) + @($am.Department.Values) + @($am.JobTitle.Values)) {
            foreach ($gname in @($layer.AD)) { if ($gname) { $adGroups[$gname] = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase) } }
            foreach ($gname in @($layer.Entra)) {
                if ($gname) { $gid = [guid]::NewGuid().ToString(); $entraGroups[$gid] = @{ id = $gid; displayName = $gname; members = [System.Collections.Generic.HashSet[string]]::new() } }
            }
        }
        $global:FakeDir = @{
            GraphConnected = $false
            SimulateLag    = $true
            AD             = @{ Users = @{}; Groups = $adGroups }
            Graph          = @{ Users = @{}; Groups = $entraGroups; Calls = [System.Collections.Generic.List[string]]::new(); Lag = @{}; LagHits = 0 }
        }

        function Invoke-LiveRun {
            param([string]$Feed, [switch]$Apply, [string]$Fail, [string]$FailFor)
            $p = @{ ConfigPath = $script:cfgPath; FeedPath = (Join-Path $script:data $Feed); AsOfDate = [datetime]'2026-09-28'; Quiet = $true; PassThru = $true; Apply = $Apply }
            if ($Fail) { $p.SimulateFailure = $Fail; $p.SimulateFailureFor = $FailFor }
            Invoke-JmlRun @p
        }
        function Get-Ops { param($r) ($r.Items | Group-Object Operation | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' ' }
    }

    AfterAll {
        $env:PSModulePath = $script:oldModulePath
        Remove-Module MeridianJML, ActiveDirectory, Microsoft.Graph.Authentication -Force -ErrorAction SilentlyContinue
        Remove-Variable -Name FakeDir -Scope Global -ErrorAction SilentlyContinue
    }

    It 'connects app-only and provisions day one through New-ADUser and POST /users' {
        $r = Invoke-LiveRun -Feed 'hr-feed-day1-joiners.csv' -Apply
        @($r.Items | Where-Object Result -ne 'Completed').Count | Should -Be 0
        $global:FakeDir.AD.Users.Count | Should -Be 11
        @($global:FakeDir.Graph.Users.Values).Count | Should -Be 2
        $global:FakeDir.AD.Users['esokolova'].Manager | Should -Match '^CN=Marcus Bell,'
        $global:FakeDir.AD.Groups['GG-MFG-Treasury-WireRelease'].Contains('esokolova') | Should -BeTrue
    }

    It 'rides out Entra replication lag on just-created cloud users instead of rolling back' {
        $global:FakeDir.Graph.LagHits | Should -BeGreaterThan 0
        $nora = $global:FakeDir.Graph.Users.Values | Where-Object employeeId -eq 'C2001'
        $nora | Should -Not -BeNullOrEmpty
        @($global:FakeDir.Graph.Groups.Values | Where-Object { $_.members.Contains($nora.id) }).Count | Should -Be 3
    }

    It 'queries employeeId with ConsistencyLevel eventual and converges after Cloud Sync' {
        Invoke-FakeCloudSync
        $r = Invoke-LiveRun -Feed 'hr-feed-day1-joiners.csv' -Apply
        Get-Ops $r | Should -Be 'Mover=2 Reconcile=11'
        @($r.Items | Where-Object Result -ne 'Completed').Count | Should -Be 0
        $r3 = Invoke-LiveRun -Feed 'hr-feed-day1-joiners.csv'
        Get-Ops $r3 | Should -Be 'NoChange=13'
    }

    It 'moves, renames nothing it should not, and strips old entitlements' {
        $r = Invoke-LiveRun -Feed 'hr-feed-day2-movers.csv' -Apply
        @($r.Items | Where-Object { $_.Result -notin @('Completed', 'NoAction') }).Count | Should -Be 0
        $u = $global:FakeDir.AD.Users['esokolova']
        $u.DistinguishedName | Should -Match '^CN=Elena Sokolova,OU=Compliance,OU=Users'
        $u.Title | Should -Be 'Risk Analyst'
        $global:FakeDir.AD.Groups['GG-MFG-Treasury-WireRelease'].Contains('esokolova') | Should -BeFalse
        Invoke-FakeCloudSync
        [void](Invoke-LiveRun -Feed 'hr-feed-day2-movers.csv' -Apply)
        Get-Ops (Invoke-LiveRun -Feed 'hr-feed-day2-movers.csv') | Should -Be 'Deferred=1 NoChange=14'
    }

    It 'contains a leaver with Disable-ADAccount and revokeSignInSessions despite a cleanup fault' {
        $r = Invoke-LiveRun -Feed 'hr-feed-day3-leavers.csv' -Apply -Fail 'AD.MoveUser' -FailFor '100008'
        ($r.Items | Where-Object EmployeeId -eq '100008').Result | Should -Be 'Contained'
        $global:FakeDir.AD.Users['tbrennan'].Enabled | Should -BeFalse
        @($global:FakeDir.Graph.Calls | Where-Object { $_ -like 'POST*revokeSignInSessions' }).Count | Should -BeGreaterThan 0
        ($r.Items | Where-Object EmployeeId -eq 'C2002').Result | Should -Be 'Completed'
    }

    It 'finishes the leaver on the next run and is then idempotent' {
        Invoke-FakeCloudSync
        $r = Invoke-LiveRun -Feed 'hr-feed-day3-leavers.csv' -Apply
        ($r.Items | Where-Object EmployeeId -eq '100008').Result | Should -Be 'Completed'
        $global:FakeDir.AD.Users['tbrennan'].DistinguishedName | Should -Match 'OU=Disabled Users'
        $global:FakeDir.AD.Users['tbrennan'].Description | Should -Match '^Terminated 2026-09-25'
        Invoke-FakeCloudSync
        Get-Ops (Invoke-LiveRun -Feed 'hr-feed-day3-leavers.csv') | Should -Be 'Deferred=1 NoChange=14'
    }

    It 'never writes to on-prem mastered attributes through Graph' {
        $synced = @($global:FakeDir.Graph.Users.Values | Where-Object onPremisesSyncEnabled | ForEach-Object id)
        $bad = @($global:FakeDir.Graph.Calls | Where-Object { $c = $_; $c -like 'PATCH*' -and ($synced | Where-Object { $c -like "*$_*" }) })
        $bad.Count | Should -Be 0
    }
}
