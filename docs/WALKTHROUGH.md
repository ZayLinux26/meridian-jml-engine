# Lab walkthrough

This guide builds the Meridian hybrid lab and runs the JML engine through three HR days. Every step that produces a README image is marked **Screenshot** with the exact filename to save under `docs/screenshots/`.

**What you need**

- A Mac (everything on the Windows side happens over Remote Desktop)
- An Azure subscription
- Your Microsoft Entra tenant, with a Global Administrator account
- About 3 to 4 hours spread over a couple of sittings

**What you end up with**

```
Your Mac ──RDP──> MFG-DC01 (Azure VM, Windows Server 2022)
                    ├─ AD DS: meridianfg.internal, OU=Meridian
                    ├─ Entra Cloud Sync agent ──> your Entra tenant
                    └─ PowerShell 7 + JML engine ──Graph (app-only, cert)──> your Entra tenant
```

One VM plays two roles: domain controller and automation host. In production those are separate machines (the engine would run on a hardened management server under a gMSA). For a lab, one box keeps cost and setup down.

**Screenshot tips for the Mac**

- `Cmd + Shift + 4`, then `Space`, then click a window: captures just that window with a clean shadow.
- Before terminal screenshots, maximise the PowerShell window inside the RDP session and run `cls` so the image starts with your command.
- Crop out anything showing your tenant ID, subscription ID or public IP. The tenant's `onmicrosoft.com` name is fine to show.

---

## Phase 0: Get the code onto GitHub and run it once on your Mac

**0.1 Install PowerShell 7 on the Mac**

```bash
brew install --cask powershell
pwsh --version
```

**0.2 Create the repo.** On GitHub, create a new public repository named `meridian-jml-engine` (no README, no license; the project already has both). Then, from the unzipped project folder:

```bash
cd ~/Projects/meridian-jml-engine
git init -b main
git add .
git commit -m "Meridian JML engine: initial commit"
git remote add origin https://github.com/ZayLinux26/meridian-jml-engine.git
git push -u origin main
```

**0.3 Run the simulated demo** to see the engine work before building anything:

```powershell
pwsh
Copy-Item ./config/jml.config.example.psd1 ./config/jml.config.psd1
Import-Module ./src/MeridianJML/MeridianJML.psd1
Invoke-JmlRun -ConfigPath ./config/jml.config.psd1 -FeedPath ./data/hr-feed-day1-joiners.csv -Simulated
```

You should see 13 joiners planned. Nothing is written in plan mode. Delete `./output` afterwards so the simulated state does not mix with anything else.

**0.4 Run the tests**

```powershell
Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -Force
Invoke-Pester ./tests -Output Detailed
```

**Screenshot `28-pester-green.png`:** the end of the Pester output showing all tests passed.

Open the repo's **Actions** tab on GitHub. The `tests` workflow runs on every push.

**Screenshot `29-github-actions-green.png`:** the green workflow run.

---

## Phase 1: Deploy MFG-DC01 in Azure

You can do this in the portal (better screenshots) or with `lab/00-Deploy-LabVM.sh` from the Mac (`brew install azure-cli`, `az login`, then run it). Portal steps:

**1.1** portal.azure.com, **Create a resource**, **Virtual machine**.

**1.2 Basics tab**

| Field | Value |
|---|---|
| Resource group | Create new: `rg-meridian-iam-lab` |
| Virtual machine name | `MFG-DC01` |
| Region | `(US) Central US` (or your closest) |
| Availability options | No infrastructure redundancy required |
| Security type | Trusted launch virtual machines |
| Image | Windows Server 2022 Datacenter: Azure Edition - x64 Gen2 |
| Size | `Standard_B2ms` (2 vCPU, 8 GiB) |
| Username | `mfgadmin` |
| Password | a long unique password; save it in your password manager |
| Public inbound ports | Allow selected ports, RDP (3389) |

**1.3 Disks tab:** OS disk type `Standard SSD`.

**1.4 Networking tab:** create a new virtual network `vnet-meridian` with address space `10.20.0.0/16` and subnet `snet-identity` `10.20.1.0/24`. Keep the new public IP.

**1.5 Management tab:** turn on **Auto-shutdown**, 11:00 PM, your time zone. This is the difference between a lab that costs a few dollars and one that runs all month.

