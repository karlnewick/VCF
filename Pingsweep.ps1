<#
.SYNOPSIS
    Performs a ping sweep and reverse DNS lookup for:
    10.11.0.1 through 10.11.109.254

.DESCRIPTION
    Tests every usable IP address in each /24 subnet from:

        10.11.0.0/24
        through
        10.11.109.0/24

    Reverse DNS lookups are performed against:

        10.11.92.23
        10.11.92.24

    The exported CSV only includes addresses that:

        1. Respond to ping
           OR
        2. Have a PTR/DNS record

    Addresses that do not respond and have no PTR record are excluded.

.NOTES
    Requires PowerShell 7 or newer because it uses
    ForEach-Object -Parallel.
#>

[CmdletBinding()]
param(
    [string]$OutputPath = ".\PingSweep-10.11.0-109-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv",

    [ValidateRange(1, 500)]
    [int]$ThrottleLimit = 100,

    [ValidateRange(100, 10000)]
    [int]$TimeoutMilliseconds = 500,

    [string[]]$DnsServers = @(
        '10.11.92.23',
        '10.11.92.24'
    ),

    [switch]$IncludeNetworkAndBroadcast
)

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer.'
}

# ------------------------------------------------------------
# Build target list
# ------------------------------------------------------------

$Targets = foreach ($ThirdOctet in 0..109) {

    $HostRange = if ($IncludeNetworkAndBroadcast) {
        0..255
    }
    else {
        1..254
    }

    foreach ($FourthOctet in $HostRange) {
        [pscustomobject]@{
            Subnet    = "10.11.$ThirdOctet.0/24"
            IPAddress = "10.11.$ThirdOctet.$FourthOctet"
        }
    }
}

Write-Host
Write-Host 'Starting ping and reverse DNS sweep' -ForegroundColor Cyan
Write-Host 'Range             : 10.11.0.0 through 10.11.109.255'
Write-Host "Addresses to test : $($Targets.Count)"
Write-Host "DNS servers       : $($DnsServers -join ', ')"
Write-Host "Ping timeout      : $TimeoutMilliseconds ms"
Write-Host "Parallel threads  : $ThrottleLimit"
Write-Host

$StartTime = Get-Date

# ------------------------------------------------------------
# Ping and DNS sweep
# ------------------------------------------------------------

$Results = $Targets | ForEach-Object -Parallel {

    $Target     = $_
    $Timeout    = $using:TimeoutMilliseconds
    $DnsServers = $using:DnsServers

    # --------------------------------------------------------
    # Ping test
    # --------------------------------------------------------

    $PingStatus     = 'No Reply'
    $ResponseTimeMs = $null
    $PingError      = $null

    $PingClient = [System.Net.NetworkInformation.Ping]::new()

    try {
        $Reply = $PingClient.Send(
            $Target.IPAddress,
            $Timeout
        )

        if (
            $Reply.Status -eq
            [System.Net.NetworkInformation.IPStatus]::Success
        ) {
            $PingStatus     = 'Online'
            $ResponseTimeMs = $Reply.RoundtripTime
        }
        else {
            $PingStatus = $Reply.Status.ToString()
        }
    }
    catch {
        $PingStatus = 'Ping Error'
        $PingError  = $_.Exception.Message
    }
    finally {
        $PingClient.Dispose()
    }

    # --------------------------------------------------------
    # Reverse DNS lookup
    # --------------------------------------------------------

    $PtrRecord     = $null
    $DnsServerUsed = $null
    $DnsStatus     = 'No PTR Record'
    $DnsError      = $null

    foreach ($DnsServer in $DnsServers) {
        try {
            $DnsResult = Resolve-DnsName `
                -Name $Target.IPAddress `
                -Type PTR `
                -Server $DnsServer `
                -DnsOnly `
                -QuickTimeout `
                -ErrorAction Stop

            $PtrRecord = $DnsResult |
                Where-Object {
                    $_.QueryType -eq 'PTR' -and
                    -not [string]::IsNullOrWhiteSpace($_.NameHost)
                } |
                Select-Object `
                    -ExpandProperty NameHost `
                    -First 1

            if (-not [string]::IsNullOrWhiteSpace($PtrRecord)) {
                $PtrRecord     = $PtrRecord.TrimEnd('.')
                $DnsServerUsed = $DnsServer
                $DnsStatus     = 'Resolved'
                $DnsError      = $null
                break
            }
        }
        catch {
            $DnsError = $_.Exception.Message
        }
    }

    # --------------------------------------------------------
    # Return result object
    # --------------------------------------------------------

    [pscustomobject]@{
        Timestamp      = Get-Date
        Subnet         = $Target.Subnet
        IPAddress      = $Target.IPAddress
        PingStatus     = $PingStatus
        ResponseTimeMs = $ResponseTimeMs
        PingError      = $PingError
        PTRRecord      = $PtrRecord
        DNSStatus      = $DnsStatus
        DNSServerUsed  = $DnsServerUsed
        DNSError       = $DnsError
    }

} -ThrottleLimit $ThrottleLimit

