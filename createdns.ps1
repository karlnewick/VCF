<#
.SYNOPSIS
    Create or delete DNS records in Infoblox CSP (Universal DDI / BloxOne DDI).

.DESCRIPTION
    PowerShell equivalent of the SDDC.Lab CleanupDNS.yml / infoblox_nsupdate workflow.
    Talks directly to the Infoblox CSP DDI REST API (https://csp.infoblox.com/api/ddi/v1).

    Supports A, AAAA, CNAME, and PTR records. For A/AAAA records, use -CreatePtr to
    have Infoblox automatically create the matching PTR record (equivalent to running
    both the A and PTR tasks in the playbook).

    Authentication: pass -Token, or set the INFOBLOX_API_TOKEN environment variable.

.PARAMETER Function
    'new' to create the record, 'delete' to remove it. (Maps to LOCAL_RecordState
    present/absent in the playbook.)

.PARAMETER Type
    Record type: a, aaaa, cname, or ptr.

.PARAMETER Name
    Record name (host portion only, e.g. 'fi-a'). Combined with -Zone to form the FQDN.
    For PTR type, this is still the hostname the PTR should point to.

.PARAMETER IP
    IP address. Required for a/aaaa/ptr. For PTR, the reverse record is derived from
    this address.

.PARAMETER Value
    CNAME target (required only when -Type cname). Can be short name (zone appended)
    or FQDN.

.PARAMETER Zone
    Forward DNS zone. Default: wei-lab.com

.PARAMETER View
    Infoblox DNS view name. Default: lab-mgmt

.PARAMETER Token
    CSP API token. Falls back to $env:INFOBLOX_API_TOKEN.

.PARAMETER CspUrl
    CSP portal URL. Default: https://csp.infoblox.com

.PARAMETER CreatePtr
    When creating an A/AAAA record, also create the matching PTR.

.EXAMPLE
    .\createdns.ps1 -function new -type a -name fi-a -ip 10.11.128.11

.EXAMPLE
    .\createdns.ps1 -function new -type a -name fi-a -ip 10.11.128.11 -CreatePtr

.EXAMPLE
    .\createdns.ps1 -function delete -type a -name fi-a -ip 10.11.128.11

.EXAMPLE
    .\createdns.ps1 -function new -type cname -name router -value router-uplink

.EXAMPLE
    .\createdns.ps1 -function new -type ptr -name fi-a -ip 10.11.128.11
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('new', 'delete')]
    [string]$Function,

    [Parameter(Mandatory = $true)]
    [ValidateSet('a', 'aaaa', 'cname', 'ptr')]
    [string]$Type,

    [Parameter(Mandatory = $true)]
    [string]$Name,

    [Parameter(Mandatory = $false)]
    [string]$IP,

    [Parameter(Mandatory = $false)]
    [string]$Value,

    [Parameter(Mandatory = $false)]
    [string]$Zone = 'wei-lab.com',

    [Parameter(Mandatory = $false)]
    [string]$View = 'lab-mgmt',

    [Parameter(Mandatory = $false)]
    [string]$Token = $env:INFOBLOX_API_TOKEN,

    [Parameter(Mandatory = $false)]
    [string]$CspUrl = 'https://csp.infoblox.com',

    [switch]$CreatePtr,

    [switch]$ResetToken
)

$ErrorActionPreference = 'Stop'
$ApiBase = "$($CspUrl.TrimEnd('/'))/api/ddi/v1"

#region --- Token handling ---------------------------------------------------

$TokenFile = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.infoblox\token.xml'

function Get-IBStoredToken {
    if (Test-Path $TokenFile) {
        try {
            $secure = Import-Clixml -Path $TokenFile
            return [System.Net.NetworkCredential]::new('', $secure).Password
        }
        catch {
            Write-Warning "Stored token at '$TokenFile' could not be decrypted (different user or machine?). It will be ignored."
        }
    }
    return $null
}

function Save-IBToken {
    param([securestring]$SecureToken)
    $dir = Split-Path $TokenFile -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $SecureToken | Export-Clixml -Path $TokenFile
    Write-Host "Token saved (encrypted) to $TokenFile" -ForegroundColor Green
}

if ($ResetToken -and (Test-Path $TokenFile)) {
    Remove-Item $TokenFile -Force
    Write-Host "Stored token removed. You will be prompted for a new one." -ForegroundColor Yellow
}

# Token resolution order: -Token param > env var > encrypted file > interactive prompt
if ([string]::IsNullOrWhiteSpace($Token)) {
    $Token = Get-IBStoredToken
}