**1.6 Review + create**, then **Create**. Wait for the deployment to finish and open the VM.

**Screenshot `01-azure-vm-overview.png`:** the VM Overview blade (status Running, size, OS). Crop out the subscription ID and public IP.

**1.7 Lock RDP to your IP.** VM, **Networking**, **Network settings**, click the RDP inbound rule. Set **Source** to `My IP address`, save.

**Screenshot `02-nsg-rdp-my-ip.png`:** the inbound rules list showing RDP restricted to a single source IP (blur the IP).

**1.8 Make the private IP static.** VM, **Networking**, click the network interface, **IP configurations**, `ipconfig1`, set assignment to **Static** (keep the address, usually `10.20.1.4`), save. A domain controller's address must never change.

---

## Phase 2: Connect from the Mac and install tooling

**2.1** Install **Windows App** (Microsoft's Remote Desktop app) from the Mac App Store. **+**, **Add PC**, enter the VM's public IP, add the `mfgadmin` credential, connect.

**2.2** On the VM, open **Windows PowerShell** as Administrator and run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
Invoke-WebRequest -UseBasicParsing https://raw.githubusercontent.com/ZayLinux26/meridian-jml-engine/main/lab/00-Install-Tooling.ps1 -OutFile $env:TEMP\tooling.ps1
& $env:TEMP\tooling.ps1
```

This installs PowerShell 7, Git, the Graph authentication module and Pester.

**2.3** Close that window. From the Start menu open **PowerShell 7 (x64)** as Administrator. Every command from here on runs in PowerShell 7.

```powershell
git clone https://github.com/ZayLinux26/meridian-jml-engine.git C:\Lab\meridian-jml-engine
Set-Location C:\Lab\meridian-jml-engine
```

---

## Phase 3: Build the Meridian forest

**3.1 Promote to a domain controller**

```powershell
.\lab\01-Install-MeridianForest.ps1
```

Enter a DSRM password when prompted. The server reboots in a few minutes.

**3.2** Reconnect with Windows App. The username is now `MERIDIAN\mfgadmin`, same password.

**3.3 Point the VNet at the DC.** In the portal: `vnet-meridian`, **DNS servers**, **Custom**, `10.20.1.4`, save. Then restart the VM once so it picks up the setting.

**3.4 Verify**

```powershell
Get-ADDomain | Format-List DNSRoot, NetBIOSName, DomainMode, PDCEmulator
```

**Screenshot `03-domain-controller-ready.png`:** that output (or Server Manager showing AD DS and DNS with green status).

---

## Phase 4: OU structure, UPN suffix and groups

**4.1** Find your tenant's domain: entra.microsoft.com, **Overview**, **Primary domain** (for example `contoso.onmicrosoft.com`). Note the **Tenant ID** too.

**4.2** Run the directory build (PowerShell 7, from `C:\Lab\meridian-jml-engine`):

```powershell
.\lab\02-Initialize-MeridianDirectory.ps1 -UpnSuffix <yourtenant>.onmicrosoft.com
```

It creates `OU=Meridian` with department OUs, `Disabled Users`, `Groups` and `Service Accounts`; adds your tenant domain as a UPN suffix; creates the birthright groups from the access model; and nests them into resource groups (AGDLP). Run it again and every line shows `=` instead of `+`. That is the same idempotency idea the engine uses.

**4.3** Open **Active Directory Users and Computers** (`dsa.msc`). Expand `meridianfg.internal`, `Meridian`, `Users`, and click `Groups` too.

**Screenshot `04-aduc-meridian-ous.png`:** ADUC with the Meridian OU tree expanded and the Groups OU contents visible.

**4.4 (Optional, but worth it for the story) Delegate least-privilege rights**

```powershell
.\lab\03-Grant-JmlDelegation.ps1 -WhatIf     # shows the dsacls commands
.\lab\03-Grant-JmlDelegation.ps1
```

In ADUC, **View**, enable **Advanced Features**. Right-click `Meridian`, **Properties**, **Security**, **Advanced**.

**Screenshot `05-ad-delegation.png`:** the Advanced Security Settings list showing `GG-MFG-JML-Operators` entries.

---

## Phase 5: Entra side (groups and the app registration)

Both scripts sign in with a **device code**: they print a URL and a code. Open the URL on your Mac, enter the code, sign in as your Global Administrator.

**5.1 Birthright groups**

```powershell
.\lab\05-New-MeridianEntraGroups.ps1 -TenantId <your-tenant-id>
```

In the Entra admin center, **Groups**, **All groups**, search `SG-MFG`.

**Screenshot `06-entra-birthright-groups.png`:** the list of SG-MFG groups.

**5.2 App registration with certificate auth**

```powershell
.\lab\04-New-JmlAppRegistration.ps1 -TenantId <your-tenant-id>
```

It creates a certificate on the VM (private key cannot be exported), registers `MFG-JML-Engine`, grants admin consent for `User.ReadWrite.All` and `GroupMember.ReadWrite.All`, and prints three lines. **Copy those three lines**; you need them in Phase 7.

In the Entra admin center, **App registrations**, **All applications**, `MFG-JML-Engine`:

**Screenshot `07-app-permissions-granted.png`:** **API permissions** page showing the two Application permissions with the green "Granted for ..." status.

**Screenshot `08-app-certificate-no-secrets.png`:** **Certificates & secrets** page with one certificate and zero client secrets.

---

## Phase 6: Entra Cloud Sync

**6.1** On the VM, open Edge and sign in to entra.microsoft.com. Go to **Entra ID**, **Entra Connect**, **Cloud sync**, **Agents**, **Download on-premises agent**, accept, and run the installer.

**6.2** In the installer: choose **Microsoft Entra Connect cloud sync**, sign in with your Global Administrator, let it **create a gMSA**, then **Add directory** `meridianfg.internal` using `MERIDIAN\mfgadmin`. Finish. (Screen names shift a little between agent versions; the flow stays the same.)

**6.3** Back in the portal, **Cloud sync**, **Agents**: the agent shows **Active**.

**Screenshot `09-cloud-sync-agent.png`:** the Agents page with MFG-DC01 active.

**6.4** **Configurations**, **New configuration**, **AD to Microsoft Entra ID sync**, select `meridianfg.internal`, keep **Enable password hash sync** on, **Create**.

**6.5** In the new configuration: **Scoping filters**, **Selected organizational units**, add:

```
OU=Meridian,DC=meridianfg,DC=internal
```

Save. Then **Review and enable**, **Enable configuration**.

**Screenshot `10-cloud-sync-scope.png`:** the configuration overview showing the OU scope and Enabled status.

Scoping to `OU=Meridian` keeps the built-in `mfgadmin` and system accounts out of the cloud.

---

## Phase 7: Configure and connect the engine

**7.1**

```powershell
Copy-Item .\config\jml.config.example.psd1 .\config\jml.config.psd1
notepad .\config\jml.config.psd1
```

Set `AD.UpnSuffix` to your tenant domain and paste the three Graph lines from Phase 5.2. `config\jml.config.psd1` is git-ignored, so the IDs never reach GitHub.

**7.2 Prove the app-only connection**

```powershell
Import-Module .\src\MeridianJML\MeridianJML.psd1
Connect-JmlGraph -ConfigPath .\config\jml.config.psd1 | Format-List AppName, AuthType, Scopes, CertificateThumbprint
```

**Screenshot `11-graph-app-only-context.png`:** `AuthType : AppOnly` and exactly two scopes. Blur the thumbprint.

---

## Phase 8: Day 1, joiners

Set a short variable so the commands stay readable:

```powershell
$cfg = '.\config\jml.config.psd1'
```

**8.1 Plan**

```powershell
Invoke-JmlRun -ConfigPath $cfg -FeedPath .\data\hr-feed-day1-joiners.csv
```

13 joiners: 11 hybrid employees and 2 cloud-only contractors. Managers are planned before their reports so everyone gets a manager in one pass.

**Screenshot `12-day1-plan.png`:** the summary table plus the first few action blocks.

**8.2 Apply**

```powershell
Invoke-JmlRun -ConfigPath $cfg -FeedPath .\data\hr-feed-day1-joiners.csv -Apply
```

**Screenshot `13-day1-apply.png`:** the Results table, all `Completed`.

**8.3** In ADUC, refresh `Meridian > Users > Finance`.

**Screenshot `14-aduc-day1-users.png`:** Finance OU with Marcus Bell, Priya Raman and Elena Sokolova. Open Elena's **Organization** tab so the manager (Marcus Bell) shows too, if it fits.

**8.4 Wait for Cloud Sync** (about 2 to 5 minutes). Entra admin center, **Users**, **All users**, add the column **On-premises sync enabled**.

**Screenshot `15-entra-synced-users.png`:** Meridian users with sync enabled = Yes, plus the two `c-` contractors as cloud users.

**8.5 Apply again**

```powershell
Invoke-JmlRun -ConfigPath $cfg -FeedPath .\data\hr-feed-day1-joiners.csv -Apply
```

Now that the cloud objects exist, the engine adds the Entra birthright groups (`Reconcile`) and sets the contractors' managers.

**Screenshot `16-day1-reconcile-entra-groups.png`:** the plan section showing `[Entra] AddGroupMember` actions.

**8.6 The idempotency shot.** Run the plan one more time:

```powershell
Invoke-JmlRun -ConfigPath $cfg -FeedPath .\data\hr-feed-day1-joiners.csv
```

**Screenshot `17-day1-idempotent-nochange.png`:** every row `NoChange`, 0 actions. This is the most important image in the README.

---

## Phase 9: Day 2, movers (and a deliberate joiner failure)

**9.1 Plan**

```powershell
Invoke-JmlRun -ConfigPath $cfg -FeedPath .\data\hr-feed-day2-movers.csv
```

Elena Sokolova moves from Finance (Treasury Analyst) to Compliance (Risk Analyst). Look at her block: new manager, OU move, `GG-MFG-Compliance` added, and `GG-MFG-Finance` and `GG-MFG-Treasury-WireRelease` **removed**. Tom Brennan gets a title change. Michael Chen joins. Grace Liu starts in January, so she is `Deferred`.

**Screenshot `18-day2-mover-plan.png`:** Elena's action block.

**9.2 Apply with a failure injected into the new joiner**

```powershell
Invoke-JmlRun -ConfigPath $cfg -FeedPath .\data\hr-feed-day2-movers.csv -Apply -SimulateFailure AD.AddGroupMember -SimulateFailureFor 100012
```

Michael Chen's account is created, the first group add fails, and the engine deletes the account it just made. Elena and Tom still complete.

**Screenshot `19-day2-joiner-rollback.png`:** the `RolledBack` detail block (CreateUser `Compensated`, AddGroupMember `Failed`, the rest `NotStarted`).

Check ADUC: there is no `mchen` in Technology.

**9.3 Apply again without the fault.** Michael is provisioned cleanly.

```powershell
Invoke-JmlRun -ConfigPath $cfg -FeedPath .\data\hr-feed-day2-movers.csv -Apply
```

**9.4** Elena in ADUC (now under `Users > Compliance`), **Member Of** tab.

**Screenshot `20-elena-groups-after-move.png`:** only Employees and Compliance groups; no Finance, no wire release.

After the next Cloud Sync cycle, run the day 2 apply once more so the Entra side converges for Michael, then a plan to confirm `NoChange`.

---

## Phase 10: Day 3, leavers (with a failure in the middle)

**10.1 Apply with the OU move failing for Tom Brennan**

```powershell
Invoke-JmlRun -ConfigPath $cfg -FeedPath .\data\hr-feed-day3-leavers.csv -Apply -SimulateFailure AD.MoveUser -SimulateFailureFor 100008
```

Tom is disabled and his sessions are revoked first. Groups come off. The move fails, so the "Terminated" stamp is held back. Result: `Contained`.

**Screenshot `21-day3-leaver-contained.png`:** Tom's detail block: containment `Succeeded`, MoveUser `Failed`, commit stamp `Skipped`.

**10.2 The audit trail**

```powershell
Show-JmlRun -ConfigPath $cfg -List | Format-Table
Show-JmlRun -ConfigPath $cfg -RunId <RunId from 10.1> -EmployeeId 100008
```

**Screenshot `22-day3-audit-trail.png`:** the timestamped per-action trail with the injected error.

**10.3 Finish the job**

```powershell
Invoke-JmlRun -ConfigPath $cfg -FeedPath .\data\hr-feed-day3-leavers.csv -Apply
```

**Screenshot `23-day3-leaver-completed.png`:** Tom `Completed` (move plus stamp only; nothing repeated that was already done).

**10.4 Proof in Entra.** After the next Cloud Sync cycle, open Tom in the Entra admin center: **Account enabled: No**. Then show the revocation timestamp from Graph:

```powershell
Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/users/tbrennan@<yourtenant>.onmicrosoft.com?`$select=displayName,accountEnabled,signInSessionsValidFromDateTime"
```

**Screenshot `24-entra-leaver-blocked.png`:** the Entra user page or the Graph output with `accountEnabled False` and a fresh `signInSessionsValidFromDateTime`.

---

## Phase 11: Safety rails

**11.1 A broken HR extract**

```powershell
Invoke-JmlRun -ConfigPath $cfg -FeedPath .\data\hr-feed-BAD-mass-termination.csv -Apply
```

The run aborts before any change with a `SAFETY LIMIT` error.

**Screenshot `25-safety-limit.png`:** the red SAFETY LIMIT message.

**11.2 Bad rows**

```powershell
Invoke-JmlRun -ConfigPath $cfg -FeedPath .\data\hr-feed-invalid-rows.csv
```

Unknown department, bad date format, invalid employment type, and a duplicated employee ID (both copies rejected). Plan mode only, so nothing changes. The warnings show which workers are missing from this feed as orphans, which is exactly why orphans are never auto-disabled.

**Screenshot `26-feed-rejections.png`:** the rejected-row warnings.

---

## Phase 12: Break-glass rollback

Say HR terminated Tom by mistake. His termination was spread over two runs (10.1 contained him, 10.3 finished the move and stamp), so undo them newest first.

```powershell
Show-JmlRun -ConfigPath $cfg -List | Format-Table      # find the two day 3 Apply runs
Undo-JmlRun -ConfigPath $cfg -RunId <RunId from 10.3> -EmployeeId 100008 -WhatIf
```

**Screenshot `27-undo-whatif.png`:** the WhatIf lines for the 10.3 run (move back to Operations, remove the stamp, restore the manager).

Now run it for real, newest run first:

```powershell
Undo-JmlRun -ConfigPath $cfg -RunId <RunId from 10.3> -EmployeeId 100008 -Confirm:$false
Undo-JmlRun -ConfigPath $cfg -RunId <RunId from 10.1> -EmployeeId 100008 -Confirm:$false
```

The second undo re-enables Tom and restores his groups, and lists two steps it cannot reverse (password randomisation and session revocation). He would need a Temporary Access Pass to sign in.

Then plan day 3 again: the engine wants to terminate Tom again, because the HR feed still says so. That is correct behaviour. The permanent fix belongs in HR; once the feed says Active, the engine processes him as a `Rehire`.

To get the lab back to a clean day 3 state, apply day 3 again.

---

## Phase 13: README polish

1. Copy the PNGs into `docs/screenshots/` with the filenames above.
2. `git add docs/screenshots && git commit -m "Add lab screenshots" && git push`
3. Open the repo on GitHub and check that every image in the README renders.

---

## Cost and cleanup

- **Stop** the VM from the portal when you finish a session (status must say *Stopped (deallocated)*, which stops compute billing). Auto-shutdown catches the nights you forget.
- To delete everything: portal, `rg-meridian-iam-lab`, **Delete resource group**. In Entra, delete the `MFG-JML-Engine` app registration, the SG-MFG groups, the synced users and the Cloud Sync configuration.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Access model references Entra groups that do not exist` | Run Phase 5.1, or check the group names match `config/access-model.json`. |
| `Config Graph.TenantId is not set` | Paste the Phase 5.2 output into `config\jml.config.psd1`. |
| `Insufficient privileges` from Graph | Admin consent missing. App registration, API permissions, **Grant admin consent**. |
| Entra groups never get added for hybrid users | Cloud Sync has not created the users yet. Check Cloud sync, provisioning logs. Scope must include `OU=Meridian`. |
| Synced users show a different UPN | The UPN suffix in AD must match a verified tenant domain. Re-run Phase 4.2 with the right `-UpnSuffix`. |
| Certificate not found on connect | Run the engine as the same Windows user that ran `04-New-JmlAppRegistration.ps1` (the cert lives in that user's store). |
