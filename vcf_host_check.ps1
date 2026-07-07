<#
==========================================================================================
 Author:      Karl Newick (WEI – Manager, Infrastructure Engineering)
 Created:     2025
 Script Name: ESXi Pre-VCF9 Validation & Remediation Tool

 Purpose:
    This script validates and corrects ESXi host settings BEFORE VMware Cloud
    Foundation (VCF) 9.x deployment. Proper DNS, NTP, hostname, and certificate
    configuration is mandatory for successful VCF bring-up.

    The tool performs:
      • DNS verification and correction
      • NTP server and NTP service policy compliance checks
      • Hostname + FQDN consistency validation
      • Self-signed certificate CN inspection and regeneration (if required)
      • Optional remediation mode (-Remediate)
      • Optional verbose debug mode (-DebugOutput)
      • Pre-VCF revert mode (-Revert): hard power-off all VMs, wipe vSAN,
        and migrate host networking from vDS back to a standard vSwitch
        with only vmnic0 attached (restores bare-metal ESXi state)

 Requirements:
    • Windows PowerShell 5.1 or PowerShell 7.x
    • VCF.PowerCLI 9.1.0 or newer (https://developer.broadcom.com/powercli)
        Install-Module -Name VCF.PowerCLI
        - Required modules:
            VMware.VimAutomation.Core
#>

# =====================================================================
# CONFIGURATION — this script reads configuration from tools/vars.ps1
# Copy tools/vars.example.ps1 → tools/vars.ps1 and edit values for
# your environment. Do NOT commit secrets into the repository.
# =====================================================================

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$varsFile = Join-Path $scriptDir 'tools\vars.ps1'
$varsExample = Join-Path $scriptDir 'tools\vars.example.ps1'
if (Test-Path $varsFile) {
    . $varsFile
} else {
    if (Test-Path $varsExample) { . $varsExample }
    Write-Host "Using tools/vars.example.ps1 — copy to tools/vars.ps1 and edit for your environment before running." -ForegroundColor Yellow
}

# Obtain credentials safely (avoid hard-coded passwords in public repos)
if (-not $cred) {
    if ($env:VCF_ESXI_USER -and $env:VCF_ESXI_PASS) {
        $sec = ConvertTo-SecureString $env:VCF_ESXI_PASS -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential($env:VCF_ESXI_USER,$sec)
    } else {
        $cred = Get-Credential -UserName 'root' -Message 'Enter ESXi root credential'
    }
}

$pass = $cred.GetNetworkCredential().Password

# =====================================================================
# FUNCTION: Retrieve ESXi Certificate Subject (replacement for old Get-VMHostCertificate)
# =====================================================================
function Get-EsxiCertificateCN {
    param([string]$HostName)

    try {
        $tcp = New-Object System.Net.Sockets.TcpClient($HostName, 443)
        $ssl = New-Object System.Net.Security.SslStream(
            $tcp.GetStream(), $false, ({ $true })
        )

        $ssl.AuthenticateAsClient($HostName)
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)
        $tcp.Close()

        return $cert.Subject
    }
    catch {
        return $null
    }
}

# =====================================================================
# FUNCTION: Extract only the CN hostname (clean output)
# =====================================================================
function Get-CNClean {
    param([string]$Subject)

    if (-not $Subject) { return $null }

    # Split on commas and look for CN=
    $parts = $Subject -split ","

    foreach ($p in $parts) {
        $p = $p.Trim()
        if ($p -match "^CN=") {
            return $p.Replace("CN=", "").Trim()
        }
    }

    return $null
}

# =====================================================================
# FUNCTION: Read a property value from an object using one of several names
# =====================================================================
function Get-PropertyValue {
    param(
        [object]$InputObject,
        [string[]]$PropertyNames
    )

    if (-not $InputObject) { return $null }

    foreach ($propertyName in $PropertyNames) {
        $property = $InputObject.PSObject.Properties[$propertyName]
        if ($property) {
            return $property.Value
        }
    }

    return $null
}

# =====================================================================
# FUNCTION: Normalize validation output for display
# =====================================================================
function Get-ValidationStatus {
    param(
        [object]$ActualValue,
        [object]$ExpectedValue
    )

    if ($ExpectedValue -is [System.Array]) {
        if ($ExpectedValue.Count -eq 0) { return "NotConfigured" }
        return if ($ActualValue -in $ExpectedValue) { "Match" } else { "Mismatch" }
    }

    if ($null -eq $ExpectedValue) { return "NotConfigured" }
    if ($ExpectedValue -is [string] -and [string]::IsNullOrWhiteSpace($ExpectedValue)) { return "NotConfigured" }

    return if ([string]$ActualValue -eq [string]$ExpectedValue) { "Match" } else { "Mismatch" }
}

# =====================================================================
# FUNCTION: Regenerate ESXi self-signed cert via SSH (replaces removed Set-VMHostCertificate)
# =====================================================================
function Invoke-ESXiCertRegen {
    param(
        [object]$VMHost,
        [string]$HostName,
        [string]$Password
    )

    if (-not (Get-Module -ListAvailable -Name Posh-SSH -ErrorAction SilentlyContinue)) {
        Write-Host "    Installing Posh-SSH module..." -ForegroundColor DarkGray
        try {
            Install-Module Posh-SSH -Scope CurrentUser -Force -Confirm:$false -ErrorAction Stop | Out-Null
        } catch {
            Write-Host "   ❌ Cannot install Posh-SSH. Manual fix: SSH to $HostName and run /sbin/generate-certificates" -ForegroundColor Red
            return $false
        }
    }
    Import-Module Posh-SSH -ErrorAction SilentlyContinue

    $sshSvc        = Get-VMHostService -VMHost $VMHost | Where-Object { $_.Key -eq "TSM-SSH" }
    $sshWasRunning = $sshSvc.Running

    if (-not $sshWasRunning) {
        Write-Host "    Enabling SSH service temporarily..." -ForegroundColor DarkGray
        Start-VMHostService -HostService $sshSvc -Confirm:$false | Out-Null
        Start-Sleep -Seconds 2
    }

    $success = $false
    try {
        $secPass = ConvertTo-SecureString $Password -AsPlainText -Force
        $sshCred = New-Object PSCredential("root", $secPass)
        $sshSess = New-SSHSession -ComputerName $HostName -Credential $sshCred -AcceptKey -Force -ErrorAction Stop

        # Set FQDN on the host first — generate-certificates uses the configured hostname as CN
        Invoke-SSHCommand -SessionId $sshSess.SessionId -Command "esxcli system hostname set --fqdn=$HostName" -TimeOut 15 | Out-Null

        $cmd = Invoke-SSHCommand -SessionId $sshSess.SessionId -Command "/sbin/generate-certificates" -TimeOut 30
        Remove-SSHSession -SessionId $sshSess.SessionId | Out-Null

        if ($cmd.ExitStatus -eq 0) {
            Write-Host "   ✔ Certificate regenerated with CN=$HostName. A reboot is required for hostd to load the new cert." -ForegroundColor Green
            $success = $true
        } else {
            Write-Host "   ⚠ generate-certificates exited $($cmd.ExitStatus): $($cmd.Error)" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "   ❌ SSH cert regeneration failed: $_" -ForegroundColor Red
    } finally {
        if (-not $sshWasRunning) {
            Stop-VMHostService -HostService $sshSvc -Confirm:$false | Out-Null
        }
    }

    return $success
}

# =====================================================================
# FUNCTION: Revert host networking — vDS → standard switch via SSH
# Migrates vmk0 back to a new vSwitch0 with only vmnic0 as the uplink.
# The connectivity-disrupting steps are backgrounded so the SSH session
# can return cleanly before the interface move drops the connection.
# =====================================================================
function Invoke-ESXiNetworkRevert {
    param(
        [object]$VMHost,
        [string]$HostName,
        [string]$Password,
        [string]$VDSName,
        [string]$MgmtVlanId
    )

    Import-Module Posh-SSH -ErrorAction SilentlyContinue

    $sshSvc = Get-VMHostService -VMHost $VMHost | Where-Object { $_.Key -eq "TSM-SSH" }
    $sshWas = $sshSvc.Running
    if (-not $sshWas) {
        Start-VMHostService -HostService $sshSvc -Confirm:$false | Out-Null
        Start-Sleep -Seconds 2
    }

    # Capture vmk0 IP before disrupting anything — PowerCLI is still connected at this point
    $vmk0 = Get-VMHostNetworkAdapter -VMHost $VMHost | Where-Object { $_.Name -eq "vmk0" }
    $vmk0IP      = $vmk0.IP
    $vmk0Netmask = $vmk0.SubnetMask
    $vmk0GW      = (Get-VMHostNetwork -VMHost $VMHost).VMKernelDefaultGateway

    if (-not $vmk0IP) {
        Write-Host "  ❌ Could not read vmk0 IP from host — aborting network revert." -ForegroundColor Red
        return $false
    }
    Write-Host "  ℹ vmk0: IP=$vmk0IP  Mask=$vmk0Netmask  GW=$vmk0GW" -ForegroundColor DarkCyan

    $secPass = ConvertTo-SecureString $Password -AsPlainText -Force
    $sshCred = New-Object PSCredential("root", $secPass)

    try {
        $sshSess = New-SSHSession -ComputerName $HostName -Credential $sshCred -AcceptKey -Force -ErrorAction Stop

        # Build a shell script that runs in the background.
        # All connectivity-disrupting commands are inside the subshell so that
        # even if the SSH session drops mid-flight the commands complete on the host.
        $bgScript = @"
(
  esxcli network vswitch standard add -v vSwitch0 2>/dev/null
  esxcli network vswitch standard portgroup add -v vSwitch0 -p 'Management Network' 2>/dev/null
  esxcli network vswitch standard portgroup set -p 'Management Network' --vlan-id $MgmtVlanId

  # Remove non-management vmkernel adapters before pulling the vDS
  for vmk in vmk1 vmk2 vmk3 vmk4 vmk5; do
    esxcli network ip interface remove -i \$vmk 2>/dev/null
  done

  # Move vmnic0 off the vDS onto the standard switch
  esxcli network vswitch dvs vmware uplink remove --dvs-name '$VDSName' --uplink-name vmnic0 2>/dev/null
  esxcli network vswitch standard uplink add -v vSwitch0 -u vmnic0

  # Migrate vmk0 — brief loss of connectivity here
  esxcli network ip interface remove -i vmk0
  esxcli network ip interface add -i vmk0 -p 'Management Network'
  esxcli network ip interface ipv4 set -i vmk0 -t static -I $vmk0IP -N $vmk0Netmask -g $vmk0GW
) &
"@

        Write-Host "  🔧 Issuing background network revert — connectivity will drop briefly..." -ForegroundColor DarkYellow
        Invoke-SSHCommand -SessionId $sshSess.SessionId -Command $bgScript -TimeOut 10 -ErrorAction SilentlyContinue | Out-Null
        Remove-SSHSession -SessionId $sshSess.SessionId -ErrorAction SilentlyContinue | Out-Null
    }
    catch {
        Write-Host "  ❌ SSH session failed: $_" -ForegroundColor Red
        return $false
    }

    # Poll until port 443 responds — host is back when management vmk is up
    Write-Host "  ⏳ Waiting for $HostName to come back online (up to 90s)..." -ForegroundColor DarkGray
    $deadline = (Get-Date).AddSeconds(90)
    $back = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        $test = Test-NetConnection -ComputerName $HostName -Port 443 -WarningAction SilentlyContinue
        if ($test.TcpTestSucceeded) { $back = $true; break }
    }

    if ($back) {
        Write-Host "  ✔ $HostName is reachable on port 443 — network revert complete." -ForegroundColor Green
    } else {
        Write-Host "  ⚠ $HostName did not respond within 90s. Verify manually." -ForegroundColor Yellow
    }
    return $back
}

