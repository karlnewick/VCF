**Tools**

This folder contains example variable files and helper scripts for the ESXi
preflight validation and remediation tools.

Quick start:

- Copy `vars.example.ps1` to `vars.ps1` and edit values for your environment.
- Do NOT commit `vars.ps1` — it may contain secrets.
- Run the script from the parent folder, e.g.: `./vcf_esxi_preflight.ps1 -DebugOutput`

Authentication:
- The scripts will prompt for an ESXi `root` credential if none is provided.
- For automation you can set environment variables `VCF_ESXI_USER` and `VCF_ESXI_PASS`
  (use secure CI secret storage — do NOT store plaintext passwords in VCS).

Files:
- `vars.example.ps1` — example configuration you should copy and edit.