# ------------------------------------------------------------
# Sort IP addresses numerically
# ------------------------------------------------------------

$Results = $Results | Sort-Object {
    $Octets = $_.IPAddress.Split('.')

    (
        ([uint64]$Octets[0] -shl 24) -bor
        ([uint64]$Octets[1] -shl 16) -bor
        ([uint64]$Octets[2] -shl 8)  -bor
        ([uint64]$Octets[3])
    )
}

# ------------------------------------------------------------
# Filter results
#
# Keep an address when:
#   - It replied successfully to ping
#     OR
#   - It has a PTR record
#
# Remove an address when:
#   - It did not reply
#     AND
#   - It has no PTR record
# ------------------------------------------------------------

$FilteredResults = $Results | Where-Object {
    $_.PingStatus -eq 'Online' -or
    -not [string]::IsNullOrWhiteSpace($_.PTRRecord)
}

# ------------------------------------------------------------
# Export filtered CSV
# ------------------------------------------------------------

$FilteredResults | Export-Csv `
    -Path $OutputPath `
    -NoTypeInformation `
    -Encoding UTF8

# ------------------------------------------------------------
# Build summary
# ------------------------------------------------------------

$OnlineResults = $FilteredResults |
    Where-Object {
        $_.PingStatus -eq 'Online'
    }

$ResolvedResults = $FilteredResults |
    Where-Object {
        -not [string]::IsNullOrWhiteSpace($_.PTRRecord)
    }

$PingOnlyResults = $FilteredResults |
    Where-Object {
        $_.PingStatus -eq 'Online' -and
        [string]::IsNullOrWhiteSpace($_.PTRRecord)
    }

$DnsOnlyResults = $FilteredResults |
    Where-Object {
        $_.PingStatus -ne 'Online' -and
        -not [string]::IsNullOrWhiteSpace($_.PTRRecord)
    }

$Elapsed = (Get-Date) - $StartTime

# ------------------------------------------------------------
# Display summary
# ------------------------------------------------------------

Write-Host
Write-Host 'Sweep complete.' -ForegroundColor Green
Write-Host "Addresses tested : $($Results.Count)"
Write-Host "Results exported : $($FilteredResults.Count)"
Write-Host "Rows removed     : $($Results.Count - $FilteredResults.Count)"
Write-Host "Ping responses   : $($OnlineResults.Count)"
Write-Host "PTR records found: $($ResolvedResults.Count)"
Write-Host "Ping only        : $($PingOnlyResults.Count)"
Write-Host "DNS only         : $($DnsOnlyResults.Count)"
Write-Host "Elapsed time     : $($Elapsed.ToString('hh\:mm\:ss'))"
Write-Host "Results file     : $OutputPath"
Write-Host

# ------------------------------------------------------------
# Display retained results
# ------------------------------------------------------------

$FilteredResults |
    Select-Object `
        IPAddress,
        PingStatus,
        ResponseTimeMs,
        PTRRecord,
        DNSStatus,
        DNSServerUsed |
    Format-Table -AutoSize