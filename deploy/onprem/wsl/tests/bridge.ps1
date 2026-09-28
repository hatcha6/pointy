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
$script:FirewallRules = [System.Collections.ArrayList]::new()
function Add-FirewallRule { param([string]$Name, [string]$Port, [string[]]$RemoteAddress = @())
    [void]$script:FirewallRules.Add([pscustomobject]@{ Name = $Name; Port = $Port; RemoteAddress = @($RemoteAddress) }) }
function Write-FirewallWarnings { param($Ftp = $null) }
# The DVRs' side (FTP) is walked on every reconcile too. Its probes are faked
# here, before the first reconcile, so none of them dials a real socket.
$script:FtpAnswers = @()          # addresses where the FTP greeting is ours
$script:FtpAnswersAfter = $null   # ...once a forward is re-created
$script:Listening = @{}           # ports the IP Helper listens on, as a set
$script:ListeningAfter = $null
$script:Services = @()
function Test-PointyFtp { param([string]$Address, [int]$Port) return ($script:FtpAnswers -contains $Address) }
function Get-ForwardListeningPorts { return $script:Listening }
function Get-ServicesInProcess { param([int]$ProcessId) return @($script:Services) }
# netsh's portproxy table, one forward per line; a machine already bridged has
# the DVRs' ports in it as well as the tills'.
function forwardTable([string]$Ip, [int[]]$Ports) {
    return (@($Ports | ForEach-Object { "0.0.0.0         $_        $Ip    $_" }) -join "`n") }
$allData = @(30000..30019)
$bridged = @(8000, 80, 21) + $allData
$healthySet = @(21) + $allData   # what the IP Helper listens on when all is well
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
    $script:NetshOut = forwardTable "172.28.150.9" $bridged
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

# --- FTP upload setups: the DVRs' side of the bridge -------------------------
#
# A DVR dials the control port and then a passive data port per transfer, and
# every one of them crosses the same portproxy. A data port that never bound is
# the cruellest failure there is: the DVR logs in fine, "Test" may even pass,
# and no footage ever arrives.

check "the FTP ports default to the compose file's when the .env says nothing" {
    $ftp = ConvertFrom-FtpEnv -Text ""
    ($ftp.Port -eq 21) -and ($ftp.Range -eq "30000-30019") -and (@($ftp.Passive).Count -eq 20) -and
        ($ftp.Passive[0] -eq 30000) -and ($ftp.Passive[-1] -eq 30019)
}
check "moved FTP ports are followed: quoted, commented, CRLF, or through an inbox wsl.exe's NULs" {
    $a = ConvertFrom-FtpEnv -Text "POINTY_FTP_PUBLIC_PORT=2121`r`nPOINTY_FTP_PASSIVE_PORTS=`"31000-31004`"  # off IIS`r`n"
    $b = ConvertFrom-FtpEnv -Text "POINTY_FTP_PUBLIC_PORT='2121'`0`nPOINTY_FTP_PASSIVE_PORTS=31000`0"
    ($a.Port -eq 2121) -and ($a.Range -eq "31000-31004") -and ((@($a.Passive) -join ",") -eq "31000,31001,31002,31003,31004") -and
        ($b.Port -eq 2121) -and ($b.Range -eq "31000") -and ((@($b.Passive) -join ",") -eq "31000")
}
check "an empty or commented-out value keeps the default, as compose does" {
    $ftp = ConvertFrom-FtpEnv -Text "POINTY_FTP_PUBLIC_PORT=`nPOINTY_FTP_PASSIVE_PORTS=`n# POINTY_FTP_PUBLIC_PORT=2121"
    ($ftp.Port -eq 21) -and ($ftp.Range -eq "30000-30019")
}
check "a data range too wide to forward port by port is refused, and says so" {
    $script:Log.Clear()
    ($null -eq (ConvertFrom-FtpEnv -Text "POINTY_FTP_PASSIVE_PORTS=30000-40000")) -and (logged "stops at 100")
}
check "FTP ports that cannot work are refused rather than forwarded" {
    ($null -eq (ConvertFrom-FtpEnv -Text "POINTY_FTP_PASSIVE_PORTS=80-99")) -and
        ($null -eq (ConvertFrom-FtpEnv -Text "POINTY_FTP_PASSIVE_PORTS=30019-30000")) -and
        ($null -eq (ConvertFrom-FtpEnv -Text "POINTY_FTP_PUBLIC_PORT=30005")) -and
        ($null -eq (ConvertFrom-FtpEnv -Text "POINTY_FTP_PUBLIC_PORT=70000"))
}
check "port lists are said as ranges" {
    ((Format-PortList @(30005, 30000, 30001, 30002)) -eq "30000-30002, 30005") -and ((Format-PortList @(21)) -eq "21")
}