# =====================================================================
# LOAD POWERCLI — fast path: skip everything if already loaded.
# Checks for the specific module this script uses (VMware.VimAutomation.Core)
# rather than the VCF.PowerCLI meta-module, which may not be visible in the
# current edition's module path even when PowerCLI is installed. Only installs
# when the module is genuinely absent.
# =====================================================================
$coreModule = "VMware.VimAutomation.Core"

if (-not (Get-Module -Name $coreModule)) {
    if (Get-Module -ListAvailable -Name $coreModule) {
        Write-Host "Loading PowerCLI ($coreModule)..." -ForegroundColor DarkGray
        Import-Module $coreModule -ErrorAction Stop
    }
    else {
        Write-Host "PowerCLI not found — installing VCF.PowerCLI (one-time download)..." -ForegroundColor Yellow
        Install-Module -Name VCF.PowerCLI -Scope CurrentUser -Force -Confirm:$false
        Import-Module $coreModule -ErrorAction Stop
    }
}

Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null

$results = @()

# ---------------------------------------------------------------------
# PRE-FLIGHT: Collect host times in parallel (PowerShell 7+), so later
# operations (enabling SSH, remediation) cannot change host clock while
# we measure drift. Falls back to sequential collection on older PS.
# ---------------------------------------------------------------------
$PrecomputedTimeMap = @{}

Write-Host "\nGathering host times (parallel where available) to avoid task interference..." -ForegroundColor DarkCyan

if ($PSVersionTable.PSVersion.Major -ge 7) {
    try {
        # Use Start-ThreadJob for robust parallelism across PS editions
        $jobs = @()
        foreach ($h in $ESXiHosts) {
            $j = Start-ThreadJob -Name $h -ArgumentList $h,$cred,$pass,$MaxAllowedDriftSeconds -ScriptBlock {
                param($esxHost,$cred,$pass,$MaxAllowedDriftSeconds)
                try { Import-Module VMware.VimAutomation.Core -ErrorAction SilentlyContinue } catch {}
                Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null

                $hostTime = $null
                try {
                    $session = Connect-VIServer -Server $esxHost -Credential $cred -ErrorAction Stop -WarningAction SilentlyContinue
                    $vmhost = Get-VMHost -Server $session
                    $view = Get-View -Id $vmhost.ExtensionData.MoRef -ErrorAction Stop
                    if ($view -and $view.ConfigManager -and $view.ConfigManager.DateTimeSystem) {
                        try { $dateSys = Get-View -Id $view.ConfigManager.DateTimeSystem -ErrorAction Stop; $dt = $dateSys.QueryDateTime(); if ($dt -is [datetime]) { $hostTime = $dt } elseif ($dt -is [string]) { $hostTime = [datetime]::Parse($dt) } elseif ($dt -ne $null -and $dt.PSObject.Properties['dateTime']) { $hostTime = [datetime]$dt.dateTime } else { $hostTime = [datetime]$dt } } catch {}
                    }
                } catch {}

                if (-not $hostTime) {
                    try {
                        if (-not (Get-Module -ListAvailable -Name Posh-SSH)) { Install-Module Posh-SSH -Scope CurrentUser -Force -Confirm:$false -ErrorAction SilentlyContinue }
                        Import-Module Posh-SSH -ErrorAction SilentlyContinue
                        $secPass = ConvertTo-SecureString $pass -AsPlainText -Force
                        $sshCred = New-Object PSCredential('root',$secPass)
                        $sshSess = $null
                        try { $sshSess = New-SSHSession -ComputerName $esxHost -Credential $sshCred -AcceptKey -Force -ErrorAction Stop } catch {}
                        if ($sshSess) {
                            $cmd = Invoke-SSHCommand -SessionId $sshSess.SessionId -Command "date +%s" -TimeOut 15 -ErrorAction SilentlyContinue
                            if ($cmd) {
                                $rawOut = if ($cmd.Output -is [System.Array]) { ($cmd.Output -join "`n").Trim() } else { $cmd.Output }
                                $clean = ($rawOut -replace '[^0-9]','').Trim()
                                if ($clean -and ($clean -match '^\d+$')) {
                                    try { $epoch = [double]$clean; $hostTime = ([DateTimeOffset]::FromUnixTimeSeconds([long]$epoch)).ToLocalTime().DateTime } catch {}
                                } else { try { $hostTime = [datetime]::Parse($rawOut) } catch {} }
                            }
                            try { Remove-SSHSession -SessionId $sshSess.SessionId | Out-Null } catch {}
                        }
                    } catch {}
                }

                if ($hostTime) { $localTime = Get-Date; $drift = [math]::Round([math]::Abs(($localTime - $hostTime).TotalSeconds),2); return [PSCustomObject]@{ HostName = $esxHost; HostTime = $hostTime; TimeDriftSeconds = $drift; TimeDriftOK = ($drift -le [int]$MaxAllowedDriftSeconds) } }
                return [PSCustomObject]@{ HostName = $esxHost; HostTime = $null; TimeDriftSeconds = 'Unknown'; TimeDriftOK = 'Unknown' }
            }
            $jobs += $j
        }

        # Wait for jobs to finish (with a reasonable timeout)
        $wait = Wait-Job -Job $jobs -Timeout 60
        $timeResults = Receive-Job -Job $jobs -ErrorAction SilentlyContinue
        Remove-Job -Job $jobs -Force -ErrorAction SilentlyContinue

        foreach ($t in $timeResults) { $PrecomputedTimeMap[$t.HostName] = $t }
    } catch {
        Write-Host "  ⚠ Parallel time collection failed; falling back to sequential." -ForegroundColor Yellow
        Write-Host "  [DEBUG] Parallel error: $_" -ForegroundColor DarkGray
        $timeResults = $null
    }
}

