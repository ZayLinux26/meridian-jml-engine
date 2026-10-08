# Pester tests for the JML engine, run against the simulated directory provider.
# Compatible with Pester 5 (CI) and Pester 4.10+.
#   Invoke-Pester ./tests

Describe 'Meridian JML engine' {

    BeforeAll {
        $repo = Split-Path -Path $PSScriptRoot -Parent
        Import-Module (Join-Path $repo 'src/MeridianJML/MeridianJML.psd1') -Force

        $work = Join-Path ([System.IO.Path]::GetTempPath()) ("jml-tests-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path (Join-Path $work 'config') -Force | Out-Null
        Copy-Item (Join-Path $repo 'config/jml.config.example.psd1') (Join-Path $work 'config/jml.config.psd1')
        Copy-Item (Join-Path $repo 'config/access-model.json') (Join-Path $work 'config/access-model.json')

        $script:cfgPath = Join-Path $work 'config/jml.config.psd1'
        $script:data = Join-Path $repo 'data'
        $script:simPath = Join-Path $work 'output/simulation/sim-state.json'
        $script:asOf = [datetime]'2026-09-28'

        function Invoke-TestRun {
            param([string]$Feed, [switch]$Apply, [string]$Fail, [string]$FailFor)
            $p = @{
                ConfigPath = $script:cfgPath; FeedPath = (Join-Path $script:data $Feed); Simulated = $true
                AsOfDate = $script:asOf; Quiet = $true; PassThru = $true; Apply = $Apply
            }
            if ($Fail) { $p.SimulateFailure = $Fail; $p.SimulateFailureFor = $FailFor }
            Invoke-JmlRun @p
        }
        function Get-SimState { Get-Content -LiteralPath $script:simPath -Raw | ConvertFrom-Json -AsHashtable }
        function Get-Item100 { param($Run, $Id) $Run.Items | Where-Object EmployeeId -eq $Id }
    }

    AfterAll {
        Remove-Module MeridianJML -Force -ErrorAction SilentlyContinue
    }

    Context 'HR feed validation' {
        It 'rejects bad rows and every copy of a duplicated EmployeeId' {
            $am = Get-Content (Join-Path (Split-Path $script:cfgPath) 'access-model.json') -Raw | ConvertFrom-Json -AsHashtable
            $feed = Import-JmlHrFeed -Path (Join-Path $script:data 'hr-feed-invalid-rows.csv') -AccessModel $am
            @($feed.Records).Count | Should -Be 2
            @($feed.Rejected).Count | Should -Be 5
            ($feed.Rejected | Where-Object EmployeeId -eq '100002').Count | Should -Be 2
            ($feed.Rejected | Where-Object EmployeeId -eq '100014').Reasons | Should -Match 'Marketing'
            $feed.Sha256 | Should -Match '^[0-9A-F]{64}$'
        }
    }

    Context 'Joiners and idempotency' {
        It 'provisions every day-one worker' {
            $r = Invoke-TestRun -Feed 'hr-feed-day1-joiners.csv' -Apply
            @($r.Items | Where-Object Operation -eq 'Joiner').Count | Should -Be 13
            @($r.Items | Where-Object Result -ne 'Completed').Count | Should -Be 0
        }
        It 'sets managers created in the same run (manager-first ordering)' {
            $s = Get-SimState
            $s.AD.Users['praman'].Attributes.manager | Should -Match '^CN=Marcus Bell,'
        }
        It 'converges cloud group membership once Cloud Sync has created the objects' {
            $r = Invoke-TestRun -Feed 'hr-feed-day1-joiners.csv' -Apply
            @($r.Items | Where-Object Operation -eq 'Joiner').Count | Should -Be 0
            @($r.Items | Where-Object Operation -eq 'Reconcile').Count | Should -Be 11
        }
        It 'plans nothing on a third run over the same feed' {
            $r = Invoke-TestRun -Feed 'hr-feed-day1-joiners.csv'
            @($r.Items | Where-Object Operation -ne 'NoChange').Count | Should -Be 0
            ($r.Items | ForEach-Object { $_.Actions.Count } | Measure-Object -Sum).Sum | Should -Be 0
        }
        It 'never creates duplicate accounts when applied repeatedly' {
            [void](Invoke-TestRun -Feed 'hr-feed-day1-joiners.csv' -Apply)
            $s = Get-SimState
            $s.AD.Users.Count | Should -Be 11
            @($s.Entra.Users.Values | Where-Object { -not $_.OnPremisesSyncEnabled }).Count | Should -Be 2
        }
        It 'removes hand-added access to a managed group (drift remediation)' {
            $s = Get-SimState
            $s.AD.Users['hlee'].Groups = @($s.AD.Users['hlee'].Groups) + 'GG-MFG-HR'
            $s | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:simPath
            $r = Invoke-TestRun -Feed 'hr-feed-day1-joiners.csv' -Apply
            $i = Get-Item100 $r '100005'
            $i.Operation | Should -Be 'Reconcile'
            $i.Actions[0].Key | Should -Be 'AD.RemoveGroupMember'
            (Get-SimState).AD.Users['hlee'].Groups | Should -Not -Contain 'GG-MFG-HR'
        }
    }

    Context 'Movers, rollback and pre-hire' {
        It 'rolls a failed joiner back to nothing' {
            $r = Invoke-TestRun -Feed 'hr-feed-day2-movers.csv' -Apply -Fail 'AD.AddGroupMember' -FailFor '100012'
            (Get-Item100 $r '100012').Result | Should -Be 'RolledBack'
            (Get-Item100 $r '100012').Actions[0].Status | Should -Be 'Compensated'
            (Get-SimState).AD.Users.ContainsKey('mchen') | Should -BeFalse
        }
        It 'still completes the other identities in that run' {
            (Get-SimState).AD.Users['esokolova'].Attributes.department | Should -Be 'Compliance'
        }
        It 'strips old-department and SoD-sensitive access from a mover' {
            $u = (Get-SimState).AD.Users['esokolova']
            $u.Groups | Should -Contain 'GG-MFG-Compliance'
            $u.Groups | Should -Not -Contain 'GG-MFG-Finance'
            $u.Groups | Should -Not -Contain 'GG-MFG-Treasury-WireRelease'
            $u.DistinguishedName | Should -Match 'OU=Compliance,OU=Users'
        }
        It 'provisions the rolled-back joiner cleanly on the next run' {
            $r = Invoke-TestRun -Feed 'hr-feed-day2-movers.csv' -Apply
            (Get-Item100 $r '100012').Result | Should -Be 'Completed'
            (Get-SimState).AD.Users.ContainsKey('mchen') | Should -BeTrue
        }
        It 'defers a start date outside the pre-hire window' {
            $r = Invoke-TestRun -Feed 'hr-feed-day2-movers.csv'
            (Get-Item100 $r '100013').Operation | Should -Be 'Deferred'
        }
    }

    Context 'Leavers' {
        It 'contains access even when cleanup fails, and holds the commit stamp' {
            [void](Invoke-TestRun -Feed 'hr-feed-day2-movers.csv' -Apply)   # converge Entra groups first
            $r = Invoke-TestRun -Feed 'hr-feed-day3-leavers.csv' -Apply -Fail 'AD.MoveUser' -FailFor '100008'
            $i = Get-Item100 $r '100008'
            $i.Result | Should -Be 'Contained'
            ($i.Actions | Where-Object Key -eq 'AD.DisableUser').Status | Should -Be 'Succeeded'
            ($i.Actions | Where-Object Key -eq 'Entra.RevokeSessions').Status | Should -Be 'Succeeded'
            ($i.Actions | Where-Object Commit).Status | Should -Be 'Skipped'
            $u = (Get-SimState).AD.Users['tbrennan']
            $u.Enabled | Should -BeFalse
            @($u.Groups).Count | Should -Be 0
        }
        It 'finishes the leaver on the next run and then goes quiet' {
            $r = Invoke-TestRun -Feed 'hr-feed-day3-leavers.csv' -Apply
            (Get-Item100 $r '100008').Result | Should -Be 'Completed'
            $u = (Get-SimState).AD.Users['tbrennan']
            $u.DistinguishedName | Should -Match 'OU=Disabled Users'
            $u.Attributes.description | Should -Match '^Terminated 2026-09-25'
            $r2 = Invoke-TestRun -Feed 'hr-feed-day3-leavers.csv'
            (Get-Item100 $r2 '100008').Operation | Should -Be 'NoChange'
        }
        It 'deprovisions a cloud-only contractor through Graph' {
            $c = (Get-SimState).Entra.Users.Values | Where-Object EmployeeId -eq 'C2002'
            $c.AccountEnabled | Should -BeFalse
            @($c.Groups).Count | Should -Be 0
        }
        It 'withholds containment cleanup when a critical step fails, so it is retried' {
            # Re-enable the contractor by hand to simulate drift, then fail the revoke.
            $s = Get-SimState
            $c = $s.Entra.Users.Values | Where-Object EmployeeId -eq 'C2002'
            $c.AccountEnabled = $true
            $c.Groups = @($s.Entra.Groups.Keys | Select-Object -First 1)
            $s | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:simPath
            $r = Invoke-TestRun -Feed 'hr-feed-day3-leavers.csv' -Apply -Fail 'Entra.RevokeSessions' -FailFor 'C2002'
            $i = Get-Item100 $r 'C2002'
            $i.Result | Should -Be 'ContainmentFailed'
            ($i.Actions | Where-Object Key -eq 'Entra.DisableUser').Status | Should -Be 'Succeeded'
            ($i.Actions | Where-Object Key -eq 'Entra.RemoveGroupMember').Status | Should -Be 'Skipped'
            $r2 = Invoke-TestRun -Feed 'hr-feed-day3-leavers.csv'
            (Get-Item100 $r2 'C2002').Actions.Key | Should -Contain 'Entra.RevokeSessions'
            [void](Invoke-TestRun -Feed 'hr-feed-day3-leavers.csv' -Apply)
        }
    }

    Context 'Safety' {
        It 'blocks an apply when a bad extract terminates most of the company' {
            $err = $null
            try { [void](Invoke-TestRun -Feed 'hr-feed-BAD-mass-termination.csv' -Apply) } catch { $err = $_.Exception.Message }
            $err | Should -Match 'SAFETY LIMIT'
            (Get-SimState).AD.Users['mbell'].Enabled | Should -BeTrue
        }
        It 'only warns in plan mode' {
            $r = Invoke-TestRun -Feed 'hr-feed-BAD-mass-termination.csv'
            $r.Safety.Tripped | Should -BeTrue
        }
        It 'reports orphans without touching them' {
            $s = Get-SimState
            $s.AD.Users['legacy.jdoe'] = @{
                SamAccountName = 'legacy.jdoe'; DistinguishedName = 'CN=John Doe,OU=Operations,OU=Users,OU=Meridian,DC=meridianfg,DC=internal'
                Enabled = $true; UserPrincipalName = 'legacy.jdoe@CHANGEME.onmicrosoft.com'; EmployeeId = '099999'
                Attributes = @{ displayName = 'John Doe' }; Groups = @('GG-MFG-Operations')
            }
            $s | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:simPath
            $r = Invoke-TestRun -Feed 'hr-feed-day3-leavers.csv' -Apply
            @($r.Orphans).EmployeeId | Should -Contain '099999'
            (Get-SimState).AD.Users['legacy.jdoe'].Enabled | Should -BeTrue
        }
    }

    Context 'Rollback and audit' {
        It 'undoes an applied leaver from its journal and lists irreversible steps' {
            $cfg = Import-PowerShellDataFile $script:cfgPath
            $journalDir = Join-Path (Split-Path $script:cfgPath) $cfg.Paths.Journal
            $leaverRun = Get-ChildItem $journalDir -Filter '*.json' | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json -AsHashtable } |
                Where-Object { $_.Mode -eq 'Apply' -and ($_.Items | Where-Object { $_.EmployeeId -eq '100008' -and $_.Result -eq 'Completed' -and $_.Operation -eq 'Leaver' }) } |
                Select-Object -First 1
            $leaverRun | Should -Not -BeNullOrEmpty
            Undo-JmlRun -ConfigPath $script:cfgPath -RunId $leaverRun.RunId -EmployeeId '100008' -Simulated -Confirm:$false 6>$null
            $u = (Get-SimState).AD.Users['tbrennan']
            $u.DistinguishedName | Should -Match 'OU=Operations,OU=Users'
            $u.Attributes.description | Should -BeNullOrEmpty
            $rb = Get-ChildItem $journalDir -Filter '*.json' | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json -AsHashtable } |
                Where-Object { $_.Mode -eq 'Rollback' -and $_.RollbackOf -eq $leaverRun.RunId } | Select-Object -First 1
            $steps = @($rb.Items[0].Steps)
            ($steps | Where-Object Of -eq 'AD.MoveUser').Reverse | Should -Match '^Move back to OU=Operations,OU=Users'
            ($steps | Where-Object Of -eq 'AD.SetAttributes').Reverse | Should -Match "^Restore description 'Terminated"
            $err = $null
            try { Undo-JmlRun -ConfigPath $script:cfgPath -RunId $leaverRun.RunId -Simulated -Confirm:$false 6>$null } catch { $err = $_.Exception.Message }
            $err | Should -Match 'already been undone'
        }
        It 'writes a journal, JSONL log and CSV report for every run' {
            $r = Invoke-TestRun -Feed 'hr-feed-day3-leavers.csv'
            Test-Path $r.JournalPath | Should -BeTrue
            Test-Path $r.ReportPath | Should -BeTrue
            Test-Path $r.LogPath | Should -BeTrue
            $j = Get-Content $r.JournalPath -Raw | ConvertFrom-Json
            $j.Feed.Sha256 | Should -Match '^[0-9A-F]{64}$'
        }
    }

    Context 'Naming' {
        It 'suffixes colliding account names and strips diacritics' {
            InModuleScope MeridianJML {
                $reserved = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                $taken = { param($c) $c -eq 'jsmith' }
                New-JmlSamAccountName -GivenName 'John' -Surname 'Smith' -Reserved $reserved -IsTaken $taken | Should -Be 'jsmith2'
                New-JmlSamAccountName -GivenName 'Jane' -Surname 'Smith' -Reserved $reserved -IsTaken $taken | Should -Be 'jsmith3'
                New-JmlSamAccountName -GivenName 'Zoë' -Surname "O'Brien-Núñez" -Reserved $reserved -IsTaken { $false } | Should -Be 'zobriennunez'
                (New-JmlSamAccountName -GivenName 'A' -Surname 'Bartholomew-Worthington' -Reserved $reserved -IsTaken { $false }).Length | Should -BeLessOrEqual 20
            }
        }
    }
}
