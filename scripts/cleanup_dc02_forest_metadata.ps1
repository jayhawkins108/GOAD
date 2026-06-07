<#
.SYNOPSIS
    Remove stale DC02/WINTERFELL forest metadata from DC01 before a DC02 rebuild.

.DESCRIPTION
    VBoxManage deletes the DC02 VM files but leaves its AD registration on DC01.
    Running DCPROMO on a fresh DC02 fails with error 1356 ("cannot determine if
    domain name is unique") until these objects are removed.

    Run this script on DC01 (kingslanding.sevenkingdoms.local) before rebuilding
    DC02. Idempotent — safe to re-run if partially completed.

.NOTES
    Related: ARCHER issue #922
    Reference: https://learn.microsoft.com/en-us/troubleshoot/windows-server/active-directory/remove-orphaned-domains
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ChildDomain    = 'north.sevenkingdoms.local'
$ServerObject   = 'WINTERFELL'
$SiteName       = 'Default-First-Site-Name'

function Write-Step { param([string]$msg) Write-Host "  [cleanup] $msg" -ForegroundColor Cyan }
function Write-OK   { param([string]$msg) Write-Host "  [ok]      $msg" -ForegroundColor Green }
function Write-Skip { param([string]$msg) Write-Host "  [skip]    $msg" -ForegroundColor Yellow }

Write-Step "Checking forest for stale north.sevenkingdoms.local objects..."

Import-Module ActiveDirectory

$forest = Get-ADForest
if ($ChildDomain -notin $forest.Domains) {
    Write-Skip "north.sevenkingdoms.local not in forest — nothing to clean."
    exit 0
}

# 1 — Verify no live DC exists for north (safety guard)
Write-Step "Checking for live DCs in north domain..."
try {
    $dc = Get-ADDomainController -DomainName $ChildDomain -Discover -ErrorAction Stop
    Write-Host "  [ABORT] A live DC ($($dc.HostName)) is still registered for north.sevenkingdoms.local." -ForegroundColor Red
    Write-Host "         Only run this script when DC02 is fully offline and unregistered." -ForegroundColor Red
    exit 1
} catch {
    Write-OK "No live DC found for north — safe to clean."
}

# 2 — Remove WINTERFELL server object from Sites
Write-Step "Removing CN=WINTERFELL from CN=Sites..."
$serverDN = "CN=$ServerObject,CN=Servers,CN=$SiteName,CN=Sites,CN=Configuration,DC=sevenkingdoms,DC=local"
try {
    $obj = Get-ADObject -Identity $serverDN -ErrorAction Stop
    Remove-ADObject -Identity $obj -Recursive -Confirm:$false
    Write-OK "Removed CN=$ServerObject from Sites."
} catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
    Write-Skip "CN=$ServerObject not found in Sites — already clean."
}

# 3 — Remove DC=DomainDnsZones,DC=north NC via ntdsutil
Write-Step "Removing DC=DomainDnsZones,DC=north,DC=sevenkingdoms,DC=local partition..."
$dnsZoneNC = "DC=DomainDnsZones,DC=north,DC=sevenkingdoms,DC=local"
$ntdsutilDns = @"
partition management
connections
connect to server kingslanding.sevenkingdoms.local
quit
list
delete NC $dnsZoneNC
quit
quit
"@
$ntdsutilDns | ntdsutil 2>&1 | Where-Object { $_ -match 'error|success|deleted|not found' -or $_ -match 'Operation' } | ForEach-Object { Write-Host "    $_" }
Write-OK "ntdsutil DNS zone partition command complete."

# 4 — Remove DC=north,DC=sevenkingdoms,DC=local NC via ntdsutil
Write-Step "Removing DC=north,DC=sevenkingdoms,DC=local partition..."
$northNC = "DC=north,DC=sevenkingdoms,DC=local"
$ntdsutilNorth = @"
partition management
connections
connect to server kingslanding.sevenkingdoms.local
quit
list
delete NC $northNC
quit
quit
"@
$ntdsutilNorth | ntdsutil 2>&1 | Where-Object { $_ -match 'error|success|deleted|not found' -or $_ -match 'Operation' } | ForEach-Object { Write-Host "    $_" }
Write-OK "ntdsutil north NC partition command complete."

# 5 — Remove CN=NORTH crossRef from Partitions
Write-Step "Removing CN=NORTH crossRef from CN=Partitions..."
$crossRefDN = "CN=NORTH,CN=Partitions,CN=Configuration,DC=sevenkingdoms,DC=local"
try {
    $obj = Get-ADObject -Identity $crossRefDN -ErrorAction Stop
    Remove-ADObject -Identity $obj -Confirm:$false
    Write-OK "Removed CN=NORTH crossRef."
} catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
    Write-Skip "CN=NORTH crossRef not found — already clean."
}

# 6 — Wait for replication
Write-Step "Triggering replication sync..."
repadmin /syncall /AdeP 2>&1 | Select-String 'error|SyncAll' | ForEach-Object { Write-Host "    $_" }

Write-Host ""
Write-Host "  Forest cleanup complete. DC02 rebuild + DCPROMO should now succeed." -ForegroundColor Green
Write-Host "  Verify by running: Get-ADForest | Select -ExpandProperty Domains"
