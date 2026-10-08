<div align="center">

# Meridian JML Engine

**Joiner-Mover-Leaver identity lifecycle automation for hybrid Active Directory and Microsoft Entra ID**

![PowerShell](https://img.shields.io/badge/PowerShell-7-5391FE?style=for-the-badge&logo=powershell&logoColor=white)
![Microsoft Graph](https://img.shields.io/badge/Microsoft%20Graph-v1.0-0078D4?style=for-the-badge&logo=microsoft&logoColor=white)
![Entra ID](https://img.shields.io/badge/Microsoft%20Entra%20ID-Hybrid-0078D4?style=for-the-badge&logo=microsoftazure&logoColor=white)
![Entra Cloud Sync](https://img.shields.io/badge/Entra%20Cloud%20Sync-AD%20to%20Entra-0078D4?style=for-the-badge&logo=microsoft&logoColor=white)
![Active Directory](https://img.shields.io/badge/Active%20Directory-Windows%20Server%202022-0078D6?style=for-the-badge&logo=windows&logoColor=white)
![Azure](https://img.shields.io/badge/Azure-Lab-0089D6?style=for-the-badge&logo=microsoftazure&logoColor=white)
![Pester](https://img.shields.io/badge/Tested%20with-Pester-A61E22?style=for-the-badge&logo=powershell&logoColor=white)
![Tests](https://img.shields.io/github/actions/workflow/status/ZayLinux26/meridian-jml-engine/tests.yml?style=for-the-badge&logo=githubactions&logoColor=white&label=tests)
![License](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)

*Part 1 of **The PowerShell IAM / PAM / PIM Series***

</div>

---

HR decides who works here. This engine makes Active Directory and Microsoft Entra ID agree with HR every day: it creates accounts for new hires, changes access when people change jobs, and shuts access off when they leave. It shows every change before making it, handles a failure halfway through, and leaves an audit trail an examiner can follow.

It was built for a fictional mid-size bank, Meridian Financial Group, and proven end to end on a live hybrid lab: a Server Core domain controller and a management server in Azure, synced to a real Entra tenant.

## Contents

1. [The enterprise problem](#the-enterprise-problem)
2. [What this project proves](#what-this-project-proves)
3. [JML explained](#jml-explained) (reference section)
4. [How the engine works](#how-the-engine-works)
5. [Design decisions](#design-decisions)
6. [Proven on a live lab](#proven-on-a-live-lab)
7. [What the live lab taught me](#what-the-live-lab-taught-me)
8. [Running it](#running-it)
9. [Audit evidence and control mapping](#audit-evidence-and-control-mapping)
10. [Testing](#testing)
11. [Repository layout and roadmap](#repository-layout)

---

## The enterprise problem

Every large company gets the same identity findings from its auditors, year after year:

- **Terminated users who still have access.** HR files the termination on Friday, IT disables the account on Tuesday, and the audit sample finds four days of exposure. In a bank, that's a former employee who could still sign in to the systems that move money.
- **Access creep.** People change jobs and keep everything from the old one. The analyst who moved from Treasury to Compliance can still release wires, which is also a segregation-of-duties violation.
- **Half-finished scripts.** A deprovisioning script dies halfway and leaves an account disabled in AD, alive in the cloud, and still in six groups. Nobody can say what state it's in.
- **No evidence.** Even when IT did the right thing, it can't prove when, who ran it, or from which HR record.

Hybrid identity makes all four harder. Employees live in on-prem Active Directory and sync to Entra ID, contractors often exist only in the cloud, and the sync between the two lags by minutes. A JML process has to handle both directories and the gap between them.

## What this project proves

Each claim links to a screenshot from the live lab.

| Claim | Evidence |
|---|---|
| Every change is previewed before it happens | [Day 1 plan](docs/screenshots/12-day1-plan.png) |
| Running it twice changes nothing the second time | [0 actions on the second run](docs/screenshots/17-day1-idempotent-nochange.png) |
| A job change removes the old job's access the same day | [Mover plan](docs/screenshots/18-day2-mover-plan.png), [Elena's groups after the move](docs/screenshots/20-elena-groups-after-move.png) |
| A failed new-hire setup is undone, not left half-built | [Joiner rolled back](docs/screenshots/19-day2-joiner-rollback.png) |
| A leaver loses access even when a later step breaks | [Leaver contained](docs/screenshots/21-day3-leaver-contained.png) |
| Access is cut in under a second, with timestamps to prove it | [Audit trail](docs/screenshots/22-day3-audit-trail.png) |
| Cloud sessions are revoked, not just the AD account | [Entra: blocked, sessions revoked](docs/screenshots/24-entra-leaver-blocked.png) |
| A corrupted HR file can't lock out the company | [Safety limit](docs/screenshots/25-safety-limit.png) |
| Bad HR rows are rejected, and missing people aren't disabled | [Feed rejections](docs/screenshots/26-feed-rejections.png) |
| A wrong termination can be reversed, with honest limits | [Rollback preview](docs/screenshots/27-undo-whatif.png) |
| The app identity has two Graph permissions and no secrets | [Permissions](docs/screenshots/07-app-permissions-granted.png), [certificate only](docs/screenshots/08-app-certificate-no-secrets.png) |

---

## JML explained

This section is the reference I wanted when I started: what JML is, the words people use for it, and what goes wrong at each stage.

### The lifecycle

```mermaid
stateDiagram-v2
    direction LR
    [*] --> PreHire: HR enters the hire
    PreHire --> Active: Joiner (start date within 14 days)
    Active --> Active: Mover (department, title or manager changes)
    Active --> Terminated: Leaver
    Terminated --> Active: Rehire
```

| Stage | Trigger in HR | What IT must do | What goes wrong without automation |
|---|---|---|---|
| **Joiner** | New worker with a start date | Create the account in the right place, give the access everyone in that role gets, set the manager | The new hire can't work on day one, or someone copies a coworker's account and inherits years of extra access |
| **Mover** | Department, title or manager changes | Add the new role's access **and remove the old role's access** | Access creep and segregation-of-duties conflicts, the most common audit finding |
| **Leaver** | Status changes to Terminated | Cut access immediately (disable, kill sessions), then clean up (groups, manager, OU, records) | Former employees keep access, and cloud sessions stay alive for hours after the AD account is disabled |
| **Rehire** | A terminated worker comes back | Re-enable the same identity and restore current access | Duplicate accounts, lost history, a broken audit trail |

### Terms you'll see in IAM work

| Term | Meaning | Where it shows up here |
|---|---|---|
| **Authoritative source** | The system whose word is final about who works here. Almost always HR (Workday, SuccessFactors, ADP). | The daily HR file in `data/` |
| **Identity anchor** | The one value that never changes for a person, used to match records across systems. Names and emails change; the HR worker ID doesn't. | `employeeID` in AD, `employeeId` in Entra |
| **Birthright access** | Access everyone gets automatically because of their job attributes, with no request or approval. | `config/access-model.json` |
| **Requested access** | Access someone asks for and a manager or owner approves. Handled by a ticket or an IGA tool, not by JML. | Left alone: the engine only removes groups it manages |
| **RBAC** | Role-based access control: access follows the role, not the person. | Department and job title layers in the access model |
| **AGDLP** | Microsoft's AD group pattern. **A**ccounts go in **G**lobal groups (who you are), which nest into **D**omain **L**ocal groups (what you can reach), which get **P**ermissions. | `GG-MFG-*` role groups nested into resource groups by `lab/02` |
| **Hybrid identity** | Users live in on-prem AD and are synced to Entra ID. AD is the "source of authority" for synced users, so their attributes can only be changed in AD. | Employees are hybrid; contractors are cloud-only |
| **Entra Cloud Sync** | Microsoft's lightweight agent that copies AD users to Entra on a short cycle. | Agent on MFG-MGMT01, scoped to `OU=Meridian` |
| **Containment** | The urgent part of a termination: make sure the person can't get in. Disable the account and revoke active sessions. | Steps marked `*` (critical) in leaver output |
| **Session revocation** | Disabling an account doesn't sign someone out of Teams or Outlook. Revoking sessions invalidates their refresh tokens, so cloud apps demand a new sign-in, which then fails. | `POST /users/{id}/revokeSignInSessions` |
| **Orphan account** | An enabled account with no matching active HR record. It could be a leaver HR forgot, or a service account. A human has to decide. | Reported every run, never auto-disabled |
| **Drift** | Someone changed access by hand outside the process. | Managed groups added by hand get removed |
| **Idempotent** | Running the same thing twice has the same result as running it once. The second run does nothing. | Screenshot 17 |
| **Compensation** | Undoing the steps that already succeeded when a later step fails, so nothing is left half-done. | Joiner and mover rollback, screenshot 19 |
| **Temporary Access Pass (TAP)** | A time-limited passcode in Entra that lets a user sign in and set up their credentials. | Flagged for rehires and reversed terminations |
| **Access certification** | A periodic review where managers confirm their people's access is still needed. Good JML keeps the list clean, so reviews are short. | CSV report per run |

### Worked example: one person through the lifecycle

Elena Sokolova joins Finance as a Treasury Analyst. The access model stacks four layers: everyone, employment type, department and job title.

| Layer | AD groups | Entra groups |
|---|---|---|
| Everyone | | `SG-MFG-AllStaff` |
| Employee | `GG-MFG-Employees` | `SG-MFG-Lic-M365` |
| Department: Finance | `GG-MFG-Finance` | `SG-MFG-App-ERP` |
| Title: Treasury Analyst | `GG-MFG-Treasury-WireRelease` | |

**Day 1 (Joiner):** the engine creates `esokolova` in `OU=Finance`, sets Marcus Bell as her manager and adds the three AD groups. Cloud Sync copies her to Entra a few minutes later, and the next run adds her three Entra groups.

**Day 2 (Mover):** HR moves her to Compliance as a Risk Analyst. The engine works out her access from scratch and applies only the difference: new manager, move to `OU=Compliance`, add `GG-MFG-Compliance` and `SG-MFG-App-GRC`, and **remove** `GG-MFG-Finance`, `GG-MFG-Treasury-WireRelease` and `SG-MFG-App-ERP`. She can't release wires after that run.

**Day 3 (Leaver), shown with Tom Brennan:** containment first (disable in AD, revoke Entra sessions), then cleanup (random password, remove every group, clear the manager, move to `OU=Disabled Users`), then a "Terminated" stamp on the account as the very last step.

---

## How the engine works

```mermaid
flowchart LR
    HR[(HR snapshot CSV)] --> V[Validate feed<br/>schema, duplicates, SHA-256]
    V --> P[Planner<br/>desired state vs current state]
    AD[(Active Directory<br/>meridianfg.internal)] -- one LDAP query --> P
    EN[(Microsoft Entra ID)] -- Graph v1.0 --> P
    P --> CB{Circuit breaker}
    CB -- tripped --> X[Abort, journal, exit 2]
    CB -- ok --> E[Executor]
    E -- Atomic --> J[Joiner / Mover / Rehire]
    E -- Fail-secure --> L[Leaver]
    J & L --> AD
    J & L --> EN
    AD -- Entra Cloud Sync --> EN
    E --> A[(Journal JSON<br/>JSONL audit log<br/>CSV report)]
```

1. **Read the HR file** and reject bad rows with a reason (unknown department, bad date, duplicate ID).
2. **Read the directories:** one LDAP query for AD, one Graph lookup per worker for Entra.
3. **Plan:** for each person, work out the access they should have and compare it with what they have. The output is a list of actions, each with its own undo.
4. **Check the circuit breaker:** too many leavers and the run stops before touching anything.
5. **Execute** each person as one unit of work, under the failure policy for that event type.
6. **Write evidence:** a journal, a SIEM-ready log and a CSV report for every run, dry runs included.

| HR event | Hybrid employee (AD, synced to Entra) | Cloud-only contractor (Entra) |
|---|---|---|
| **Joiner** | Creates the AD account in the department OU, sets the manager, adds AD groups. After Cloud Sync, adds Entra groups. | Creates the Entra user through Graph, sets the manager, adds Entra groups. |
| **Mover** | Updates attributes, moves OUs, adds new-role groups and **removes old-role groups** in AD and Entra. | Updates attributes and group membership through Graph. |
| **Leaver** | Disables and revokes sessions first, then randomizes the password, strips groups, clears the manager, moves to Disabled Users and stamps the record. | Blocks sign-in and revokes sessions first, then strips groups and clears the manager. |
| **Rehire** | Re-enables, moves back, restores access and flags that a TAP is needed. | Re-enables sign-in and restores access. |
| **Drift** | Removes managed groups someone added by hand. | Same. |

Component details, the action catalog and the full failure matrix are in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

---

## Design decisions

**1. Desired state, not a to-do list.** The engine never asks "did I already do this?" It compares what HR says with what the directory has right now and plans only the difference. There's no state file that can drift away from reality, and a run that crashed is fixed by running it again.
*Why it matters:* the job can run on a schedule, get retried by an operator at 2 AM or rerun after an outage, and it can't double-apply anything.

**2. Two failure policies, because joiners and leavers fail differently.**

| | Joiner / Mover / Rehire | Leaver |
|---|---|---|
| Policy | **Atomic** | **Fail-secure** |
| On a failed step | Stop, then undo every completed step in reverse order. The person ends fully changed or exactly as before. | Keep going. Undoing a termination would hand access back to someone who shouldn't have it. |
| Order | As planned | Containment first, cleanup second, "Terminated" stamp last |
| Results | `Completed`, `RolledBack`, `RollbackFailed` | `Completed`, `Contained`, `ContainmentFailed` |

The "Terminated" stamp works like a commit marker. Until it's written, every run treats the leaver as unfinished: it revokes sessions and randomizes the password again, then finishes the remaining cleanup.
*Why it matters:* a broken step never leaves a former employee with access, and never leaves a new hire with half an account.

**3. A circuit breaker for bad HR files.** If a run would terminate more than 10 people or more than 25% of the population, it stops before changing anything and exits with code 2. An operator can override after checking with HR, and the override is journaled with their name.
*Why it matters:* a truncated HR export should cause a phone call, not a company-wide lockout.

**4. The engine only removes access it owns.** Groups named in the access model are managed. Anything else (a privileged group, a share approved by ticket) is left alone for active workers. Leavers lose all AD group memberships.
*Why it matters:* JML automation that fights the access-request process gets turned off within a month.

**5. Missing from the HR file is not the same as terminated.** Enabled accounts HR stopped sending are reported as orphans for review and never disabled automatically.
*Why it matters:* a filtered export or a bad join on the HR side would otherwise look like a mass termination.

**6. Least-privilege app identity.** Graph access is app-only, with a certificate whose private key can't be exported off the management server. Two application permissions: `User.ReadWrite.All` and `GroupMember.ReadWrite.All`. No client secrets and no `Directory.ReadWrite.All`. On the AD side, `lab/03-Grant-JmlDelegation.ps1` delegates rights on `OU=Meridian` only, so the engine doesn't need Domain Admin.
*Why it matters:* the account that can disable everyone is the most attractive account to steal, so it should hold as little as possible.

**7. Hybrid-aware.** Synced users are mastered in AD, so the engine writes their attributes in AD and only uses Graph for what AD can't do (cloud groups, session revocation). It never edits an AD-mastered user through Graph, and when sync is slow it waits (`PendingSync`) instead of creating a duplicate cloud account.
*Why it matters:* writing to the wrong side of a hybrid identity either fails or gets silently overwritten on the next sync.

**8. Production-style server layout.** The domain controller runs Server Core with nothing extra installed. Admin tools, the Cloud Sync agent and the engine run on a separate management server, and RDP to both is limited to one IP.
*Why it matters:* domain controllers are tier 0. Fewer tools and fewer logons on them means less to attack.

---

## Proven on a live lab

Everything below was captured from a real hybrid environment, not the simulator:

- **MFG-DC01:** Windows Server 2022 **Core** domain controller for `meridianfg.internal`
- **MFG-MGMT01:** Windows Server 2022 management server running RSAT, the Entra Cloud Sync agent and the engine
- **Microsoft Entra ID** tenant, synced with Entra Cloud Sync and scoped to `OU=Meridian`
- Both VMs in one Azure VNet (`10.20.0.0/24`), with RDP locked to a single admin IP

### Day 1: joiners

Eleven employees and two contractors start. The plan shows every change before anything happens. The first live apply hit Entra replication lag, and the engine rolled the two contractors back cleanly instead of leaving them half-built. After the fix, everything converged and the final run found nothing to do.

| Plan (dry run) | First apply: two contractors roll back on replication lag ([lesson 1](#what-the-live-lab-taught-me)) |
|---|---|
| ![Day 1 plan](docs/screenshots/12-day1-plan.png) | ![Day 1 apply](docs/screenshots/13-day1-apply.png) |
| **After Cloud Sync: Entra groups added** | **Same file again: 0 actions** |
| ![Reconcile](docs/screenshots/16-day1-reconcile-entra-groups.png) | ![Idempotent](docs/screenshots/17-day1-idempotent-nochange.png) |

### Day 2: a mover, and a joiner that fails halfway

Elena moves from Treasury to Compliance and loses wire-release access the same day. Michael's account setup is broken on purpose, and the engine deletes the half-built account instead of leaving it behind.

| Mover plan: old access removed | Joiner rolled back |
|---|---|
| ![Mover](docs/screenshots/18-day2-mover-plan.png) | ![Rollback](docs/screenshots/19-day2-joiner-rollback.png) |

![Elena's groups after the move](docs/screenshots/20-elena-groups-after-move.png)

### Day 3: a leaver, with a failure in the middle

Tom is disabled and his Entra sessions are revoked within a second. The OU move then fails on purpose, so the "Terminated" stamp is held back and the next run finishes the job.

| Contained despite the failure | Per-action audit trail |
|---|---|
| ![Contained](docs/screenshots/21-day3-leaver-contained.png) | ![Audit](docs/screenshots/22-day3-audit-trail.png) |
| **Next run finishes the job** | **Entra: blocked, sessions revoked** |
| ![Completed](docs/screenshots/23-day3-leaver-completed.png) | ![Entra blocked](docs/screenshots/24-entra-leaver-blocked.png) |

### Safety rails and break-glass

| A bad HR file would terminate 57% of staff | Bad rows rejected, orphans flagged, nothing disabled |
|---|---|
| ![Safety limit](docs/screenshots/25-safety-limit.png) | ![Rejections](docs/screenshots/26-feed-rejections.png) |
| **Rollback preview, irreversible steps called out** | **Test suite** |
| ![Undo](docs/screenshots/27-undo-whatif.png) | ![Pester](docs/screenshots/28-pester-green.png) |

<details>
<summary><b>Lab build screenshots (Azure, AD, Entra, app registration, Cloud Sync)</b></summary>

| | |
|---|---|
| ![Azure VMs](docs/screenshots/01-azure-vm-overview.png) | ![NSG rule](docs/screenshots/02-nsg-rdp-my-ip.png) |
| ![DC ready](docs/screenshots/03-domain-controller-ready.png) | ![OU structure](docs/screenshots/04-aduc-meridian-ous.png) |
| ![AD delegation](docs/screenshots/05-ad-delegation.png) | ![Entra groups](docs/screenshots/06-entra-birthright-groups.png) |
| ![App permissions](docs/screenshots/07-app-permissions-granted.png) | ![Certificate only](docs/screenshots/08-app-certificate-no-secrets.png) |
| ![Cloud Sync agent](docs/screenshots/09-cloud-sync-agent.png) | ![Cloud Sync scope](docs/screenshots/10-cloud-sync-scope.png) |
| ![App-only Graph](docs/screenshots/11-graph-app-only-context.png) | ![ADUC users](docs/screenshots/14-aduc-day1-users.png) |
| ![Synced users](docs/screenshots/15-entra-synced-users.png) | ![GitHub Actions](docs/screenshots/29-github-actions-green.png) |

</details>

---

## What the live lab taught me

The simulator and the contract tests passed from the start. The real tenant still found four things they didn't.

**1. Entra replication lag.** Right after `POST /users` creates a contractor, the next write (adding a group, setting a manager) can return 404 for a few seconds because the new object hasn't replicated yet. On the first live run, two contractors rolled back over it. The fix: Graph writes against a just-created user retry 404s with backoff, and later steps address the user by object ID instead of UPN. The contract tests now simulate that lag.

**2. A rollback has to survive the same lag.** The compensating delete for a failed contractor hit the same 404, treated it as "already gone" and left an active account behind. Deletes now retry before they accept "not found". A rollback that quietly fails is worse than no rollback.

**3. Sync scope is part of your leaver process.** Tom vanished from Entra after his termination instead of showing as disabled. The Cloud Sync scope listed individual OUs, and `OU=Disabled Users` wasn't one of them, so moving him there pushed him out of scope and Cloud Sync soft-deleted his cloud account. For a bank that's a records-retention problem: the 30-day clock on his mailbox and files starts without anyone deciding it should. Scoping to the parent `OU=Meridian` brought him back as the same, disabled account. Deletion should be a deliberate step after a retention period, not a side effect of an OU move. I caught it when a Graph lookup on Tom, meant to confirm `accountEnabled: false`, came back 404 instead.

![Leaver soft-deleted by a sync scope gap](docs/screenshots/24a-scope-lesson-deleted-user.png)

**4. The sync engine can get stuck, and the JML engine has to wait it out.** Twice, a new AD user never appeared in Entra and on-demand provisioning answered `JoinNotFound`. Restarting provisioning in Cloud Sync cleared it. Meanwhile the engine reported those users as `PendingSync` and changed nothing in the cloud. It never tried to create a duplicate cloud account to work around sync.

---

## Running it

### Try it on any machine (no lab needed)

The simulated provider is an in-memory AD and Entra pair with a stand-in Cloud Sync cycle. Same planner, same executor.

```powershell
# macOS: brew install --cask powershell   |   Windows: winget install Microsoft.PowerShell
pwsh
Copy-Item ./config/jml.config.example.psd1 ./config/jml.config.psd1
Import-Module ./src/MeridianJML/MeridianJML.psd1

$cfg = './config/jml.config.psd1'
Invoke-JmlRun -ConfigPath $cfg -FeedPath ./data/hr-feed-day1-joiners.csv -Simulated            # plan
Invoke-JmlRun -ConfigPath $cfg -FeedPath ./data/hr-feed-day1-joiners.csv -Simulated -Apply     # apply
Invoke-JmlRun -ConfigPath $cfg -FeedPath ./data/hr-feed-day3-leavers.csv -Simulated -Apply `
    -SimulateFailure AD.MoveUser -SimulateFailureFor 100008                                     # break it on purpose
```

### Build the real hybrid lab

[docs/WALKTHROUGH.md](docs/WALKTHROUGH.md) builds the two Azure servers, the forest, Cloud Sync and the app registration, then walks the three HR days end to end. Every screenshot above has a step there. It also has a troubleshooting table and a resume checklist for when the VMs have been off.

### The HR file

One row per worker, the full population every day (a snapshot, not a list of changes):

```
EmployeeId,GivenName,Surname,Department,JobTitle,ManagerId,Office,EmploymentType,Status,EffectiveDate
100002,Priya,Raman,Finance,Senior Financial Analyst,100001,Chicago,Employee,Active,2026-09-01
```

`Status` is `Active` or `Terminated`. `EmploymentType` is `Employee` or `Contractor`. `EffectiveDate` is the start date for joiners (accounts are created up to 14 days early) and the termination date for leavers.

### Commands

| Command | Purpose |
|---|---|
| `Invoke-JmlRun -ConfigPath -FeedPath` | Plan only. Reads everything, writes nothing, saves the plan as change evidence. |
| `Invoke-JmlRun ... -Apply` | Execute the plan. |
| `Invoke-JmlRun ... -OverrideSafetyLimit` | Proceed past the circuit breaker (journaled). |
| `Show-JmlRun -ConfigPath -List` | List past runs. |
| `Show-JmlRun -ConfigPath -RunId [-EmployeeId]` | Print the per-action audit trail for a run. |
| `Undo-JmlRun -ConfigPath -RunId [-EmployeeId] [-WhatIf]` | Break-glass reversal of an applied run from its journal. |
| `scripts/Start-JmlRun.ps1 -FeedPath [-Apply]` | Scheduler entry point with exit codes: 0 ok, 1 retry pending, 2 safety abort, 3 containment failed, 4 engine error. |

The exit codes are meant for a scheduler or a monitoring tool: 1 means the next run will finish the work, 2 means call HR, and 3 means page someone, because a leaver may still have access.

---

## Audit evidence and control mapping

| File | Contents |
|---|---|
| `output/journal/<RunId>.json` | Full plan and outcome: every action, its before-state, its undo, timestamps, status, errors, operator and HR file SHA-256. |
| `output/logs/run-<RunId>.jsonl` | One JSON line per event, ready for Sentinel, Splunk or any SIEM. |
| `output/reports/report-<RunId>.csv` | One row per person for the access review or the auditor. |

Passwords are generated at execution time and never logged. Rollbacks write their own journal, so the undo is audited too.

| Framework | Control | How |
|---|---|---|
| PCI DSS v4.0 | 8.2.4, 8.2.5 | Adds, changes and removals follow the authoritative HR record; terminated access is revoked on the next run, containment first. |
| SOX ITGC | Logical access: provisioning, deprovisioning, transfers | Plans are change evidence; journals show who ran what, from which HR file hash. |
| ISO/IEC 27001:2022 | A.5.16, A.5.18 | Identity lifecycle and access rights driven from one source of truth. |
| NIST SP 800-53 | AC-2, AC-2(3) | Account management; disabling accounts of departed users. |

---

## Testing

```powershell
Invoke-Pester ./tests
```

- `tests/MeridianJML.Tests.ps1` runs the three-day story on the simulated directory: idempotency, rollback, fail-secure leavers, the circuit breaker, orphans, naming collisions and the rollback journal.
- `tests/LiveProvider.Contract.Tests.ps1` runs the **live** AD and Graph code against stand-ins for the `ActiveDirectory` and `Microsoft.Graph.Authentication` modules. The stand-ins copy the behavior that breaks real scripts: missing AD attributes, Graph 404s, duplicate-member 400s, AD-mastered users rejecting cloud edits, `employeeId` filters that need `ConsistencyLevel: eventual`, and replication lag on new users.

Both run in GitHub Actions on every push.

---

## Repository layout

```
config/            engine config (example) and the birthright access model
data/              sample HR files: day 1 joiners, day 2 movers, day 3 leavers, bad extract, invalid rows
docs/              architecture, step-by-step lab walkthrough, screenshots
lab/               Azure deployment, forest, OU/group build, AD delegation, app registration, Entra groups
scripts/           unattended entry point with exit codes
src/MeridianJML/   the module (Public = commands, Private = planner, executor, providers)
tests/             Pester suites and AD/Graph test stand-ins
```

## Roadmap

- HR source adapters for the Workday and SuccessFactors APIs alongside CSV
- Graph `$batch` and delta queries for large populations
- Temporary Access Pass issuance for joiners and rehires
- Hand-off to Entra Lifecycle Workflows (`employeeLeaveDateTime`) for mailbox and OneDrive tasks
- Part 2 of the series: privileged account lifecycle and PIM role assignment

## License

MIT. See [LICENSE](LICENSE).
