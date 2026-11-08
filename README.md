<p align="center">
  <img src="https://raw.githubusercontent.com/joser14/joser14/main/logo.webp" width="200" alt="GHOSTSHIELD LABS">
  <br><b>GHOSTSHIELD LABS</b>
</p>

# AD-LAB: Active Directory Lab on Hyper-V

An isolated, self-contained Active Directory lab on your own machine, for learning and security practice.
Everything is automated: the script builds the VMs from ISOs, promotes the domain controller, joins the
clients and installs the roles below. **Keep this lab off any production network.** It is deliberately
weakened (Defender off, a service account with SPNs) so that lab tooling runs.

Built for practising the Active Directory attack path from **TCM Security's PJPT**
(Practical Junior Penetration Tester). Attacker box: **Kali on WSL** (see
[Attacker box](#attacker-box-kali-on-wsl)) or the Kali ISO as a Hyper-V VM.

### Default credentials
All domain accounts share one lab password, set in `Run-Build.ps1` (or pass `-LabPassword`).
Change it before use — it's a throwaway lab password; do not reuse it anywhere real.

### Deliberate attack surface (the PJPT path)
- `svc_sql` has a registered SPN → **Kerberoastable**.
- `da_admin` is a **Domain Admin** (target for lateral movement / privilege escalation).
- Defender is disabled via GPO so tooling (Responder, mimikatz, etc.) runs unhindered.
- SQL Server with Windows auth → `xp_cmdshell` / impersonation practice.

## What you get

| VM    | OS                               | IP            | Role |
|-------|----------------------------------|---------------|------|
| DC01  | Windows Server (Desktop Exp.)    | 10.10.10.10   | AD DS (forest `lab.local`), DNS, **AD CS** Enterprise Root CA + Web Enrollment |
| WS01  | Windows 11 Pro                   | 10.10.10.21   | Domain member, **SQL Server 2022** running as `LAB\svc_sql` |
| WS02  | Windows 11 Pro                   | 10.10.10.22   | Domain member |

- **Network:** internal Hyper-V switch `ADLab`, `10.10.10.0/24`. The host is the gateway `10.10.10.1`
  and does NAT so the VMs can reach the internet. There is no bridge to your LAN.
- **Domain:** `lab.local` / NetBIOS `LAB`.

### Accounts (all use the lab password)
| Account        | Purpose |
|----------------|---------|
| `LAB\Administrator` | Built-in domain admin |
| `LAB\da_admin` | Extra **domain admin** (member of Domain Admins), also a SQL sysadmin |
| `LAB\alice`, `LAB\bob` | Standard users, in group `Lab Users` |
| `LAB\svc_sql`  | SQL Server service account (its own password if you set one; SPNs registered) |

### Group Policy
- A **Disable Defender** GPO linked at the domain root, security-filtered to **Authenticated Users**.
  It turns off real-time and behaviour monitoring across the domain so lab tooling runs unhindered.

## Prerequisites
1. **Windows Server ISO.** The free 180-day evaluation of Windows Server 2022 or 2025 from the
   [Microsoft Evaluation Center](https://www.microsoft.com/evalcenter) works. Download the **ISO** and pass
   its path with `-ServerIso`.
2. **Windows 11 ISO** (24H2 or later) from [Microsoft](https://www.microsoft.com/software-download/windows11).
   The script looks for `Downloads\Win11_24H2_English_x64.iso`; pass `-ClientIso <path>` if yours is elsewhere.
   If you leave out `-ServerIso`, it picks the newest ISO in `Downloads` with "server" in its name.
3. **Hyper-V** enabled (Windows 10/11 Pro, Enterprise or Education), and the script run **as Administrator**.
4. About **120 GB** free disk space for the base images and 3 VMs, and 16 GB+ RAM recommended.

## Run it
Open **PowerShell as Administrator**, then:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\Build-ADLab.ps1 -ServerIso "C:\ISOs\SERVER_EVAL.iso"
```

You'll be prompted for:
- a lab password, used for all accounts (upper case, lower case and a digit, 8+ characters), and
- an optional separate password for `svc_sql` (press Enter to reuse the first).

For a fully unattended run (no prompts), pass `-LabPassword` (and optionally `-SqlPassword`), or use the
`Run-Build.ps1` elevated launcher.

The script is **idempotent**: re-run it and it skips anything already done. It uses PowerShell
Direct (no network needed to configure the VMs), so it works even before the domain is up.

Skip SQL (faster first build) with `-SkipSql`. Put SQL on WS02 instead with `-SqlHost WS02`.

Expect **45–90 minutes** the first time (building base images and installing SQL).

## Attacker box (Kali on WSL)
`setup-kali.sh` and `install-kali-tools.sh` set up a Kali WSL distro with a sudo user and the PJPT
toolset (netexec, impacket, Responder, BloodHound, evil-winrm, enum4linux-ng, and more).

```powershell
wsl --install -d kali-linux --no-launch
# then, as root inside the distro, run setup-kali.sh and install-kali-tools.sh
```

**Note on reaching the lab:** WSL2 is NAT'd onto its own network, separate from the Hyper-V
`10.10.10.0/24` lab, so Kali can't reach the DC by default. Either enable host routing between the
two networks (host-side IP forwarding + a route in Kali), try WSL mirrored networking
(`networkingMode=mirrored` in `%USERPROFILE%\.wslconfig`, if it initialises on your host), or run
Kali from the ISO as a Hyper-V VM on the `ADLab` switch for a native `10.10.10.x` address.

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
.\Destroy-ADLab.ps1 -KeepBase  # keeps the base VHDs for a fast rebuild
```

## Notes and options
- Everything is a parameter at the top of `Build-ADLab.ps1`: `-LabPath` (default `D:\ADLab`),
  `-DomainName`, `-Subnet`, `-SqlHost`, `-SqlBootstrapUrl`.
- If the SQL download link ever returns 404, download SQL Server 2022 **Developer** media yourself and
  put the `SQLServer2022-x64-ENU-*.exe` in `<LabPath>\Media\SQL\` before running.
- The Windows 11 clients get a virtual TPM and Secure Boot so 24H2 installs cleanly.

## Responsible use
For learning and authorised testing only. Never connect this lab to a network you don't own.

## Licence
MIT, see [LICENSE](LICENSE).
