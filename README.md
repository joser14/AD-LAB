# Active Directory Lab (Hyper-V)

An isolated, self-contained AD lab on your machine for learning and security practice.
Everything is automated: the script builds the VMs from ISOs, promotes the DC, joins the
clients, and installs the roles below. Keep this lab off any production network.

## What you get

| VM    | OS                               | IP            | Role |
|-------|----------------------------------|---------------|------|
| DC01  | Windows Server (Desktop Exp.)    | 10.10.10.10   | AD DS (forest `lab.local`), DNS, **AD CS** Enterprise Root CA + Web Enrollment |
| WS01  | Windows 11 Pro                   | 10.10.10.21   | Domain member, **SQL Server 2022** running as `LAB\svc_sql` |
| WS02  | Windows 11 Pro                   | 10.10.10.22   | Domain member |

- **Network:** internal Hyper-V switch `ADLab`, `10.10.10.0/24`, host is the gateway `10.10.10.1`
  with NAT so the VMs can reach the internet. No bridge to your LAN.
- **Domain:** `lab.local` / NetBIOS `LAB`.

### Accounts (all use the password you type at the prompt)
| Account        | Purpose |
|----------------|---------|
| `LAB\Administrator` | Built-in domain admin |
| `LAB\da_admin` | Extra **domain admin** (member of Domain Admins), also a SQL sysadmin |
| `LAB\alice`, `LAB\bob` | Standard users, in group `Lab Users` |
| `LAB\svc_sql`  | SQL Server service account (own password if you set one; SPNs registered) |

### Group Policy
- **Disable Defender** GPO linked at the domain root, security-filtered to **Authenticated Users**
  (turns off real-time/behavior monitoring across the domain so lab tooling runs unhindered).

## Prerequisites
1. **Windows Server ISO** — you don't have one yet. Grab the free 180-day **evaluation** of
   Windows Server 2022 (or 2025) from Microsoft Evaluation Center. The build page is open in your
   browser. Download the **ISO**, note its path, pass it with `-ServerIso`.
2. **Windows 11 ISO** — already present: `C:\ISOs\Win11_24H2_English_x64.iso`.
3. **Hyper-V** enabled (it is) and you run the script **as Administrator**.
4. ~120 GB free (base images + 3 VMs). You have plenty on D:.

## Run it
Open **PowerShell as Administrator**, then:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\Build-ADLab.ps1 -ServerIso "C:\ISOs\<server-eval>.iso"
```

You'll be prompted for:
- a lab password (used for all accounts; needs upper + lower + digit, 8+ chars), and
- an optional separate password for `svc_sql` (Enter to reuse the first).

The script is **idempotent** — re-run it and it skips anything already done. It uses PowerShell
Direct (no network needed to configure the VMs), so it works even before the domain is up.

Skip SQL (faster first build) with `-SkipSql`. Point SQL at WS02 instead with `-SqlHost WS02`.

Expect **45–90 min** the first time (building base images + SQL install).

## Verify
At the end the script prints the computers in AD. To check by hand, open **DC01** in Hyper-V
Manager, sign in as `LAB\da_admin`, and run:
```powershell
Get-ADComputer -Filter *                         # WS01, WS02 present
Get-ADUser -Filter * | ft Name,Enabled           # alice, bob, da_admin, svc_sql
certutil -ping                                    # CA responding
Invoke-Sqlcmd -ServerInstance WS01 -Query "SELECT @@VERSION"   # SQL up (run on WS01)
```

## Tear it down
```powershell
.\Destroy-ADLab.ps1            # removes VMs, disks, switch, NAT
.\Destroy-ADLab.ps1 -KeepBase # keep base VHDs for a fast rebuild
```

## Notes / knobs
- Everything parameterized at the top of `Build-ADLab.ps1`: `-LabPath`, `-DomainName`,
  `-Subnet`, `-SqlHost`, `-SqlBootstrapUrl`.
- If the SQL download link ever 404s, download SQL Server 2022 **Developer** media yourself and
  drop the `SQLServer2022-x64-ENU-*.exe` into `D:\ADLab\Media\SQL\` before running.
- The Win11 clients get a virtual TPM + Secure Boot so 24H2 installs cleanly.
```
