# The LAN bridge: pure parsers, tested in-process.
#
# These decide whether a till can reach the stack at all. When they are wrong
# the install still LOOKS like it worked - containers healthy, no errors - and
# the shop simply cannot sell. That is the worst failure shape there is, so the
# parsing is pinned here rather than discovered on a shop floor.
. "$PSScriptRoot/lib.ps1"
$pass = 0; $fail = 0
function check([string]$what, [scriptblock]$body) {
    try { $r = & $body; if ($r) { $script:pass++; Write-Host "ok   $what" -ForegroundColor Green }
          else { $script:fail++; Write-Host "FAIL $what" -ForegroundColor Red } }
    catch { $script:fail++; Write-Host "FAIL $what -- $($_.Exception.Message)" -ForegroundColor Red }
}

Write-Host "# bootstrap-wsl.ps1 : LAN bridge"

# Once Docker is running the distro also holds docker0 and per-network bridge
# addresses. `hostname -I` returns them in no guaranteed order, and forwarding
# the LAN to a docker bridge address blackholes every till silently.
$script:GuestOut = ""
function Invoke-Guest { param([string]$Command, [int]$TimeoutSec = 120)
    return [pscustomobject]@{ ExitCode = 0; Output = $script:GuestOut } }

check "reads eth0's address" {
    $script:GuestOut = '2: eth0    inet 172.28.144.3/20 brd 172.28.159.255 scope global eth0'
    (Get-WslIp) -eq "172.28.144.3"
}
check "survives UTF-16 NULs from an inbox wsl.exe" {
    $script:GuestOut = "2: eth0`0    inet`0 172.28.144.3/20 scope global eth0"
    (Get-WslIp) -eq "172.28.144.3"
}
check "returns nothing rather than a guess when eth0 has no address" {
    $script:GuestOut = '2: eth0    <NO-CARRIER,BROADCAST,MULTICAST,UP>'
    $null -eq (Get-WslIp)
}
check "a failed guest command yields no address" {
    function Invoke-Guest { param([string]$Command, [int]$TimeoutSec = 120)
        return [pscustomobject]@{ ExitCode = 1; Output = "" } }
    $null -eq (Get-WslIp)
}

# netsh reports success for `portproxy add` even when the listener never binds,
# so reading back what is actually configured is the only honest check.
$script:NetshOut = ""
function Invoke-Native { param([string]$File, [string[]]$Arguments)
    [void]$script:NativeLog.Add("$File $($Arguments -join ' ')")
    return [pscustomobject]@{ ExitCode = 0; Output = $script:NetshOut } }

check "parses the current portproxy target" {
    $script:NetshOut = @"
Listen on ipv4:             Connect to ipv4:

Address         Port        Address         Port
--------------- ----------  --------------- ----------
0.0.0.0         8000        172.28.144.3    8000
0.0.0.0         80          172.28.144.3    80
"@
    (Get-PortProxyTarget -Port 8000) -eq "172.28.144.3"
}
check "does not confuse one port's row for another" {
    (Get-PortProxyTarget -Port 80) -eq "172.28.144.3"
}
check "reports nothing for a port that is not forwarded" {
    $null -eq (Get-PortProxyTarget -Port 9999)
}
check "an already-correct forward is left alone (no churn on every boot)" {
    $script:NativeLog.Clear()
    $r = Set-PortProxy -Port 8000 -Target "172.28.144.3"
    (-not $r) -and -not (called "portproxy add")
}
check "a moved WSL IP is re-pointed: delete then add" {
    $script:NativeLog.Clear()
    $r = Set-PortProxy -Port 8000 -Target "172.28.150.9"
    $r -and (called "portproxy delete") -and (called "portproxy add")
}
check "a brand new forward is added without a pointless delete" {
    $script:NativeLog.Clear()
    $r = Set-PortProxy -Port 9999 -Target "172.28.144.3"
    $r -and (called "portproxy add") -and -not (called "portproxy delete")
}
check "-Force re-creates a forward whose rule already looks right" {
    # The rule is only configuration. A listener that never bound behind a
    # correct rule is invisible to the comparison above, forever.
    $script:NativeLog.Clear()
    $r = Set-PortProxy -Port 8000 -Target "172.28.144.3" -Force
    $r -and (called "portproxy delete") -and (called "portproxy add")
}

# --- the addresses a till dials ---------------------------------------------

