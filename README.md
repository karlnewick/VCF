# ESXi Pre-VCF9 Validation & Remediation Tool

Purpose
- Validate and optionally remediate ESXi host networking, DNS, NTP, SSH, certificates, and readiness prior to VMware Cloud Foundation (VCF) 9.x bring-up.

Quick summary
- Script: [vcf_host_check.ps1](vcf_host_check.ps1)
- Output: CSV report exported to `./ESXi_Validation_and_Remediation_Report.csv`

Prerequisites
- Windows PowerShell 5.1 or PowerShell 7+ (PowerShell 7 recommended for improved parallelism).
- PowerCLI / VCF.PowerCLI installed. The script requires `VMware.VimAutomation.Core`.
  - Install once per user: `Install-Module -Name VCF.PowerCLI -Scope CurrentUser`
- Posh-SSH (installed on-demand by the script for SSH fallbacks).
- Network access to ESXi hosts (TCP 443 + optional SSH 22).
- Credentials with root access to ESXi hosts (the script uses `root`/password for SSH operations).

Important notes
- The script can perform destructive remediation (certificate regeneration, NTP changes, vSAN disk removal, network revert). Use `-Remediate` only when you intend to modify hosts.
- The script temporarily enables SSH when required and restores previous state where possible.
- Pre-flight host time collection is done in parallel (when available) to avoid later remediation changing host clocks.

Recent fixes and behavior
- Replaced fragile `ForEach-Object -Parallel` usage with `Start-ThreadJob` for more robust parallel pre-flight collection across PowerShell editions.
- Epoch conversion now uses `DateTimeOffset::FromUnixTimeSeconds(...)` to reliably convert `date +%s` output into host DateTime values.
- Precomputed host times are stored in a preflight map and used later for TimeDrift reporting where available.

Usage examples
- Dry-run with debug output:

```powershell
Set-Location 'C:\Users\karlnewick\OneDrive - WEI-LAB\Documents\Tools'
.\vcf_host_check.ps1 -DebugOutput
```

- Apply remediation (use with caution):

```powershell
.\vcf_host_check.ps1 -Remediate -DebugOutput
```

Flags you may use
- `-Remediate`: apply fixes (DNS, NTP, hostname, certificate regen, vSAN removal when configured);
- `-DebugOutput`: show verbose debug logging;
- `-Revert`: run the network/vSAN revert flow (destructive — prompts for confirmation);
- `-EnableSSH` / `-DisableSSH`: manage SSH service state as part of the run;
- `-Reboot`: reboot hosts where required after remediation;
- `-DisableIPv6OnVmk0`: attempt to disable IPv6 via SSH and reboot.

Where to look next
- Script: [vcf_host_check.ps1](vcf_host_check.ps1)
- Report CSV: `./ESXi_Validation_and_Remediation_Report.csv`

Contact / notes
- Edit the `ESXiHosts`, `CorrectDNS`, `CorrectNTP`, and `$Domain` variables at the top of the script to match your environment before running.
- I updated the script to fix parallel pre-flight collection and epoch parsing; re-run with `-DebugOutput` to verify `TimeDriftSeconds` values are now populated.