if (-not $timeResults) {
    foreach ($esxHost in $ESXiHosts) {
        $hostTime = $null
            try {
                $session = Connect-VIServer -Server $esxHost -Credential $cred -ErrorAction Stop -WarningAction SilentlyContinue
                $vmhost = Get-VMHost -Server $session
                $view = Get-View -Id $vmhost.ExtensionData.MoRef -ErrorAction Stop
                if ($view -and $view.ConfigManager -and $view.ConfigManager.DateTimeSystem) {
                    try {
                        $dateSys = Get-View -Id $view.ConfigManager.DateTimeSystem -ErrorAction Stop
                        $dt = $dateSys.QueryDateTime()
                        if ($dt -is [datetime]) { $hostTime = $dt }
                        elseif ($dt -is [string]) { $hostTime = [datetime]::Parse($dt) }
                        elseif ($dt -ne $null -and $dt.PSObject.Properties['dateTime']) { $hostTime = [datetime]$dt.dateTime }
                        else { $hostTime = [datetime]$dt }
                    } catch {
                        # ignore and let SSH fallback handle it
                    }
                }
            } catch {
                Write-Host "  [PRE-FLIGHT] vSphere view read failed for $($esxHost): $($_)" -ForegroundColor DarkGray
            }

        if (-not $hostTime) {
            try {
                if (-not (Get-Module -ListAvailable -Name Posh-SSH)) { Install-Module Posh-SSH -Scope CurrentUser -Force -Confirm:$false -ErrorAction SilentlyContinue }
                Import-Module Posh-SSH -ErrorAction SilentlyContinue
                $secPass = ConvertTo-SecureString $pass -AsPlainText -Force
                $sshCred = New-Object PSCredential('root',$secPass)
                $sshSess = $null
                try { $sshSess = New-SSHSession -ComputerName $esxHost -Credential $sshCred -AcceptKey -Force -ErrorAction Stop } catch {}
                if ($sshSess) {
                    $cmd = Invoke-SSHCommand -SessionId $sshSess.SessionId -Command "date +%s" -TimeOut 15 -ErrorAction SilentlyContinue
                    if ($cmd) {
                        $rawOut = if ($cmd.Output -is [System.Array]) { ($cmd.Output -join "`n").Trim() } else { $cmd.Output }
                        $rawErr = if ($cmd.Error -is [System.Array]) { ($cmd.Error -join "`n").Trim() } else { $cmd.Error }
                        $clean = ($rawOut -replace '[^0-9]','').Trim()
                        Write-Host "  [PRE-FLIGHT] SSH date output for $($esxHost): '$rawOut' -> cleaned '$clean'" -ForegroundColor DarkGray
                        if ($rawErr) { Write-Host "  [PRE-FLIGHT] SSH date error for $($esxHost): '$rawErr'" -ForegroundColor DarkGray }

                        if ($clean -and ($clean -match '^\d+$')) {
                            try {
                                $epoch = [double]$clean
                                try { $hostTime = ([DateTimeOffset]::FromUnixTimeSeconds([long]$epoch)).ToLocalTime().DateTime } catch { $hostTime = $null }
                                Write-Host "  [PRE-FLIGHT] Parsed epoch for $($esxHost): $epoch -> $hostTime" -ForegroundColor DarkGray
                            } catch {
                                Write-Host "  [PRE-FLIGHT] Failed to parse epoch for $($esxHost): $_" -ForegroundColor Yellow
                                try { $hostTime = [datetime]::Parse($rawOut) } catch { $hostTime = $null }
                            }
                        } else {
                            try { $hostTime = [datetime]::Parse($rawOut) } catch { $hostTime = $null }
                        }
                    }
                    try { Remove-SSHSession -SessionId $sshSess.SessionId | Out-Null } catch {}
                } else {
                    Write-Host "  [PRE-FLIGHT] Could not create SSH session for $esxHost." -ForegroundColor DarkGray
                }
            } catch {}
        }

        if ($hostTime) {
            Write-Host "  [PRE-FLIGHT] Host time for $($esxHost) read as $hostTime" -ForegroundColor DarkGray
            $localTime = Get-Date
            $drift = [math]::Round([math]::Abs(($localTime - $hostTime).TotalSeconds),2)
            $PrecomputedTimeMap[$esxHost] = [PSCustomObject]@{ HostName = $esxHost; HostTime = $hostTime; TimeDriftSeconds = $drift; TimeDriftOK = ($drift -le [int]$MaxAllowedDriftSeconds) }
        } else {
            Write-Host "  [PRE-FLIGHT] No time retrieved for $($esxHost); marking Unknown." -ForegroundColor DarkGray
            $PrecomputedTimeMap[$esxHost] = [PSCustomObject]@{ HostName = $esxHost; HostTime = $null; TimeDriftSeconds = 'Unknown'; TimeDriftOK = 'Unknown' }
        }
    }
}


# =====================================================================
# MAIN PROCESSING LOOP
# =====================================================================