# netsh's listing of the ports Windows keeps from programs. Hyper-V's NAT takes
# blocks at boot (no asterisk); an operator's own reservations carry one.
$script:ExcludedOut = @"
Protocol tcp Port Exclusion Ranges

Start Port    End Port
----------    --------
      5357        5357
     30010       30109
     50000       50059     *

* - Administered port exclusions.
"@
$script:FtpEnv = ""
$script:GuestCommands = [System.Collections.ArrayList]::new()
function Invoke-Guest { param([string]$Command, [int]$TimeoutSec = 120)
    [void]$script:GuestCommands.Add($Command)
    if ($Command -eq "true") {
        return [pscustomobject]@{ ExitCode = $(if ($script:GuestStarts) { 0 } else { 1 }); Output = "" } }
    if ($Command -like "ip -4 *") {
        return [pscustomobject]@{ ExitCode = 0; Output = "2: eth0    inet 172.28.150.9/20 scope global eth0" } }
    if ($Command -like "grep *") {
        return [pscustomobject]@{ ExitCode = $(if ($script:FtpEnv) { 0 } else { 1 }); Output = $script:FtpEnv } }
    return [pscustomobject]@{ ExitCode = 0; Output = "" } }
function Invoke-Native { param([string]$File, [string[]]$Arguments)
    $line = "$File $($Arguments -join ' ')"
    [void]$script:NativeLog.Add($line)
    if ($line -like "*excludedportrange*") { return [pscustomobject]@{ ExitCode = 0; Output = $script:ExcludedOut } }
    if ($line -like "*portproxy add*") {
        if ($null -ne $script:AnswersAfter) { $script:Answers = $script:AnswersAfter }
        if ($null -ne $script:FtpAnswersAfter) { $script:FtpAnswers = $script:FtpAnswersAfter }
        if ($null -ne $script:ListeningAfter) { $script:Listening = $script:ListeningAfter }
    }
    return [pscustomobject]@{ ExitCode = 0; Output = $script:NetshOut } }
# Who holds which port, now per port: a data port can be taken on its own.
function Get-PortListeners { param([int]$Port) return @($script:Listeners | Where-Object { $_.Port -eq $Port }) }
function listeningOn([int[]]$Ports) { $set = @{}; foreach ($p in $Ports) { $set[$p] = $true }; return $set }
function holder([int]$Port, [string]$Name, [int]$ProcessId) {
    return [pscustomobject]@{ Port = $Port; Address = "0.0.0.0"; ProcessId = $ProcessId; Name = $Name } }

check "Windows' reserved port ranges are read, telling Hyper-V's from an operator's own" {
    $ranges = @(Get-ExcludedPortRanges)
    ($ranges.Count -eq 3) -and ($ranges[1].Start -eq 30010) -and ($ranges[1].End -eq 30109) -and
        (-not $ranges[1].Administered) -and $ranges[2].Administered
}

$ftp = ConvertFrom-FtpEnv -Text ""
$everywhere = @("172.28.144.3", "127.0.0.1", "192.168.1.10")
function ftpCase([string[]]$Answers, [string[]]$AnswersAfter = $null, $Listening = $null, $ListeningAfter = $null,
                 $Listeners = @()) {
    $script:FtpAnswers = $Answers; $script:FtpAnswersAfter = $AnswersAfter
    $script:Listening = $Listening; $script:ListeningAfter = $ListeningAfter
    $script:Lan = @("192.168.1.10"); $script:Listeners = $Listeners
    $script:Log.Clear(); $script:NativeLog.Clear()
    return (Confirm-FtpBridge -WslIp "172.28.144.3" -Ftp $ftp)
}