function Get-NetIPAddress { param($AddressFamily, $ErrorAction)
    function row([string]$Alias, [string]$Ip, [string]$State = "Preferred") {
        [pscustomobject]@{ InterfaceAlias = $Alias; IPAddress = $Ip; AddressState = $State } }
    row "Ethernet" "192.168.1.10"
    # WSL's own adapter often sits in 192.168.x. Offering it to a till is
    # offering an address no other device can route to.
    row "vEthernet (WSL (Hyper-V firewall))" "192.168.176.1"
    row "vEthernet (Default Switch)" "172.20.0.1"
    row "VirtualBox Host-Only Network" "192.168.56.1"
    row "Wi-Fi" "169.254.3.4"
    row "Loopback Pseudo-Interface 1" "127.0.0.1"
    row "Ethernet 2" "10.0.0.5" "Tentative"
    # A Hyper-V EXTERNAL switch is where a real LAN address lives on a machine
    # that has one; filtering every vEthernet would lose it.
    row "vEthernet (External LAN)" "192.168.1.20"
}
check "LAN addresses are the real adapters only" {
    $lan = @(Get-LanIPv4)
    ($lan -join ",") -eq "192.168.1.10,192.168.1.20"
}

# --- walking the path a till takes ----------------------------------------

# Which addresses answer on the front door's health path. A re-created forward
# switches to $AnswersAfter, which is how a listener that finally binds looks.
$script:GuestUp = $true
$script:Answers = @()
$script:AnswersAfter = $null
$script:Lan = @("192.168.1.10")
$script:Listeners = @()
function Invoke-Guest { param([string]$Command, [int]$TimeoutSec = 120)
    if ($Command -like "curl *") {
        return [pscustomobject]@{ ExitCode = $(if ($script:GuestUp) { 0 } else { 7 }); Output = "" } }
    return [pscustomobject]@{ ExitCode = 0; Output = "" } }
function Test-PointyHttp { param([string]$Url, [int]$TimeoutMs = 4000)
    return ($script:Answers -contains ([uri]$Url).Host) }
function Get-LanIPv4 { return $script:Lan }
function Get-PortListeners { param([int]$Port) return $script:Listeners }
function Invoke-Native { param([string]$File, [string[]]$Arguments)
    [void]$script:NativeLog.Add("$File $($Arguments -join ' ')")
    if (($Arguments -join ' ') -like "*portproxy add*" -and $null -ne $script:AnswersAfter) {
        $script:Answers = $script:AnswersAfter }
    return [pscustomobject]@{ ExitCode = 0; Output = $script:NetshOut } }
function bridgeCase([bool]$GuestUp, [string[]]$Answers, [string[]]$AnswersAfter = $null,
                    [string[]]$Lan = @("192.168.1.10"), $Listeners = @()) {
    $script:GuestUp = $GuestUp; $script:Answers = $Answers; $script:AnswersAfter = $AnswersAfter
    $script:Lan = $Lan; $script:Listeners = $Listeners
    $script:Log.Clear(); $script:NativeLog.Clear()
    return (Confirm-LanBridge -WslIp "172.28.144.3" -Port 8000 -HealthPath "/healthz-edge")
}

