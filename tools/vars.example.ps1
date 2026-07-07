<#
Example variables for VCF ESXi preflight scripts.

Copy this file to tools/vars.ps1 and edit values for your environment.
Do NOT commit real credentials or secrets into the public repository.
#>

# List of ESXi host FQDNs — example only
$ESXiHosts = @(
    "esx1.example.com",
    "esx2.example.com"
)

# DNS and NTP servers expected for the environment
$CorrectDNS = @("10.0.0.10","10.0.0.11")
$CorrectNTP = @("0.pool.ntp.org","1.pool.ntp.org")
$Domain     = "example.com"

# Behavior flags (defaults safe for an example/public repo)
# Set to $true to enable actions.
$Remediate = $false
$DebugOutput = $false
$EnableSSH = $false
$DisableSSH = $false
$DisableIPv6OnVmk0 = $false
$Reboot = $false
$Revert = $false

# Optional readiness baselines. Leave empty to skip enforcement and only report values
$ExpectedMgmtGateway   = ""
$ExpectedMgmtVlanId    = ""
$SupportedESXiVersions = @()
$SupportedESXiBuilds   = @()
$MaxAllowedDriftSeconds = 5

# Revert-specific values (only used with -Revert)
$RevertVDSName    = "vcf-mgmt-vds01"
$RevertMgmtVlanId = "1200"

# Authentication: prefer using Get-Credential at runtime or environment variables
# If you must automate, export these in your CI securely (do NOT commit):
# $env:VCF_ESXI_USER = 'root'
# $env:VCF_ESXI_PASS = 'SuperSecretPassword'