check "an FTP service not up yet is not judged, and no forward is touched" {
    $r = ftpCase -Answers @() -Listening (listeningOn $allData)
    ($null -eq $r) -and (logged "does not answer at 172.28.144.3:21") -and -not (called "portproxy")
}
check "a healthy FTP bridge is proven without touching a forward" {
    $r = ftpCase -Answers $everywhere -Listening (listeningOn $healthySet)
    ($r -eq $true) -and -not (called "portproxy") -and -not (logged "WARN:") -and -not (logged "ERROR:")
}
check "an FTP control forward that never bound is re-created, then proven" {
    $r = ftpCase -Answers @("172.28.144.3", "127.0.0.1") -AnswersAfter $everywhere -Listening (listeningOn $healthySet)
    ($r -eq $true) -and (called "listenport=21 ") -and (logged "re-created forward answers") -and -not (logged "ERROR:")
}
check "port 21 held by IIS's FTP service names the service and the way out" {
    # Its greeting is not ours, so 127.0.0.1 and the LAN "do not answer".
    $script:Services = @("ftpsvc")
    $r = ftpCase -Answers @("172.28.144.3") -Listening (listeningOn $allData) -Listeners @(holder 21 "svchost" 1234)
    $script:Services = @()
    ($r -eq $false) -and (logged "0.0.0.0:21 is held by svchost (PID 1234: ftpsvc)") -and
        (logged "POINTY_FTP_PUBLIC_PORT") -and (logged "each DVR's FTP settings")
}
check "data ports inside a block Hyper-V reserved are named, with the fix" {
    $half = listeningOn (@(21) + @(30000..30009))
    $r = ftpCase -Answers $everywhere -Listening $half -ListeningAfter $half
    ($r -eq $false) -and (called "listenport=30010 ") -and (logged "still nothing listening on 30010-30019") -and
        (logged "Windows has reserved TCP 30010-30109") -and (logged "POINTY_FTP_PASSIVE_PORTS") -and
        -not (logged "50000")
}
check "a data port another program holds is named" {
    $script:ExcludedOut = ""
    $most = listeningOn (@(21) + @($allData | Where-Object { $_ -ne 30005 }))
    $r = ftpCase -Answers $everywhere -Listening $most -ListeningAfter $most -Listeners @(holder 30005 "vendorapp" 777)
    ($r -eq $false) -and (logged "0.0.0.0:30005 is held by vendorapp (PID 777)") -and (logged "POINTY_FTP_PASSIVE_PORTS")
}
check "data forwards with nothing in their way and still no listener name the IP Helper" {
    $r = ftpCase -Answers $everywhere -Listening (listeningOn @(21)) -ListeningAfter (listeningOn @(21))
    ($r -eq $false) -and (logged "IP Helper service has not opened the forwards") -and -not (logged "Fix:")
}
check "data forwards that listen once re-created are proven" {
    $r = ftpCase -Answers $everywhere -Listening (listeningOn @(21)) -ListeningAfter (listeningOn $healthySet)
    ($r -eq $true) -and (logged "re-created forwards listen") -and -not (logged "ERROR:")
}
check "when the listeners cannot be read, the control port's greeting is enough" {
    $r = ftpCase -Answers $everywhere -Listening $null
    $r -eq $true
}
check "a machine that hides who listens is not judged on its data ports, and nothing is re-created" {
    # The control port just answered, yet its listener is not in the set: the
    # set is what is wrong, and twenty working forwards must not be churned.
    $r = ftpCase -Answers $everywhere -Listening (listeningOn $allData)
    ($r -eq $true) -and -not (called "portproxy") -and -not (logged "WARN:")
}

function reconcileWith([string]$Netsh) {
    $script:NetshOut = $Netsh
    $script:Answers = @("172.28.150.9", "127.0.0.1", "192.168.1.10"); $script:AnswersAfter = $null
    $script:Lan = @("192.168.1.10"); $script:Listeners = @()
    $script:FirewallRules.Clear(); $script:GuestCommands.Clear(); $script:Log.Clear(); $script:NativeLog.Clear()
    $r = Invoke-BootReconcile
    return [pscustomobject]@{ Result = $r; State = (Get-Content -Raw $StateFile | ConvertFrom-Json) }
}
function ruleNamed([string]$Name) { return @($script:FirewallRules | Where-Object { $_.Name -eq $Name }) }