check "a stack still starting is not judged, and the forward is left alone" {
    $r = bridgeCase -GuestUp $false -Answers @()
    ($null -eq $r) -and (logged "not answering inside WSL") -and -not (called "portproxy")
}
check "a stack Windows cannot reach at the VM address points at the bind setting" {
    $r = bridgeCase -GuestUp $true -Answers @("127.0.0.1", "192.168.1.10")
    ($r -eq $false) -and (logged "POINTY_BACKEND_BIND") -and -not (called "portproxy add")
}
check "a healthy bridge is verified without touching the forward" {
    $r = bridgeCase -GuestUp $true -Answers @("172.28.144.3", "127.0.0.1", "192.168.1.10")
    ($r -eq $true) -and -not (called "portproxy add")
}
check "THE BUG: a forward that never bound is re-created, then proven" {
    # The install-order race: the rule was right, netsh said it succeeded, the
    # server's own till worked through WSL's relay - and the LAN got nothing.
    $r = bridgeCase -GuestUp $true -Answers @("172.28.144.3", "127.0.0.1") `
                    -AnswersAfter @("172.28.144.3", "127.0.0.1", "192.168.1.10")
    ($r -eq $true) -and (called "portproxy delete") -and (called "portproxy add") -and
        (logged "re-created forward answers") -and -not (logged "ERROR:")
}
check "a forward held off by WSL's relay names it and the one-time fix" {
    $held = @([pscustomobject]@{ Address = "127.0.0.1"; ProcessId = 4242; Name = "wslrelay" })
    $r = bridgeCase -GuestUp $true -Answers @("172.28.144.3", "127.0.0.1") -Listeners $held
    ($r -eq $false) -and (logged "127.0.0.1:8000 is held by wslrelay") -and (logged "restart Windows once")
}
check "a forward nobody is listening for names the IP Helper" {
    $r = bridgeCase -GuestUp $true -Answers @("172.28.144.3")
    ($r -eq $false) -and (logged "IP Helper service has not opened")
}
check "a machine with no LAN address is not reported as reachable" {
    $r = bridgeCase -GuestUp $true -Answers @("172.28.144.3", "127.0.0.1") -Lan @()
    ($r -eq $false) -and (logged "no LAN address") -and -not (called "portproxy add")
}

# --- .wslconfig: the forward must be the only owner of its ports ------------

$script:ProfileDir = Join-Path ([IO.Path]::GetTempPath()) ("pointy-profile-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $script:ProfileDir | Out-Null
$env:USERPROFILE = $script:ProfileDir
function Get-CimInstance { param($ClassName, $Namespace, $ErrorAction)
    return [pscustomobject]@{ TotalPhysicalMemory = 16GB } }
$script:WslVersionText = "WSL version: 2.3.26.0"
function Invoke-Wsl { param([string[]]$Arguments, [int]$TimeoutSec = 120)
    return [pscustomobject]@{ ExitCode = 0; Output = $script:WslVersionText } }
# The file WSL reads is the owner's; here that is the temp profile above.
function Get-OwnerProfileDir { return $env:USERPROFILE }
$script:WslConfigPath = Join-Path $script:ProfileDir ".wslconfig"

# Which [section] a key sits in, or "" when it is missing. WSL reads a key
# only in its own section, so the section is part of what is pinned.
function sectionOf([string]$Text, [string]$Key) {
    $current = ""
    foreach ($line in ($Text -split "`n")) {
        if ($line -match '^\[(.+)\]$') { $current = $Matches[1]; continue }
        if ($line -match "^$Key=") { return $current }
    }
    return ""
}

check "a fresh .wslconfig turns WSL's localhost relay off" {
    Remove-Item $script:WslConfigPath -ErrorAction SilentlyContinue
    $changed = Write-WslConfig
    $text = Get-Content -Raw $script:WslConfigPath
    $changed -and ($text -match '(?m)^localhostForwarding=false$') -and ($text -notmatch 'localhostForwarding=true')
}
check "every key sits in the section WSL reads it from" {
    # sparseVhd under [wsl2] is a warning on every wsl.exe call and nothing
    # else; the vhdx keeps growing.
    $text = Get-Content -Raw $script:WslConfigPath
    ((sectionOf $text "localhostForwarding") -eq "wsl2") -and ((sectionOf $text "vmIdleTimeout") -eq "wsl2") -and
        ((sectionOf $text "sparseVhd") -eq "experimental") -and ((sectionOf $text "autoMemoryReclaim") -eq "experimental")
}
check "instanceIdleTimeout is not written for a WSL that would only warn about it (2.3.26)" {
    $text = Get-Content -Raw $script:WslConfigPath
    $text -notmatch 'instanceIdleTimeout'
}
check "rewriting an identical .wslconfig reports no change (no needless WSL restart)" {
    -not (Write-WslConfig)
}
check "on WSL 2.5.4+ the distro itself is told never to idle off, under [general]" {
    $script:WslVersionText = "WSL version: 2.5.10.0"
    $changed = Write-WslConfig
    $text = Get-Content -Raw $script:WslConfigPath
    $script:WslVersionText = "WSL version: 2.3.26.0"
    $changed -and ((sectionOf $text "instanceIdleTimeout") -eq "general") -and ($text -match '(?m)^instanceIdleTimeout=-1$')
}
check "an installed shop's generated .wslconfig is converged at boot" {
    $old = "$WslConfigMarker`n[wsl2]`nmemory=8GB`nlocalhostForwarding=true`nsparseVhd=true`n"
    [IO.File]::WriteAllText($script:WslConfigPath, $old)
    $script:Log.Clear()
    Update-GeneratedWslConfig
    $text = Get-Content -Raw $script:WslConfigPath
    ($text -match '(?m)^localhostForwarding=false$') -and ((sectionOf $text "sparseVhd") -eq "experimental") -and
        (logged "next time Windows restarts")
}
check "a converged .wslconfig is not rewritten (or logged) again on the next cycle" {
    $script:Log.Clear()
    Update-GeneratedWslConfig
    -not (logged "wslconfig")
}
check "an operator's own .wslconfig is never rewritten" {
    $own = "[wsl2]`nmemory=12GB`nlocalhostForwarding=true`n"
    [IO.File]::WriteAllText($script:WslConfigPath, $own)
    Update-GeneratedWslConfig
    (Get-Content -Raw $script:WslConfigPath) -eq $own
}
Remove-Item -Recurse -Force $script:ProfileDir -ErrorAction SilentlyContinue