foreach ($esxHost in $ESXiHosts) {

    Write-Host "`nConnecting to ESXi Host: $esxHost" -ForegroundColor Cyan

    $ping443 = Test-NetConnection -ComputerName $esxHost -Port 443 -WarningAction SilentlyContinue
    if (-not $ping443.TcpTestSucceeded) {
        Write-Host "❌ $esxHost — port 443 unreachable (host down, DNS failure, or firewall)" -ForegroundColor Red
        continue
    }

    try {
        $session = Connect-VIServer -Server $esxHost -Credential $cred -ErrorAction Stop
        $vmhost  = Get-VMHost -Server $session
    }
    catch {
        Write-Host "❌ Unable to connect to $esxHost — $($_.Exception.Message)" -ForegroundColor Red
        continue
    }

    # -----------------------------------------------------------------
    # Per-host pre-check: read host time immediately to avoid later tasks
    # altering clock; prefer precomputed map, otherwise query now.
    # -----------------------------------------------------------------
    if ($PrecomputedTimeMap.ContainsKey($esxHost) -and $PrecomputedTimeMap[$esxHost].TimeDriftSeconds -ne 'Unknown') {
        $TimeDriftSeconds = $PrecomputedTimeMap[$esxHost].TimeDriftSeconds
        $TimeDriftOK = $PrecomputedTimeMap[$esxHost].TimeDriftOK
    } else {
        $TimeDriftSeconds = 'Unknown'
        $TimeDriftOK = 'Unknown'
        try {
            $hostTime = $null
            try {
                $view = Get-View -Id $vmhost.ExtensionData.MoRef -ErrorAction Stop
                if ($view -and $view.ConfigManager -and $view.ConfigManager.DateTimeSystem) {
                    $dt = $view.ConfigManager.DateTimeSystem.QueryDateTime()
                    if ($dt -is [datetime]) { $hostTime = $dt }
                    elseif ($dt -is [string]) { $hostTime = [datetime]::Parse($dt) }
                    elseif ($dt -ne $null -and $dt.PSObject.Properties['dateTime']) { $hostTime = [datetime]$dt.dateTime }
                    else { $hostTime = [datetime]$dt }
                }
            } catch {}

            if (-not $hostTime) {
                # SSH fallback (temporarily enable SSH if needed)
                try {
                    if (-not (Get-Module -ListAvailable -Name Posh-SSH)) { Import-Module Posh-SSH -ErrorAction SilentlyContinue }
                    $sshSvcTemp = Get-VMHostService -VMHost $vmhost | Where-Object { $_.Key -eq 'TSM-SSH' }
                    $sshWasRunning = $false
                    $sshPrevPolicy = $null
                    if ($sshSvcTemp) { $sshWasRunning = $sshSvcTemp.Running; $sshPrevPolicy = $sshSvcTemp.Policy }

                    if (-not $sshWasRunning -and $sshSvcTemp) { Start-VMHostService -HostService $sshSvcTemp -Confirm:$false | Out-Null; Start-Sleep -Seconds 2 }

                    $secPass = ConvertTo-SecureString $pass -AsPlainText -Force
                    $sshCred = New-Object PSCredential('root',$secPass)
                    $sshSess = $null
                    try { $sshSess = New-SSHSession -ComputerName $esxHost -Credential $sshCred -AcceptKey -Force -ErrorAction Stop } catch {}
                    if ($sshSess) {
                        $cmd = Invoke-SSHCommand -SessionId $sshSess.SessionId -Command "date +%s" -TimeOut 15 -ErrorAction SilentlyContinue
                        if ($cmd) {
                            $rawOut = if ($cmd.Output -is [System.Array]) { ($cmd.Output -join "`n").Trim() } else { $cmd.Output }
                            $rawErr = if ($cmd.Error -is [System.Array]) { ($cmd.Error -join "`n").Trim() } else { $cmd.Error }
                            $clean = ($rawOut -replace '[^0-9]','').Trim()
                            Write-Host "  [PER-HOST] SSH date raw for $($esxHost): '$rawOut' -> cleaned '$clean'" -ForegroundColor DarkGray
                            if ($rawErr) { Write-Host "  [PER-HOST] SSH date error for $($esxHost): '$rawErr'" -ForegroundColor DarkGray }

                            if ($clean -and ($clean -match '^\d+$')) {
                                $epoch = [double]$clean
                                try { $hostTime = ([DateTimeOffset]::FromUnixTimeSeconds([long]$epoch)).ToLocalTime().DateTime } catch { $hostTime = $null }
                            } else {
                                try { $hostTime = [datetime]::Parse($rawOut) } catch { $hostTime = $null }
                            }
                        }
                        try { Remove-SSHSession -SessionId $sshSess.SessionId | Out-Null } catch {}
                    }

                    if (-not $sshWasRunning -and $sshSvcTemp) { Stop-VMHostService -HostService $sshSvcTemp -Confirm:$false | Out-Null; if ($sshPrevPolicy) { Set-VMHostService -HostService $sshSvcTemp -Policy $sshPrevPolicy -Confirm:$false | Out-Null } }
                } catch {}
            }

            if ($hostTime) {
                $localTime = Get-Date
                $TimeDriftSeconds = [math]::Round([math]::Abs(($localTime - $hostTime).TotalSeconds),2)
                $TimeDriftOK = ($TimeDriftSeconds -le [int]$MaxAllowedDriftSeconds)
                $PrecomputedTimeMap[$esxHost] = [PSCustomObject]@{ HostName = $esxHost; HostTime = $hostTime; TimeDriftSeconds = $TimeDriftSeconds; TimeDriftOK = $TimeDriftOK }
            }
        } catch {
            $TimeDriftSeconds = 'Unknown'
            $TimeDriftOK = 'Unknown'
        }
    }

    # -------------------------
    # DNS VALIDATION
    # -------------------------
    $net = Get-VMHostNetwork -VMHost $vmhost
    $DetectedHostName = $net.HostName
    $ExpectedHostName = ($esxHost -split '\.')[0]
    $CurrentDNS = $net.DnsAddress
    $DNS_Servers = $CurrentDNS -join ", "

    $DNSMatches = (($CurrentDNS | Sort-Object) -join ",") -eq (($CorrectDNS | Sort-Object) -join ",")

    # -------------------------
    # CERTIFICATE VALIDATION
    # -------------------------
    $CertSubject = Get-EsxiCertificateCN -HostName $esxHost
    $CertCN      = Get-CNClean -Subject $CertSubject

    if (-not $CertCN) { $CertCN = "Unable to retrieve" }

    $ExpectedFQDN = $esxHost
    $HostNameMatches = ($DetectedHostName -eq $ExpectedHostName)
    $CertMatchesFQDN = ($CertCN -eq $ExpectedFQDN)

    # -------------------------
    # REVERSE DNS VALIDATION
    # -------------------------
    $ReverseDNS = "Unable to resolve"
    $ReverseDNSMatches = $false

    # -------------------------
    # NTP VALIDATION
    # -------------------------
    $ntpService = Get-VMHostService -VMHost $vmhost | Where-Object {$_.Key -eq "ntpd"}
    $NTP_Status = if ($ntpService.Running) { "Running" } else { "Stopped" }
    $NTP_PolicyCorrect = ($ntpService.Policy -eq "on")

    # -------------------------
    # SSH VALIDATION
    # -------------------------
    $sshService = Get-VMHostService -VMHost $vmhost | Where-Object { $_.Key -eq "TSM-SSH" }
    $SSH_Status = if ($sshService.Running) { "Enabled" } else { "Disabled" }
    $SSH_Policy = $sshService.Policy
    $SSH_PolicyCorrect = ($SSH_Policy -eq "on")

    # -------------------------
    # IPv6 VALIDATION
    # -------------------------
    $IPv6_Status = "Unknown"
    try {
        $esxcliStatus = (Get-EsxCli -VMHost $vmhost -V2).network.ip.get.Invoke()
        $ipv6Enabled = Get-PropertyValue -InputObject $esxcliStatus -PropertyNames @("IPv6Enabled", "Ipv6Enabled", "IPv6 Enabled", "Ipv6 Enabled")

        if ($null -ne $ipv6Enabled) {
            if ($ipv6Enabled -is [bool]) {
                $IPv6_Status = if ($ipv6Enabled) { "Enabled" } else { "Disabled" }
            }
            elseif ($ipv6Enabled -is [string]) {
                $normalizedIpv6 = $ipv6Enabled.Trim().ToLowerInvariant()
                if ($normalizedIpv6 -in @("true", "enabled", "1", "yes")) {
                    $IPv6_Status = "Enabled"
                }
                elseif ($normalizedIpv6 -in @("false", "disabled", "0", "no")) {
                    $IPv6_Status = "Disabled"
                }
            }
            else {
                $IPv6_Status = if ([bool]$ipv6Enabled) { "Enabled" } else { "Disabled" }
            }
        }
    } catch {
        $IPv6_Status = "Unknown"
    }

    # -------------------------
    # MANAGEMENT NETWORK VALIDATION
    # -------------------------
    $MgmtVmk = Get-VMHostNetworkAdapter -VMHost $vmhost | Where-Object { $_.Name -eq "vmk0" } | Select-Object -First 1
    $MgmtIPAddress  = if ($MgmtVmk) { $MgmtVmk.IP } else { $null }
    $MgmtSubnetMask = if ($MgmtVmk) { $MgmtVmk.SubnetMask } else { $null }
    $MgmtMtu        = if ($MgmtVmk) { $MgmtVmk.Mtu } else { $null }
    $MgmtPortGroup  = if ($MgmtVmk) { $MgmtVmk.PortGroupName } else { $null }
    $MgmtVlanId     = "Unknown"

    # Resolve gateway from multiple possible properties on the host network object
    $MgmtGateway = Get-PropertyValue -InputObject $net -PropertyNames @('VMKernelDefaultGateway','VMKernelGateway','DefaultGateway','Gateway','VMKernelGateway')
    if (-not $MgmtGateway) {
        # fallback: attempt to read from vmk0 adapter (some versions expose a gateway property here)
        $MgmtGateway = Get-PropertyValue -InputObject $MgmtVmk -PropertyNames @('DefaultGateway','Gateway')
    }

    if ($MgmtIPAddress) {
        try {
            $ReverseDNS = ([System.Net.Dns]::GetHostEntry($MgmtIPAddress).HostName).TrimEnd('.')
            $ReverseDNSMatches = ($ReverseDNS -ieq $ExpectedFQDN)
        } catch {
            $ReverseDNS = "Unable to resolve"
            $ReverseDNSMatches = $false
        }
    }

    if ($MgmtPortGroup) {
        try {
            $MgmtPortGroupObj = Get-VirtualPortGroup -VMHost $vmhost -Name $MgmtPortGroup -ErrorAction Stop | Select-Object -First 1
            if ($null -ne $MgmtPortGroupObj -and $null -ne $MgmtPortGroupObj.VLanId) {
                $MgmtVlanId = [string]$MgmtPortGroupObj.VLanId
            }
        } catch {
            $MgmtVlanId = "Unknown"
        }
    }

    # -------------------------
    # ESXI VERSION / BUILD VALIDATION
    # -------------------------
    $ESXiVersion = $vmhost.Version
    $ESXiBuild   = $vmhost.Build
    $RebootRequired    = [bool]$vmhost.ExtensionData.Summary.RebootRequired
    $RebootReason      = $vmhost.ExtensionData.Summary.RebootRequiredReason

    try {
        $CurrentNTP = Get-VMHostNtpServer -VMHost $vmhost
    } catch { 
        $CurrentNTP = @() 
    }

    $NTP_Servers = $CurrentNTP -join ", "

    $ResolvedNTP = foreach ($srv in $CurrentNTP) {
        try { [System.Net.Dns]::GetHostAddresses($srv).IPAddressToString } catch { $srv }
    }

    $NTP_ResolvedIPs = $ResolvedNTP -join ", "
    $NTPMatches = (($ResolvedNTP | Sort-Object) -join ",") -eq (($CorrectNTP | Sort-Object) -join ",")

    # -------------------------
    # vSAN DISK CHECK (ESXCLI — detects orphaned/unmounted disks missed by Get-VsanDiskGroup)
    # -------------------------
    $vsanDisks          = @()
    $vsanDiskGroupNames = @()
    $vsanFound          = $false
    $esxcli             = $null

    try {
        $esxcli    = Get-EsxCli -VMHost $vmhost -V2
        # Filter out empty placeholder rows ESXCLI returns when no vSAN disks exist
        $vsanDisks = @($esxcli.vsan.storage.list.Invoke() | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Device) })

        if ($vsanDisks.Count -gt 0) {
            $vsanFound         = $true
            # IsCapacityTier is returned as a string "True"/"False" by ESXCLI v2 — use string comparison
            $vsanCacheDisks    = @($vsanDisks | Where-Object { [string]$_.IsCapacityTier -eq "False" })
            $vsanCapacityDisks = @($vsanDisks | Where-Object { [string]$_.IsCapacityTier -eq "True" })
            $vsanDiskGroupNames = @($vsanCacheDisks | Select-Object -ExpandProperty VSANDiskGroupName -Unique)

            Write-Host "  ⚠ $($vsanDisks.Count) vSAN disk(s) found on $esxHost ($($vsanCacheDisks.Count) cache, $($vsanCapacityDisks.Count) capacity)" -ForegroundColor Yellow
            foreach ($dgName in $vsanDiskGroupNames) {
                $dgCache    = @($vsanCacheDisks    | Where-Object { $_.VSANDiskGroupName -eq $dgName })
                $dgCapacity = @($vsanCapacityDisks | Where-Object { $_.VSANDiskGroupName -eq $dgName })
                Write-Host "    DiskGroup : $dgName" -ForegroundColor Yellow
                Write-Host "      Cache   : $(($dgCache    | Select-Object -ExpandProperty Device) -join ', ')" -ForegroundColor Yellow
                Write-Host "      Capacity: $(($dgCapacity | Select-Object -ExpandProperty Device) -join ', ')" -ForegroundColor Yellow
            }
            # Show any disks where IsCapacityTier is neither True nor False — dump all properties for diagnosis
            $vsanUnknown = @($vsanDisks | Where-Object { [string]$_.IsCapacityTier -notin "True","False" })
            if ($vsanUnknown.Count -gt 0) {
                Write-Host "    ⚠ $($vsanUnknown.Count) disk(s) with unexpected state — dumping all properties:" -ForegroundColor Yellow
                $vsanUnknown | ForEach-Object {
                    $_.PSObject.Properties | ForEach-Object {
                        Write-Host "      $($_.Name) = $($_.Value)" -ForegroundColor DarkGray
                    }
                    Write-Host ""
                }
            }
        } else {
            Write-Host "  ✔ No vSAN disks detected." -ForegroundColor Green
        }
    } catch {
        Write-Host "  ⚠ Could not query vSAN storage via ESXCLI: $_" -ForegroundColor DarkYellow
    }

    # -------------------------
    # DEBUG OUTPUT
    # -------------------------
    if ($DebugOutput) {
        Write-Host "  [DEBUG] Cert CN         : $CertCN"                   -ForegroundColor DarkGray
        Write-Host "  [DEBUG] Current Host    : $DetectedHostName"         -ForegroundColor DarkGray
        Write-Host "  [DEBUG] Expected Host   : $ExpectedHostName"         -ForegroundColor DarkGray
        Write-Host "  [DEBUG] Expected FQDN   : $ExpectedFQDN"            -ForegroundColor DarkGray
        Write-Host "  [DEBUG] Reverse DNS     : $ReverseDNS"              -ForegroundColor DarkGray
        Write-Host "  [DEBUG] SSH Status      : $SSH_Status"               -ForegroundColor DarkGray
        Write-Host "  [DEBUG] SSH Policy      : $SSH_Policy"               -ForegroundColor DarkGray
        Write-Host "  [DEBUG] IPv6 Status     : $IPv6_Status"              -ForegroundColor DarkGray
        Write-Host "  [DEBUG] Mgmt IP         : $MgmtIPAddress"            -ForegroundColor DarkGray
        Write-Host "  [DEBUG] Mgmt Gateway    : $MgmtGateway"              -ForegroundColor DarkGray
        Write-Host "  [DEBUG] Mgmt VLAN       : $MgmtVlanId"               -ForegroundColor DarkGray
        Write-Host "  [DEBUG] ESXi Version    : $ESXiVersion"              -ForegroundColor DarkGray
        Write-Host "  [DEBUG] ESXi Build      : $ESXiBuild"                -ForegroundColor DarkGray
        Write-Host "  [DEBUG] Reboot Required : $RebootRequired"           -ForegroundColor DarkGray
        Write-Host "  [DEBUG] DNS Current     : $($CurrentDNS -join ',')" -ForegroundColor DarkGray
        Write-Host "  [DEBUG] NTP Current     : $($ResolvedNTP -join ',')" -ForegroundColor DarkGray
    }

    # =====================================================================
    # REMEDIATION
    # =====================================================================
    if ($Remediate) {
        Write-Host "`n=== Remediation enabled for $esxHost ===" -ForegroundColor Yellow
        $remediationPerformed = $false
        $regenOk = $false

        #
        # DNS FIX
        #
        if (-not $DNSMatches) {
            Write-Host "🔧 Fixing DNS servers..." -ForegroundColor DarkYellow
            Get-VMHostNetwork -VMHost $vmhost | Set-VMHostNetwork -DnsAddress $CorrectDNS -DomainName $Domain -Confirm:$false
            $remediationPerformed = $true
        }

        # Always ensure host name and domain name are set — required for FQDN cert CN
        $hostNetwork   = Get-VMHostNetwork -VMHost $vmhost
        $currentHostName = $hostNetwork.HostName
        $currentDomain = $hostNetwork.DomainName
        if (($currentHostName -ne $ExpectedHostName) -or ($currentDomain -ne $Domain)) {
            Write-Host "🔧 Setting host name to $ExpectedHostName and domain to $Domain..." -ForegroundColor DarkYellow
            $hostNetwork | Set-VMHostNetwork -HostName $ExpectedHostName -DomainName $Domain -Confirm:$false
            $remediationPerformed = $true
            $hostNetwork = Get-VMHostNetwork -VMHost $vmhost
            $DetectedHostName = $hostNetwork.HostName
        }

        #
        # CERTIFICATE FIX
        #
        if (-not $CertMatchesFQDN) {
            # Re-read domain after any fixes above to confirm it is set before regenerating
            $verifiedDomain = (Get-VMHostNetwork -VMHost $vmhost).DomainName
            if ([string]::IsNullOrEmpty($verifiedDomain)) {
                Write-Host "❌ Skipping cert regen on $esxHost — domain name is still blank. Set the domain and re-run." -ForegroundColor Red
            } else {
                Write-Host "🔧 Certificate mismatch — regenerating certificate via SSH (domain: $verifiedDomain)..." -ForegroundColor DarkYellow

                $regenOk = Invoke-ESXiCertRegen -VMHost $vmhost -HostName $esxHost -Password $pass

                if ($regenOk) {
                    $remediationPerformed = $true
                    Write-Host "   ⏳ Reboot will be applied at end of remediation." -ForegroundColor Yellow
                }
            }
        }

        #
        # NTP FIX
        #
        if (-not $NTPMatches) {
            Write-Host "🔧 Correcting NTP server configuration..." -ForegroundColor DarkYellow

            foreach ($srv in $CurrentNTP) {
                Remove-VMHostNtpServer -VMHost $vmhost -NtpServer $srv -Confirm:$false
            }

            foreach ($srv in $CorrectNTP) {
                Add-VMHostNtpServer -VMHost $vmhost -NtpServer $srv -Confirm:$false
            }
            $remediationPerformed = $true
        }

        #
        # NTP POLICY FIX
        #
        if (-not $NTP_PolicyCorrect) {
            Write-Host "🔧 Setting NTP Startup Policy to 'on'..." -ForegroundColor DarkYellow
            Set-VMHostService -HostService $ntpService -Policy "on" -Confirm:$false
            $remediationPerformed = $true
        }

        if ($NTP_Status -eq "Stopped") {
            Write-Host "🔧 Starting NTP service..." -ForegroundColor DarkYellow
            Start-VMHostService -HostService $ntpService -Confirm:$false
            $remediationPerformed = $true
        }

        #
        # vSAN DISK REMOVAL (ESXCLI — handles orphaned/unmounted disks)
        #
        if ($vsanFound -and $null -ne $esxcli) {
            Write-Host "`n  ⚠ WARNING: Removing ALL vSAN data on $($vmhost.Name) — disks will be unclaimed." -ForegroundColor Red

            # Capacity disks first, then cache disks, then anything with unexpected tier value
            $removeOrder = @($vsanDisks | Where-Object { [string]$_.IsCapacityTier -eq "True"  }) +
                           @($vsanDisks | Where-Object { [string]$_.IsCapacityTier -ne "True"  })

            foreach ($disk in $removeOrder) {
                $tier = switch ([string]$disk.IsCapacityTier) {
                    "True"  { "capacity" }
                    "False" { "cache   " }
                    default { "unknown  ($($disk.IsCapacityTier))" }
                }
                Write-Host "  🔧 Removing $tier disk: $($disk.Device)..." -ForegroundColor DarkYellow
                try {
                    $esxcli.vsan.storage.remove.Invoke(@{storagedisk = $disk.Device}) | Out-Null
                    Write-Host "  ✔ $($disk.Device) removed from vSAN." -ForegroundColor Green
                    $remediationPerformed = $true
                } catch {
                    # ESXCLI remove failed — fall back to wiping the partition table via SSH
                    Write-Host "  ⚠ ESXCLI remove failed — falling back to partedUtil via SSH..." -ForegroundColor Yellow
                    try {
                        Import-Module Posh-SSH -ErrorAction SilentlyContinue
                        $secPass = ConvertTo-SecureString $pass -AsPlainText -Force
                        $sshCred = New-Object PSCredential("root", $secPass)

                        $sshSvc = Get-VMHostService -VMHost $vmhost | Where-Object { $_.Key -eq "TSM-SSH" }
                        $sshWas = $sshSvc.Running
                        if (-not $sshWas) { Start-VMHostService -HostService $sshSvc -Confirm:$false | Out-Null; Start-Sleep -Seconds 2 }

                        $sshSess = New-SSHSession -ComputerName $esxHost -Credential $sshCred -AcceptKey -Force -ErrorAction Stop
                        Invoke-SSHCommand -SessionId $sshSess.SessionId -Command "partedUtil mklabel /vmfs/devices/disks/$($disk.Device) gpt" -TimeOut 30 | Out-Null
                        Remove-SSHSession -SessionId $sshSess.SessionId | Out-Null

                        if (-not $sshWas) { Stop-VMHostService -HostService $sshSvc -Confirm:$false | Out-Null }
                        Write-Host "  ✔ Partition table wiped on $($disk.Device)." -ForegroundColor Green
                        $remediationPerformed = $true
                    } catch {
                        Write-Host "  ❌ Could not wipe $($disk.Device): $_" -ForegroundColor Red
                    }
                }
            }
        }

        # =====================================================================
        # AUTOMATIC REBOOT AFTER REMEDIATION
        # =====================================================================
        if ($regenOk) {
            Write-Host "`n🔄 Certificate regenerated — initiating reboot on $esxHost..." -ForegroundColor DarkYellow
            try {
                $rebootResult = Restart-VMHost -VMHost $vmhost -Force -Confirm:$false
                Write-Host "✔ Reboot command sent successfully to $esxHost." -ForegroundColor Green
                Start-Sleep -Seconds 2
            } catch {
                Write-Host "❌ Reboot failed for $esxHost : $_" -ForegroundColor Red
            }
        } elseif ($remediationPerformed) {
            Write-Host "ℹ Remediation applied (no reboot required)." -ForegroundColor Cyan
        } else {
            Write-Host "ℹ No remediation actions were needed." -ForegroundColor Cyan
        }
    }

    # =====================================================================
    # SSH SERVICE MANAGEMENT
    # =====================================================================
    if ($EnableSSH -or $DisableSSH) {
        $sshSvc = Get-VMHostService -VMHost $vmhost | Where-Object { $_.Key -eq "TSM-SSH" }
        if ($EnableSSH) {
            if (-not $sshSvc.Running) {
                Write-Host "  🔧 Enabling SSH on $esxHost..." -ForegroundColor DarkYellow
                Start-VMHostService -HostService $sshSvc -Confirm:$false | Out-Null
                Set-VMHostService -HostService $sshSvc -Policy "on" -Confirm:$false | Out-Null
                Write-Host "  ✔ SSH enabled and set to start on boot." -ForegroundColor Green
            } else {
                Write-Host "  ✔ SSH already running on $esxHost." -ForegroundColor Green
            }
        } elseif ($DisableSSH) {
            if ($sshSvc.Running) {
                Write-Host "  🔧 Disabling SSH on $esxHost..." -ForegroundColor DarkYellow
                Stop-VMHostService -HostService $sshSvc -Confirm:$false | Out-Null
                Set-VMHostService -HostService $sshSvc -Policy "off" -Confirm:$false | Out-Null
                Write-Host "  ✔ SSH stopped and set to off." -ForegroundColor Green
            } else {
                Write-Host "  ✔ SSH already stopped on $esxHost." -ForegroundColor Green
            }
        }
    }

    # =====================================================================
    # IPv6 DISABLING ON vmk0
    # =====================================================================
    if ($DisableIPv6OnVmk0) {
        Write-Host "  🔧 Disabling IPv6 on vmk0 for $esxHost..." -ForegroundColor DarkYellow

        try {
            Import-Module Posh-SSH -ErrorAction SilentlyContinue

            $sshSvc = Get-VMHostService -VMHost $vmhost | Where-Object { $_.Key -eq "TSM-SSH" }
            $sshWas = $sshSvc.Running
            
            if (-not $sshWas) {
                Write-Host "    Enabling SSH service temporarily..." -ForegroundColor DarkGray
                Start-VMHostService -HostService $sshSvc -Confirm:$false | Out-Null
                Start-Sleep -Seconds 2
            }

            $secPass = ConvertTo-SecureString $pass -AsPlainText -Force
            $sshCred = New-Object PSCredential("root", $secPass)
            $sshSess = New-SSHSession -ComputerName $esxHost -Credential $sshCred -AcceptKey -Force -ErrorAction Stop

            # Disable IPv6 globally on the host
            $cmd = Invoke-SSHCommand -SessionId $sshSess.SessionId -Command "esxcli network ip set --ipv6-enabled=false" -TimeOut 15

            if ($cmd.ExitStatus -eq 0) {
                Write-Host "  ✔ IPv6 disabled on vmk0." -ForegroundColor Green
                Write-Host "  🔄 IPv6 disabled — initiating reboot on $esxHost..." -ForegroundColor DarkYellow
                try {
                    Restart-VMHost -VMHost $vmhost -Force -Confirm:$false | Out-Null
                    Write-Host "  ✔ Reboot command sent successfully to $esxHost." -ForegroundColor Green
                } catch {
                    Write-Host "  ❌ Reboot failed for $esxHost : $_" -ForegroundColor Red
                }
            } else {
                Write-Host "  ⚠ IPv6 disable returned exit status $($cmd.ExitStatus): $($cmd.Output)" -ForegroundColor Yellow
            }

            Remove-SSHSession -SessionId $sshSess.SessionId | Out-Null

            if (-not $sshWas) {
                Stop-VMHostService -HostService $sshSvc -Confirm:$false | Out-Null
            }
        }
        catch {
            Write-Host "  ❌ Failed to disable IPv6 on vmk0: $_" -ForegroundColor Red
        }
    }

    # =====================================================================
    # REBOOT
    # =====================================================================
    if ($Reboot) {
        Write-Host "  🔄 Rebooting $esxHost (-Reboot)..." -ForegroundColor DarkYellow
        try {
            Restart-VMHost -VMHost $vmhost -Force -Confirm:$false | Out-Null
            Write-Host "  ✔ Reboot initiated for $esxHost." -ForegroundColor Green
        } catch {
            Write-Host "  ❌ Reboot failed for $esxHost : $_" -ForegroundColor Red
        }
    }

    # =====================================================================
    # REVERT — power off VMs, wipe vSAN, revert vDS → standard switch
    # =====================================================================
    if ($Revert) {
        Write-Host "`n=== REVERT: $esxHost ===" -ForegroundColor Magenta
        Write-Host "  ⚠ This will FORCE POWER OFF all VMs, DESTROY all vSAN data, and remove the host from the vDS." -ForegroundColor Red
        $confirm = Read-Host "  Type YES to proceed with full revert on $esxHost"
        if ($confirm -ne "YES") {
            Write-Host "  ⏳ Revert skipped for $esxHost." -ForegroundColor Yellow
            try { Disconnect-VIServer -Server $session -Confirm:$false | Out-Null } catch { }
            continue
        }

        # STEP 1 — Hard power off all VMs
        Write-Host "`n  [1/3] Powering off all VMs on $esxHost..." -ForegroundColor DarkYellow
        $vms = @(Get-VM -Server $session | Where-Object { $_.PowerState -eq 'PoweredOn' })
        if ($vms.Count -eq 0) {
            Write-Host "  ✔ No powered-on VMs found." -ForegroundColor Green
        } else {
            foreach ($vm in $vms) {
                Write-Host "  🔧 Hard power-off: $($vm.Name)..." -ForegroundColor DarkYellow
                try {
                    Stop-VM -VM $vm -Confirm:$false -Kill -ErrorAction Stop | Out-Null
                    Write-Host "  ✔ $($vm.Name) powered off." -ForegroundColor Green
                } catch {
                    Write-Host "  ⚠ Could not power off $($vm.Name): $_" -ForegroundColor Yellow
                }
            }
        }

        # STEP 2 — Wipe vSAN disks (capacity first, then cache/unknown)
        Write-Host "`n  [2/3] Removing vSAN disks on $esxHost..." -ForegroundColor DarkYellow
        if ($vsanFound -and $null -ne $esxcli) {
            $removeOrder = @($vsanDisks | Where-Object { [string]$_.IsCapacityTier -eq "True" }) +
                           @($vsanDisks | Where-Object { [string]$_.IsCapacityTier -ne "True" })

            foreach ($disk in $removeOrder) {
                $tier = if ([string]$disk.IsCapacityTier -eq "True") { "capacity" } else { "cache" }
                Write-Host "  🔧 Removing $tier disk: $($disk.Device)..." -ForegroundColor DarkYellow
                try {
                    $esxcli.vsan.storage.remove.Invoke(@{storagedisk = $disk.Device}) | Out-Null
                    Write-Host "  ✔ $($disk.Device) removed from vSAN." -ForegroundColor Green
                } catch {
                    Write-Host "  ⚠ ESXCLI remove failed — wiping partition table via SSH..." -ForegroundColor Yellow
                    try {
                        Import-Module Posh-SSH -ErrorAction SilentlyContinue
                        $secPass2 = ConvertTo-SecureString $pass -AsPlainText -Force
                        $sshCred2 = New-Object PSCredential("root", $secPass2)
                        $sshSvc2  = Get-VMHostService -VMHost $vmhost | Where-Object { $_.Key -eq "TSM-SSH" }
                        $sshWas2  = $sshSvc2.Running
                        if (-not $sshWas2) { Start-VMHostService -HostService $sshSvc2 -Confirm:$false | Out-Null; Start-Sleep -Seconds 2 }
                        $sshSess2 = New-SSHSession -ComputerName $esxHost -Credential $sshCred2 -AcceptKey -Force -ErrorAction Stop
                        Invoke-SSHCommand -SessionId $sshSess2.SessionId -Command "partedUtil mklabel /vmfs/devices/disks/$($disk.Device) gpt" -TimeOut 30 | Out-Null
                        Remove-SSHSession -SessionId $sshSess2.SessionId | Out-Null
                        if (-not $sshWas2) { Stop-VMHostService -HostService $sshSvc2 -Confirm:$false | Out-Null }
                        Write-Host "  ✔ Partition table wiped on $($disk.Device)." -ForegroundColor Green
                    } catch {
                        Write-Host "  ❌ Could not wipe $($disk.Device): $_" -ForegroundColor Red
                    }
                }
            }
        } else {
            Write-Host "  ✔ No vSAN disks to remove." -ForegroundColor Green
        }

        # STEP 3 — Revert networking vDS → standard switch
        # The function reads vmk0 IP via PowerCLI before issuing SSH commands,
        # so the session must still be active when it is called.
        # After the SSH background command fires and the host comes back up,
        # the PowerCLI session will be stale — disconnect is handled below.
        Write-Host "`n  [3/3] Reverting networking from '$RevertVDSName' to vSwitch0/vmnic0 on $esxHost..." -ForegroundColor DarkYellow
        Invoke-ESXiNetworkRevert -VMHost $vmhost -HostName $esxHost -Password $pass `
                                 -VDSName $RevertVDSName -MgmtVlanId $RevertMgmtVlanId | Out-Null
        try { Disconnect-VIServer -Server $session -Confirm:$false | Out-Null } catch { }

        Write-Host "`n  ✔ Revert complete for $esxHost." -ForegroundColor Magenta
        continue
    }

    # Refresh SSH status after all actions so the report reflects the final state.
    $sshService = Get-VMHostService -VMHost $vmhost | Where-Object { $_.Key -eq "TSM-SSH" }
    if ($sshService) {
        $SSH_Status = if ($sshService.Running) { "Enabled" } else { "Disabled" }
        $SSH_Policy = $sshService.Policy
        $SSH_PolicyCorrect = ($SSH_Policy -eq "on")
    } else {
        $SSH_Status = "Unknown"
        $SSH_Policy = $null
        $SSH_PolicyCorrect = $false
    }

    # -------------------------
    # TIME DRIFT CHECK (use precomputed map if available)
    # -------------------------
    $TimeDriftSeconds = 'Unknown'
    $TimeDriftOK = 'Unknown'

    if ($PrecomputedTimeMap.ContainsKey($esxHost)) {
        $pre = $PrecomputedTimeMap[$esxHost]
        $TimeDriftSeconds = $pre.TimeDriftSeconds
        $TimeDriftOK = $pre.TimeDriftOK
    } else {
        try {
            $hostTime = $null

            # Try using the vSphere view API which reliably exposes DateTimeSystem
            try {
                $view = Get-View -Id $vmhost.ExtensionData.MoRef -ErrorAction Stop
                if ($view -and $view.ConfigManager -and $view.ConfigManager.DateTimeSystem) {
                    $dt = $view.ConfigManager.DateTimeSystem.QueryDateTime()
                    if ($dt -is [datetime]) { $hostTime = $dt }
                    elseif ($dt -is [string]) { $hostTime = [datetime]::Parse($dt) }
                    elseif ($dt -ne $null -and $dt.PSObject.Properties['dateTime']) { $hostTime = [datetime]$dt.dateTime }
                    else { $hostTime = [datetime]$dt }
                }
            } catch {
                # ignore and try SSH fallback below
            }

            # If view didn't work, attempt SSH fallback. If SSH is disabled, enable temporarily.
            if (-not $hostTime) {
                try {
                    if (-not (Get-Module -ListAvailable -Name Posh-SSH)) { Import-Module Posh-SSH -ErrorAction SilentlyContinue }

                    $sshSvcTemp = Get-VMHostService -VMHost $vmhost | Where-Object { $_.Key -eq 'TSM-SSH' }
                    $sshWasRunning = $false
                    $sshPrevPolicy = $null
                    if ($sshSvcTemp) {
                        $sshWasRunning = $sshSvcTemp.Running
                        $sshPrevPolicy = $sshSvcTemp.Policy
                    }

                    if (-not $sshWasRunning) {
                        Write-Host "  ℹ Temporarily enabling SSH on $esxHost to read host time..." -ForegroundColor DarkGray
                        if ($sshSvcTemp) { Start-VMHostService -HostService $sshSvcTemp -Confirm:$false | Out-Null; Start-Sleep -Seconds 3 }
                    }

                    $secPass = ConvertTo-SecureString $pass -AsPlainText -Force
                    $sshCred = New-Object PSCredential('root',$secPass)
                    try {
                        $sshSess = New-SSHSession -ComputerName $esxHost -Credential $sshCred -AcceptKey -Force -ErrorAction Stop
                    } catch {
                        Write-Host "  ⚠ SSH session creation failed: $_" -ForegroundColor Yellow
                        $sshSess = $null
                    }

                    if ($sshSess) {
                        Write-Host "  [DEBUG] SSH session established (id=$($sshSess.SessionId)). Invoking date..." -ForegroundColor DarkGray
                        $cmd = Invoke-SSHCommand -SessionId $sshSess.SessionId -Command "date +%s" -TimeOut 15 -ErrorAction SilentlyContinue
                        # capture output robustly
                        if ($null -ne $cmd) {
                            $rawOut = $null
                            if ($cmd.Output -is [System.Array]) { $rawOut = ($cmd.Output -join "`n").Trim() } else { $rawOut = $cmd.Output }
                            $rawErr = $null
                            if ($cmd.Error -is [System.Array]) { $rawErr = ($cmd.Error -join "`n").Trim() } else { $rawErr = $cmd.Error }
                            $exitStatus = $null
                            if ($cmd | Get-Member -Name ExitStatus -MemberType NoteProperty -ErrorAction SilentlyContinue) { $exitStatus = $cmd.ExitStatus }
                            elseif ($cmd | Get-Member -Name ExitCode -MemberType NoteProperty -ErrorAction SilentlyContinue) { $exitStatus = $cmd.ExitCode }

                            Write-Host "  [DEBUG] SSH date output: '$rawOut'" -ForegroundColor DarkGray
                            if ($rawErr) { Write-Host "  [DEBUG] SSH date error: '$rawErr'" -ForegroundColor DarkGray }
                            Write-Host "  [DEBUG] SSH exit status: $exitStatus" -ForegroundColor DarkGray

                            if ($rawOut -and ($rawOut -match '^\d+$')) {
                                $epoch = $rawOut
                                try { $hostTime = ([DateTimeOffset]::FromUnixTimeSeconds([long]$epoch)).ToLocalTime().DateTime } catch { $hostTime = $null }
                            } elseif ($rawOut) {
                                try { $hostTime = [datetime]::Parse($rawOut) } catch { $hostTime = $null }
                            }
                        }

                        try { Remove-SSHSession -SessionId $sshSess.SessionId | Out-Null } catch {}
                    } else {
                        Write-Host "  ⚠ Skipping SSH date read because SSH session could not be created." -ForegroundColor Yellow
                    }

                    # Restore SSH to previous state if we started it
                    if (-not $sshWasRunning -and $sshSvcTemp) {
                        Write-Host "  ℹ Restoring SSH state on $esxHost (stopping temporary SSH)..." -ForegroundColor DarkGray
                        try { Stop-VMHostService -HostService $sshSvcTemp -Confirm:$false | Out-Null } catch {}
                        if ($sshPrevPolicy) { try { Set-VMHostService -HostService $sshSvcTemp -Policy $sshPrevPolicy -Confirm:$false | Out-Null } catch {} }
                    }
                } catch {
                    # SSH fallback failed; attempt to restore SSH state if needed
                    if (-not $sshWasRunning -and $sshSvcTemp) {
                        try { Stop-VMHostService -HostService $sshSvcTemp -Confirm:$false | Out-Null } catch {}
                        if ($sshPrevPolicy) { try { Set-VMHostService -HostService $sshSvcTemp -Policy $sshPrevPolicy -Confirm:$false | Out-Null } catch {} }
                    }
                }
            }

            if ($hostTime) {
                $localTime = Get-Date
                $TimeDriftSeconds = [math]::Round([math]::Abs(($localTime - $hostTime).TotalSeconds),2)
                $TimeDriftOK = ($TimeDriftSeconds -le [int]$MaxAllowedDriftSeconds)
            }
        } catch {
            $TimeDriftSeconds = 'Unknown'
            $TimeDriftOK = 'Unknown'
        }
    }

    # =====================================================================
    # STORE RESULTS
    # =====================================================================
    $results += [PSCustomObject]@{
        HostName          = $esxHost
        CurrentHostName   = $DetectedHostName
        HostShortName     = $DetectedHostName
        ExpectedHostName  = $ExpectedHostName
        ExpectedFQDN      = $ExpectedFQDN
        HostNameMatches   = $HostNameMatches
        CertificateCN     = $CertCN
        CertMatchesFQDN   = $CertMatchesFQDN
        SSH_Status        = $SSH_Status
        SSH_Policy        = $SSH_Policy
        SSH_PolicyCorrect = $SSH_PolicyCorrect
        IPv6_Status       = $IPv6_Status
        ReverseDNS        = $ReverseDNS
        ReverseDNSMatches = $ReverseDNSMatches
        MgmtIPAddress     = $MgmtIPAddress
        MgmtSubnetMask    = $MgmtSubnetMask
        MgmtMtu           = $MgmtMtu
        MgmtPortGroup     = $MgmtPortGroup
        MgmtGateway       = $MgmtGateway
        MgmtVlanId        = $MgmtVlanId
        DNS_Servers       = $DNS_Servers
        DNS_Matches       = $DNSMatches
        NTP_Servers       = $NTP_Servers
        NTP_ResolvedIPs   = $NTP_ResolvedIPs
        NTP_Matches       = $NTPMatches
        NTP_Status        = $NTP_Status
        NTP_Policy        = $ntpService.Policy
        NTP_PolicyCorrect = $NTP_PolicyCorrect
        ESXiVersion       = $ESXiVersion
        ESXiBuild         = $ESXiBuild
        RebootRequired    = $RebootRequired
        RebootReason      = $RebootReason
        # -------------------------
        # TIME DRIFT CHECK (computed above)
        # -------------------------
        TimeDriftSeconds  = $TimeDriftSeconds
        TimeDriftOK       = $TimeDriftOK
        vSAN_Found        = $vsanFound
        vSAN_DiskCount    = $vsanDisks.Count
        vSAN_DiskGroups   = if ($vsanDiskGroupNames) { $vsanDiskGroupNames -join "; " } else { "None" }
    }

    try { Disconnect-VIServer -Server $session -Confirm:$false | Out-Null } catch { }
}

# =====================================================================
# FINAL OUTPUT
# =====================================================================
Write-Host "`n===== ESXi DNS, NTP, CERT & POLICY CHECK COMPLETE =====" -ForegroundColor Green

$results |
    Select-Object HostName, ExpectedHostName, HostNameMatches, CertificateCN, CertMatchesFQDN, SSH_Status, IPv6_Status, DNS_Matches, NTP_Status, NTP_PolicyCorrect, NTP_Matches |
    Format-Table -Wrap -AutoSize

Write-Host "`n===== ESXi NETWORK & READINESS CHECKS =====" -ForegroundColor Green

$results |
    Select-Object HostName, ReverseDNS, ReverseDNSMatches, MgmtIPAddress, MgmtGateway, MgmtVlanId, ESXiVersion, ESXiBuild, RebootRequired, TimeDriftSeconds, TimeDriftOK |
    Format-Table -Wrap -AutoSize

$csv = ".\ESXi_Validation_and_Remediation_Report.csv"
$results | Export-Csv $csv -NoTypeInformation

Write-Host "`nCSV exported: $csv" -ForegroundColor Yellow