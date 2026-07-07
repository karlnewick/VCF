<#
.SYNOPSIS
    Performs a ping sweep of the planned VCF infrastructure subnets.

.DESCRIPTION
    Tests every usable IP address in each configured subnet and exports
    the results to CSV.

    Network and broadcast addresses are automatically excluded.

.NOTES
    Run from PowerShell 7 for parallel processing.
#>

[CmdletBinding()]
param(
    [string]$OutputPath = ".\VCF-PingSweep-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv",

    [ValidateRange(1, 500)]
    [int]$ThrottleLimit = 50,

    [ValidateRange(100, 10000)]
    [int]$TimeoutMilliseconds = 750
)

$ErrorActionPreference = 'Stop'

# Planned VCF networks
$Networks = @(
    [pscustomobject]@{
        VLAN    = 1280
        Name    = 'OOB-Network-Management'
        Network = '10.11.128.0'
        Prefix  = 26
    }
    [pscustomobject]@{
        VLAN    = 1290
        Name    = 'VCF-Management'
        Network = '10.11.129.0'
        Prefix  = 24
    }
    [pscustomobject]@{
        VLAN    = 1300
        Name    = 'vMotion'
        Network = '10.11.130.0'
        Prefix  = 27
    }
    [pscustomobject]@{
        VLAN    = 1301
        Name    = 'vSAN-Dell-FX2'
        Network = '10.11.130.32'
        Prefix  = 27
    }
    [pscustomobject]@{
        VLAN    = 1310
        Name    = 'Storage-Fabric-A'
        Network = '10.11.131.0'
        Prefix  = 25
    }
    [pscustomobject]@{
        VLAN    = 1311
        Name    = 'Storage-Fabric-B'
        Network = '10.11.131.128'
        Prefix  = 25
    }
    [pscustomobject]@{
        VLAN    = 1320
        Name    = 'NSX-Host-TEP'
        Network = '10.11.132.0'
        Prefix  = 27
    }
    [pscustomobject]@{
        VLAN    = 1321
        Name    = 'NSX-Edge-TEP'
        Network = '10.11.132.32'
        Prefix  = 27
    }
    [pscustomobject]@{
        VLAN    = 1322
        Name    = 'NSX-Edge-Uplink-1'
        Network = '10.11.132.64'
        Prefix  = 28
    }
    [pscustomobject]@{
        VLAN    = 1323
        Name    = 'NSX-Edge-Uplink-2'
        Network = '10.11.132.80'
        Prefix  = 28
    }
    [pscustomobject]@{
        VLAN    = 1324
        Name    = 'NSX-RTEP'
        Network = '10.11.132.96'
        Prefix  = 27
    }
    [pscustomobject]@{
        VLAN    = 1330
        Name    = 'VM-Network'
        Network = '10.11.133.0'
        Prefix  = 24
    }
)

function ConvertTo-IPv4Integer {
    param(
        [Parameter(Mandatory)]
        [string]$IPAddress
    )

    $bytes = [System.Net.IPAddress]::Parse($IPAddress).GetAddressBytes()

    if ([BitConverter]::IsLittleEndian) {
        [Array]::Reverse($bytes)
    }

    return [BitConverter]::ToUInt32($bytes, 0)
}

function ConvertFrom-IPv4Integer {
    param(
        [Parameter(Mandatory)]
        [uint32]$Integer
    )

    $bytes = [BitConverter]::GetBytes($Integer)

    if ([BitConverter]::IsLittleEndian) {
        [Array]::Reverse($bytes)
    }

    return ([System.Net.IPAddress]::new($bytes)).ToString()
}

function Get-UsableIPv4Addresses {
    param(
        [Parameter(Mandatory)]
        [string]$Network,

        [Parameter(Mandatory)]
        [ValidateRange(1, 30)]
        [int]$Prefix
    )

    $networkInteger = ConvertTo-IPv4Integer -IPAddress $Network
    $hostBits       = 32 - $Prefix
    $addressCount   = [math]::Pow(2, $hostBits)
    $broadcast      = [uint32]($networkInteger + $addressCount - 1)

    # Skip network address and broadcast address
    for ($address = $networkInteger + 1; $address -lt $broadcast; $address++) {
        ConvertFrom-IPv4Integer -Integer ([uint32]$address)
    }
}

$SweepTargets = foreach ($network in $Networks) {
    foreach ($ip in Get-UsableIPv4Addresses `
        -Network $network.Network `
        -Prefix $network.Prefix) {

        [pscustomobject]@{
            VLAN   = $network.VLAN
            Name   = $network.Name
            Subnet = "$($network.Network)/$($network.Prefix)"
            IP     = $ip
        }
    }
}

Write-Host "Testing $($SweepTargets.Count) usable IP addresses..." -ForegroundColor Cyan

$Results = $SweepTargets | ForEach-Object -Parallel {
    $target = $_
    $timeout = $using:TimeoutMilliseconds

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $ping = [System.Net.NetworkInformation.Ping]::new()

        try {
            $reply = $ping.Send($target.IP, $timeout)
        }
        finally {
            $ping.Dispose()
        }

        $stopwatch.Stop()

        $online = $reply.Status -eq `
            [System.Net.NetworkInformation.IPStatus]::Success

        [pscustomobject]@{
            Timestamp      = Get-Date
            VLAN           = $target.VLAN
            NetworkName    = $target.Name
            Subnet         = $target.Subnet
            IPAddress      = $target.IP
            Status         = if ($online) { 'Online' } else { 'No Reply' }
            ResponseTimeMs = if ($online) { $reply.RoundtripTime } else { $null }
        }
    }
    catch {
        $stopwatch.Stop()

        [pscustomobject]@{
            Timestamp      = Get-Date
            VLAN           = $target.VLAN
            NetworkName    = $target.Name
            Subnet         = $target.Subnet
            IPAddress      = $target.IP
            Status         = 'Error'
            ResponseTimeMs = $null
        }
    }
} -ThrottleLimit $ThrottleLimit

$Results = $Results |
    Sort-Object VLAN, {
        ConvertTo-IPv4Integer -IPAddress $_.IPAddress
    }

$Results | Export-Csv -Path $OutputPath -NoTypeInformation

$Online = $Results | Where-Object Status -eq 'Online'

Write-Host
Write-Host "Sweep complete." -ForegroundColor Green
Write-Host "Addresses tested : $($Results.Count)"
Write-Host "Responding hosts  : $($Online.Count)"
Write-Host "Results file      : $OutputPath"
Write-Host

$Online |
    Format-Table VLAN, NetworkName, IPAddress, ResponseTimeMs -AutoSize