if ([string]::IsNullOrWhiteSpace($Token)) {
    if ([Environment]::UserInteractive) {
        $secureInput = Read-Host -Prompt 'Enter Infoblox CSP API token' -AsSecureString
        $Token = [System.Net.NetworkCredential]::new('', $secureInput).Password
        if ([string]::IsNullOrWhiteSpace($Token)) {
            throw "No token entered."
        }
        $answer = Read-Host -Prompt 'Save this token encrypted for future runs? (y/N)'
        if ($answer -match '^[Yy]') {
            Save-IBToken -SecureToken $secureInput
        }
    }
    else {
        throw "No API token available. Use -Token, set INFOBLOX_API_TOKEN, or run interactively once to store it."
    }
}

#endregion

#region --- Validation -------------------------------------------------------

if ($Type -in @('a', 'aaaa', 'ptr') -and [string]::IsNullOrWhiteSpace($IP)) {
    throw "-IP is required for record type '$Type'."
}

if ($Type -eq 'cname' -and [string]::IsNullOrWhiteSpace($Value)) {
    throw "-Value (CNAME target) is required for record type 'cname'."
}

if ($IP) {
    $parsedIp = $null
    if (-not [System.Net.IPAddress]::TryParse($IP, [ref]$parsedIp)) {
        throw "'$IP' is not a valid IP address."
    }
    if ($Type -eq 'a'    -and $parsedIp.AddressFamily -ne 'InterNetwork')   { throw "'$IP' is not an IPv4 address (required for type 'a')." }
    if ($Type -eq 'aaaa' -and $parsedIp.AddressFamily -ne 'InterNetworkV6') { throw "'$IP' is not an IPv6 address (required for type 'aaaa')." }
}

#endregion

#region --- API helpers ------------------------------------------------------

$Headers = @{
    'Authorization' = "Token $Token"
    'Content-Type'  = 'application/json'
}

function Invoke-IBApi {
    param(
        [string]$Method,
        [string]$Path,
        [object]$Body = $null
    )
    $uri = "$ApiBase$Path"
    $params = @{
        Method  = $Method
        Uri     = $uri
        Headers = $Headers
    }
    if ($Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 10)
    }
    try {
        return Invoke-RestMethod @params
    }
    catch {
        $detail = $_.ErrorDetails.Message
        if (-not $detail -and $_.Exception.Response) {
            try {
                $reader = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream())
                $detail = $reader.ReadToEnd()
            } catch { }
        }
        throw "Infoblox API call failed [$Method $uri]: $($_.Exception.Message)`n$detail"
    }
}

function Get-IBView {
    param([string]$ViewName)
    $filter = [uri]::EscapeDataString("name==`"$ViewName`"")
    $result = Invoke-IBApi -Method GET -Path "/dns/view?_filter=$filter"
    if (-not $result.results -or $result.results.Count -eq 0) {
        throw "DNS view '$ViewName' not found in CSP."
    }
    return $result.results[0]
}

function Get-IBAuthZone {
    param(
        [string]$Fqdn,     # zone fqdn WITHOUT trailing dot
        [string]$ViewId
    )
    $filter = [uri]::EscapeDataString("fqdn==`"$Fqdn.`" and view==`"$ViewId`"")
    $result = Invoke-IBApi -Method GET -Path "/dns/auth_zone?_filter=$filter"
    if (-not $result.results -or $result.results.Count -eq 0) {
        throw "Authoritative zone '$Fqdn' not found in view '$View'. Make sure the zone exists in Infoblox before adding records."
    }
    return $result.results[0]
}