# --- the whole -Boot reconcile, which every shop runs every 5 minutes -------

$StateFile = Join-Path ([IO.Path]::GetTempPath()) ("pointy-bridge-" + [guid]::NewGuid().ToString("N") + ".json")
function Test-DistroExists { return $true }
function Enable-IpHelper { }
function Add-FirewallRule { param([string]$Name, [int]$Port) }
function Write-FirewallWarnings { }
$script:GuestStarts = $true
function Invoke-Guest { param([string]$Command, [int]$TimeoutSec = 120)
    if ($Command -eq "true") {
        return [pscustomobject]@{ ExitCode = $(if ($script:GuestStarts) { 0 } else { 1 }); Output = "" } }
    if ($Command -like "ip -4 *") {
        return [pscustomobject]@{ ExitCode = 0; Output = "2: eth0    inet 172.28.150.9/20 scope global eth0" } }
    return [pscustomobject]@{ ExitCode = 0; Output = "" } }
function Update-GeneratedWslConfig { }

check "a reboot's reconcile re-points both ports, proves them, and records it" {
    # netsh still points at the address the VM had before the reboot.
    $script:NetshOut = "0.0.0.0         8000        172.28.144.3    8000`n0.0.0.0         80          172.28.144.3    80"
    $script:Answers = @("172.28.150.9", "127.0.0.1", "192.168.1.10"); $script:AnswersAfter = $null
    $script:Lan = @("192.168.1.10")
    $script:Log.Clear(); $script:NativeLog.Clear()
    $r = Invoke-BootReconcile
    $state = Get-Content -Raw $StateFile | ConvertFrom-Json
    ($r -eq $true) -and (logged "LAN port 8000 -> 172.28.150.9:8000") -and (logged "LAN port 80 -> 172.28.150.9:80") -and
        (logged "tills reach it at http://192.168.1.10:8000") -and
        $state.verified -and ($state.wsl_ip -eq "172.28.150.9") -and (@($state.lan_ips) -join ",") -eq "192.168.1.10"
}
check "a reconcile that cannot prove the path says so instead of 'nothing to do'" {
    $script:NetshOut = "0.0.0.0         8000        172.28.150.9    8000`n0.0.0.0         80          172.28.150.9    80"
    $script:Answers = @("172.28.150.9", "127.0.0.1")   # the LAN address never answers
    $script:Log.Clear(); $script:NativeLog.Clear()
    Invoke-BootReconcile | Out-Null
    $state = Get-Content -Raw $StateFile | ConvertFrom-Json
    (-not $state.verified) -and (logged "not every hop answered") -and -not (logged "nothing to do")
}
check "a reconcile that cannot start the distro reports it and returns, rather than exiting the supervisor" {
    # Under the old -Boot this was a Die. The supervisor runs this every
    # cycle; one bad cycle must never end it.
    $script:GuestStarts = $false
    $script:Log.Clear(); $script:NativeLog.Clear()
    $r = Invoke-BootReconcile
    $script:GuestStarts = $true
    ($r -eq $false) -and (logged "ERROR: could not start distro 'Pointy'") -and -not (called "portproxy")
}
check "a reconcile for a distro this user cannot see says so and returns" {
    function Test-DistroExists { return $false }
    $script:Log.Clear()
    $r = Invoke-BootReconcile
    function Test-DistroExists { return $true }
    ($r -eq $false) -and (logged "ERROR: distro 'Pointy' is not registered")
}
Remove-Item $StateFile -ErrorAction SilentlyContinue

Write-Host ""
if ($fail -gt 0) { Write-Host "# LAN bridge: $pass passed, $fail failed" -ForegroundColor Red; exit 1 }
Write-Host "# LAN bridge: $pass passed, 0 failed" -ForegroundColor Green