check "a reconcile forwards the DVRs' ports too, opens them to private addresses only, and records them" {
    $script:FtpAnswers = @("172.28.150.9", "127.0.0.1", "192.168.1.10"); $script:FtpAnswersAfter = $null
    $script:Listening = listeningOn $healthySet; $script:ListeningAfter = $null
    $run = reconcileWith (forwardTable "172.28.150.9" @(8000, 80))
    $control = @(ruleNamed "Pointy FTP (TCP 21)")
    $data = @(ruleNamed "Pointy FTP data (TCP 30000-30019)")
    ($run.Result -eq $true) -and (called "listenport=21 connectaddress=172.28.150.9") -and
        (called "listenport=30019 connectaddress=172.28.150.9") -and
        ($control.Count -eq 1) -and ($data.Count -eq 1) -and ($data[0].Port -eq "30000-30019") -and
        (@($control[0].RemoteAddress) -contains "192.168.0.0/16") -and (@($data[0].RemoteAddress) -contains "10.0.0.0/8") -and
        $run.State.verified -and ($run.State.ftp_verified -eq $true) -and ($run.State.ftp_port -eq 21) -and
        ($run.State.ftp_passive_ports -eq "30000-30019") -and
        (logged "DVRs upload over FTP to 192.168.1.10:21 (data ports 30000-30019)") -and
        ($script:GuestCommands -contains "grep '^POINTY_FTP_' '/opt/pointy/.env'")
}
check "an already-bridged machine is left alone, FTP included" {
    $run = reconcileWith (forwardTable "172.28.150.9" $bridged)
    $run.State.verified -and ($run.State.ftp_verified -eq $true) -and -not (called "portproxy add") -and
        (logged "nothing to do")
}
check "a broken FTP bridge is reported, and never counts against the tills'" {
    $script:FtpAnswers = @("172.28.150.9")   # the service answers; the LAN side never does
    $run = reconcileWith (forwardTable "172.28.150.9" $bridged)
    $script:FtpAnswers = @("172.28.150.9", "127.0.0.1", "192.168.1.10")
    $run.State.verified -and ($run.State.ftp_verified -eq $false) -and (logged "FTP port 21: still unreachable") -and
        (logged "not every hop answered") -and -not (logged "nothing to do")
}
check "FTP ports moved in the .env are the ones forwarded and opened" {
    $script:FtpEnv = "POINTY_FTP_PUBLIC_PORT=2121`nPOINTY_FTP_PASSIVE_PORTS=31000-31004"
    $script:Listening = listeningOn (@(2121) + @(31000..31004))
    $run = reconcileWith (forwardTable "172.28.150.9" @(8000, 80))
    $script:FtpEnv = ""; $script:Listening = listeningOn $healthySet
    (called "listenport=2121 ") -and (called "listenport=31004 ") -and -not (called "listenport=21 ") -and
        -not (called "listenport=30000 ") -and ((ruleNamed "Pointy FTP data (TCP 31000-31004)").Count -eq 1) -and
        ($run.State.ftp_port -eq 2121) -and ($run.State.ftp_passive_ports -eq "31000-31004")
}
check "an .env the bridge cannot forward leaves the tills' bridge whole" {
    $script:FtpEnv = "POINTY_FTP_PASSIVE_PORTS=1-65535"
    $run = reconcileWith (forwardTable "172.28.150.9" @(8000, 80))
    $script:FtpEnv = ""
    $run.State.verified -and -not ($run.State.PSObject.Properties.Name -contains "ftp_port") -and
        (logged "are not usable") -and -not (called "portproxy add")
}
Remove-Item $StateFile -ErrorAction SilentlyContinue

# --- the scripts as shipped ---------------------------------------------------
#
# A shop PC runs Windows PowerShell 5.1, not the pwsh these tests run on. It
# reads a file without a BOM in the PC's own code page - on an Arabic Windows a
# stray UTF-8 dash can decode into a quote that ends a string early - and it
# has none of the operators PowerShell 7 added.
foreach ($shipped in @("bootstrap-wsl.ps1", "keep-pointy-running.ps1", "collect-diagnostics.ps1")) {
    $shippedPath = (Resolve-Path (Join-Path (Join-Path $PSScriptRoot "..") $shipped)).Path
    check "$shipped is plain ASCII" {
        -not ([IO.File]::ReadAllText($shippedPath) -match '[^\x00-\x7F]')
    }
    check "$shipped uses nothing Windows PowerShell 5.1 lacks" {
        $shippedTokens = $null; $shippedErrors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($shippedPath, [ref]$shippedTokens, [ref]$shippedErrors) | Out-Null
        $ps7 = @($shippedTokens | Where-Object { "$($_.Kind)" -in @("QuestionQuestion", "QuestionQuestionEquals",
            "QuestionDot", "QuestionLBracket", "AndAnd", "OrOr", "QuestionMark") })
        (@($shippedErrors).Count -eq 0) -and ($ps7.Count -eq 0)
    }
}

Write-Host ""
if ($fail -gt 0) { Write-Host "# LAN bridge: $pass passed, $fail failed" -ForegroundColor Red; exit 1 }
Write-Host "# LAN bridge: $pass passed, 0 failed" -ForegroundColor Green