function Get-ReverseZoneAndName {
    <#
        Given an IP, returns the reverse zone fqdn and the name_in_zone for the PTR record.
        IPv4 example: 10.11.128.11 -> zone '11.10.in-addr.arpa' (uses /16, matching the
        playbook's Pod.BaseNetwork.IPv4 + '.0.0/16' logic), name '11.128'.
        IPv6: uses a /64 reverse zone boundary by default.
    #>
    param([System.Net.IPAddress]$Address)

    if ($Address.AddressFamily -eq 'InterNetwork') {
        $octets = $Address.ToString().Split('.')
        # /16 reverse zone, same as playbook (BaseNetwork.IPv4 + '.0.0/16')
        $zoneFqdn   = "$($octets[1]).$($octets[0]).in-addr.arpa"
        $nameInZone = "$($octets[3]).$($octets[2])"
    }
    else {
        # Expand IPv6 to full nibble form
        $bytes = $Address.GetAddressBytes()
        $nibbles = @()
        foreach ($b in $bytes) {
            $nibbles += ('{0:x2}' -f $b).ToCharArray()
        }
        [array]::Reverse($nibbles)
        # /64 boundary: last 16 nibbles = host, first 16 = zone
        $nameInZone = ($nibbles[0..15] -join '.')
        $zoneFqdn   = (($nibbles[16..31] -join '.') + '.ip6.arpa')
    }
    return [pscustomobject]@{ ZoneFqdn = $zoneFqdn; NameInZone = $nameInZone }
}

function Find-IBRecord {
    param(
        [string]$NameInZone,     # host portion only
        [string]$RecordType,     # A, AAAA, CNAME, PTR
        [string]$ViewId,         # dns/view/xxxx
        [string]$Fqdn            # full name WITHOUT trailing dot
    )
    $filter = [uri]::EscapeDataString("name_in_zone==`"$NameInZone`" and type==`"$RecordType`"")
    $result = Invoke-IBApi -Method GET -Path "/dns/record?_filter=$filter"
    if (-not $result.results) { return @() }
    return @($result.results | Where-Object {
        $_.view -eq $ViewId -and $_.absolute_name_spec -eq "$Fqdn."
    })
}

#endregion

#region --- Main -------------------------------------------------------------

$recordType = $Type.ToUpper()
Write-Host "Connecting to Infoblox CSP ($CspUrl)..." -ForegroundColor Cyan

$viewObj = Get-IBView -ViewName $View
Write-Verbose "View '$View' -> $($viewObj.id)"

# Work out zone, name-in-zone, rdata, and FQDN based on record type
switch ($Type) {
    'ptr' {
        $rev        = Get-ReverseZoneAndName -Address $parsedIp
        $zoneFqdn   = $rev.ZoneFqdn
        $nameInZone = $rev.NameInZone
        $fqdn       = "$nameInZone.$zoneFqdn"
        $rdata      = @{ dname = "$Name.$Zone." }
    }
    'cname' {
        $zoneFqdn   = $Zone
        $nameInZone = $Name
        $fqdn       = "$Name.$Zone"
        $target     = if ($Value -like '*.*') { "$($Value.TrimEnd('.'))." } else { "$Value.$Zone." }
        $rdata      = @{ cname = $target }
    }
    default {
        # a / aaaa
        $zoneFqdn   = $Zone
        $nameInZone = $Name
        $fqdn       = "$Name.$Zone"
        $rdata      = @{ address = $IP }
    }
}

# Zone lookup is needed for both create and delete (records are searched by zone + name)
$zoneObj = Get-IBAuthZone -Fqdn $zoneFqdn -ViewId $viewObj.id
Write-Verbose "Zone '$zoneFqdn' -> $($zoneObj.id)"

if ($Function -eq 'new') {

    # Idempotency check: does an identical record already exist?
    $existing = Find-IBRecord -NameInZone $nameInZone -RecordType $recordType -ViewId $viewObj.id -Fqdn $fqdn
    $match = $existing | Where-Object {
        $rec = $_    # capture: $_ gets reassigned inside switch
        switch ($Type) {
            'ptr'   { $rec.rdata.dname -eq $rdata.dname }
            'cname' { $rec.rdata.cname -eq $rdata.cname }
            default { $rec.rdata.address -eq $rdata.address }
        }
    }
    if ($match) {
        Write-Host "OK (unchanged): $recordType record '$fqdn' already exists with the same value." -ForegroundColor Yellow
        return
    }

    $body = @{
        name_in_zone = $nameInZone
        zone         = $zoneObj.id
        type         = $recordType
        rdata        = $rdata
    }
    if ($CreatePtr -and $Type -in @('a', 'aaaa')) {
        $body.options = @{ create_ptr = $true }
    }

    $created = Invoke-IBApi -Method POST -Path '/dns/record' -Body $body
    Write-Host "CREATED: $recordType '$fqdn' -> $(($rdata.Values | Select-Object -First 1))" -ForegroundColor Green
    if ($CreatePtr -and $Type -in @('a', 'aaaa')) {
        Write-Host "         (matching PTR record created automatically)" -ForegroundColor Green
    }
    Write-Verbose "Record id: $($created.result.id)"
}
else {
    # delete
    $existing = Find-IBRecord -NameInZone $nameInZone -RecordType $recordType -ViewId $viewObj.id -Fqdn $fqdn

    # If an IP/value was given, only delete the matching record; otherwise delete all of that name+type
    $targets = $existing | Where-Object {
        $rec = $_    # capture: $_ gets reassigned inside switch
        switch ($Type) {
            'ptr'   { -not $rdata.dname   -or $rec.rdata.dname   -eq $rdata.dname }
            'cname' { -not $rdata.cname   -or $rec.rdata.cname   -eq $rdata.cname }
            default { -not $rdata.address -or $rec.rdata.address -eq $rdata.address }
        }
    }

    if (-not $targets -or @($targets).Count -eq 0) {
        Write-Host "OK (unchanged): no matching $recordType record found for '$fqdn'." -ForegroundColor Yellow
        return
    }

    foreach ($rec in $targets) {
        Invoke-IBApi -Method DELETE -Path "/$($rec.id)" | Out-Null
        Write-Host "DELETED: $recordType '$fqdn' ($($rec.id))" -ForegroundColor Green
    }
}

#endregion