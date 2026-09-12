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
function Invoke-Guest { param([string]$Command)
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
    function Invoke-Guest { param([string]$Command)
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

Write-Host ""
if ($fail -gt 0) { Write-Host "# LAN bridge: $pass passed, $fail failed" -ForegroundColor Red; exit 1 }
Write-Host "# LAN bridge: $pass passed, 0 failed" -ForegroundColor Green
