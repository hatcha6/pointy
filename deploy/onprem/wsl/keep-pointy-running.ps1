<#
  Pointy on-prem - keep the WSL server running from the signed-in Windows
  session.

  A STOPGAP for a shop that still runs Pointy inside WSL, until it moves to a
  Linux machine (see move-server.sh). WSL powers the distro off about 15 s
  after the last Windows-side wsl.exe exits, and nothing inside Linux - not
  systemd, not Docker - counts. The PointyWSL boot task, which runs in
  Windows' session 0 before anyone signs in, has not been reliable in the
  field. What demonstrably works is what shop staff were doing by hand: a
  window in the signed-in session with wsl.exe running in it. This script is
  that window, minimised and self-healing:

    - it holds the distro open with a hidden wsl.exe, and starts it again
      within seconds if WSL stops it (a WSL update, `wsl --shutdown`, a crash);
    - it asks the distro's own watchdog to bring the stack up;
    - it points the LAN forward (netsh portproxy) at the VM's current address,
      and checks the path a till takes every minute.

  It runs only while Windows is signed in to the account that owns the Pointy
  distro, so that account should sign in automatically after a restart.

  Install, once, from an ELEVATED PowerShell, signed in as the Windows user
  that installed Pointy:
      powershell -ExecutionPolicy Bypass -File .\keep-pointy-running.ps1 -Install

  Undo (removes this task and turns the PointyWSL boot task back on):
      powershell -ExecutionPolicy Bypass -File .\keep-pointy-running.ps1 -Uninstall

  Moving to Linux, at closing time, with a USB drive attached (D: here). This
  stops the stack on this PC FOR GOOD and writes everything the new machine
  needs to D:\PointyMove; add -KeepRunning for a rehearsal that changes nothing:
      powershell -ExecutionPolicy Bypass -File .\keep-pointy-running.ps1 -ExportTo D:\PointyMove
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Uninstall,
    # A folder on a local drive letter; see the header.
    [string]$ExportTo = "",
    # With -ExportTo: bring the stack back up afterwards (a rehearsal).
    [switch]$KeepRunning,
    [string]$Distro = "Pointy",
    [int]$ApiPort = 8000,
    [int]$WebPort = 80
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# wsl.exe emits UTF-16LE unless told otherwise; NULs are stripped below as well
# for the inbox Windows 10 build that ignores this.
$env:WSL_UTF8 = "1"

$InstallRoot  = Join-Path $env:ProgramData "Pointy"
$LogDir       = Join-Path $InstallRoot "logs"
$LogFile      = Join-Path $LogDir "keepalive.log"
$StateFile    = Join-Path $InstallRoot "keepalive-state.json"
# Present while an export runs: WSL stays open, the stack is left alone.
$HoldFile     = Join-Path $InstallRoot "keepalive.hold"
# Present once the server has been exported for good: nothing to keep running.
$MovedFile    = Join-Path $InstallRoot "MOVED-TO-LINUX.txt"
$StableScript = Join-Path $InstallRoot "keep-pointy-running.ps1"
$TaskName     = "PointyKeepAlive"
$OldTaskName  = "PointyWSL"
$GuestDir     = "/opt/pointy"
# The keep-alive client. Deliberately NOT the PointyWSL supervisor's
# `sleep infinity`: that supervisor adopts - and after three failed checks
# kills - any client whose command line matches its own.
$AnchorSleep  = "2147483647"
$CheckEverySec = 60
$script:WslExe = ""

# Arabic is spelled out as code points so this file stays plain ASCII, which
# Windows PowerShell reads the same way whatever the PC's language.
function ConvertFrom-CodePoint { param([int[]]$Points) return (-join ($Points | ForEach-Object { [char]$_ })) }
# "Do not close this window"
$ArDoNotClose = ConvertFrom-CodePoint @(0x644, 0x627, 0x20, 0x62A, 0x63A, 0x644, 0x642, 0x20, 0x647, 0x630,
                                        0x647, 0x20, 0x627, 0x644, 0x646, 0x627, 0x641, 0x630, 0x629)

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "{0} {1} {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    switch ($Level) {
        "WARN"  { Write-Host $line -ForegroundColor Yellow }
        "ERROR" { Write-Host $line -ForegroundColor Red }
        default { Write-Host $line }
    }
    try {
        if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
        # This runs for months; keep one generation behind so it never fills a disk.
        if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt 5MB)) {
            Move-Item -Force $LogFile ($LogFile -replace '\.log$', '.1.log')
        }
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
    } catch { }   # logging must never stop the keeper
}

function Die { param([string]$Message) Write-Log $Message "ERROR"; exit 1 }

function Set-Title {
    param([string]$State)
    try { $Host.UI.RawUI.WindowTitle = "Pointy server: ${State} - do not close | ${ArDoNotClose}" } catch { }
}

function Test-Admin {
    (New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent())
    ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

# The MSI's own wsl.exe, never the System32 one PATH finds first: that one is a
# redirector which has failed outside an interactive session (microsoft/WSL
# #9231), and WSL's own Settings app stopped using it in 2.5.4. The inbox WSL
# of an old Windows 10 has only the System32 copy, so it stays the fallback.
function Get-WslExe {
    try {
        $dir = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Lxss\Msi" `
                                 -Name InstallLocation -ErrorAction Stop).InstallLocation
        if ($dir) {
            $exe = Join-Path $dir "wsl.exe"
            if (Test-Path $exe) { return $exe }
        }
    } catch { }
    $exe = Join-Path $env:ProgramFiles "WSL\wsl.exe"
    if (Test-Path $exe) { return $exe }
    return (Join-Path $env:SystemRoot "System32\wsl.exe")
}

function Invoke-Native {
    param([string]$File, [string[]]$Arguments)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = & $File @Arguments 2>&1
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out | Out-String) }
    } finally { $ErrorActionPreference = $prev }
}

# One argument, quoted the way CommandLineToArgvW un-quotes it - which is how
# wsl.exe --exec splits what follows it.
function ConvertTo-NativeArgument {
    param([string]$Value)
    if ($Value -ne "" -and $Value -notmatch '[\s"]') { return $Value }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $backslashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq [char]'\') { $backslashes++; continue }
        if ($ch -eq [char]'"') {
            [void]$sb.Append([char]'\', $backslashes * 2 + 1)
            [void]$sb.Append([char]'"')
            $backslashes = 0
            continue
        }
        if ($backslashes) { [void]$sb.Append([char]'\', $backslashes); $backslashes = 0 }
        [void]$sb.Append($ch)
    }
    if ($backslashes) { [void]$sb.Append([char]'\', $backslashes * 2) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

# Bounded: a wedged WSL answers nothing, ever, and a keeper blocked on it is a
# keeper that restarts nothing. Output goes through files, not pipes: a Linux
# daemon that inherits a pipe keeps it open long after wsl.exe has returned.
function Invoke-NativeTimeout {
    param([string]$File, [string[]]$Arguments, [int]$TimeoutSec = 120)
    $stamp   = [guid]::NewGuid().ToString("N")
    $tempDir = [System.IO.Path]::GetTempPath()
    $outFile = Join-Path $tempDir "pointy-keepalive-${stamp}.out"
    $errFile = Join-Path $tempDir "pointy-keepalive-${stamp}.err"
    $line    = (($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join " ")
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $start = @{ FilePath = $File; NoNewWindow = $true; PassThru = $true; ErrorAction = "Stop"
                    RedirectStandardOutput = $outFile; RedirectStandardError = $errFile }
        if ($line -ne "") { $start.ArgumentList = $line }
        $p = Start-Process @start
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            try { $p.Kill() } catch { }
            return [pscustomobject]@{ ExitCode = -1; Output = "timed out after ${TimeoutSec}s: ${File} ${line}" }
        }
        $p.WaitForExit()
        $text = ""
        foreach ($f in @($outFile, $errFile)) {
            if (Test-Path $f) { $text += [System.IO.File]::ReadAllText($f, (New-Object System.Text.UTF8Encoding($false))) }
        }
        return [pscustomobject]@{ ExitCode = $p.ExitCode; Output = ($text -replace "`0", "") }
    } catch {
        return [pscustomobject]@{ ExitCode = -1; Output = "could not run ${File}: $($_.Exception.Message)" }
    } finally {
        $ErrorActionPreference = $prev
        Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-Wsl {
    param([string[]]$Arguments, [int]$TimeoutSec = 120)
    return (Invoke-NativeTimeout -File $script:WslExe -Arguments $Arguments -TimeoutSec $TimeoutSec)
}

# A command inside the distro, as root, through bash but NOT through WSL's own
# shell: --exec hands bash its arguments untouched, so nothing is parsed twice.
function Invoke-Guest {
    param([string]$Command, [int]$TimeoutSec = 120)
    $r = Invoke-Wsl @("-d", $Distro, "-u", "root", "--exec", "/bin/bash", "-c", $Command) -TimeoutSec $TimeoutSec
    return [pscustomobject]@{ ExitCode = $r.ExitCode; Output = "$($r.Output)".Trim() }
}

# Ok=$false means WSL itself did not answer (being updated, or wedged), which is
# not the same as "not registered".
function Get-RegisteredDistros {
    $r = Invoke-Wsl @("--list", "--quiet") -TimeoutSec 60
    if ($r.ExitCode -ne 0) {
        return [pscustomobject]@{ Ok = $false; Names = @(); Error = "$($r.Output)".Trim() }
    }
    $names = @(("$($r.Output)" -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    return [pscustomobject]@{ Ok = $true; Names = $names; Error = "" }
}

function Test-DistroAnswers {
    param([int]$TimeoutSec = 60)
    return ((Invoke-Wsl @("-d", $Distro, "-u", "root", "--exec", "/bin/true") -TimeoutSec $TimeoutSec).ExitCode -eq 0)
}


# ---------------------------------------------------------------------------
# .wslconfig: three keys, and nothing else is touched.
#
#   localhostForwarding=false  WSL's own relay binds 127.0.0.1 on the same ports
#                              as the LAN forward, and whichever binds first can
#                              stop the other binding at all.
#   autoMemoryReclaim          removed. Microsoft warned that "gradual" breaks
#                              the Docker daemon running as a service in WSL.
#   sparseVhd                  removed. WSL 2.5.6+ refuses sparse disks over a
#                              data-corruption risk.
#
# WSL reads the file only when its VM starts, so a change applies at the next
# start - which, for a keeper that starts at sign-in, is normally this one.
# ---------------------------------------------------------------------------
function Update-WslConfig {
    param([string]$Path = (Join-Path $env:USERPROFILE ".wslconfig"))
    $old = ""
    $lines = @()
    if (Test-Path $Path) {
        $old = [System.IO.File]::ReadAllText($Path)
        $lines = @($old -split "`r?`n")
        if ($lines.Count -and $lines[-1] -eq "") { $lines = @($lines | Select-Object -First ($lines.Count - 1)) }
    }
    $out = New-Object System.Collections.Generic.List[string]
    $section = ""
    $sawWsl2 = $false
    $forwardingSet = $false
    foreach ($raw in $lines) {
        $line = $raw.Trim()
        if ($line -match '^\[(.+)\]$') {
            if ($section -eq "wsl2" -and -not $forwardingSet) { $out.Add("localhostForwarding=false"); $forwardingSet = $true }
            $section = $Matches[1].Trim().ToLowerInvariant()
            if ($section -eq "wsl2") { $sawWsl2 = $true }
            $out.Add($raw)
            continue
        }
        if ($line -match '^(autoMemoryReclaim|sparseVhd)\s*=') { continue }
        if ($section -eq "wsl2" -and $line -match '^localhostForwarding\s*=') {
            if (-not $forwardingSet) { $out.Add("localhostForwarding=false"); $forwardingSet = $true }
            continue
        }
        $out.Add($raw)
    }
    if ($section -eq "wsl2" -and -not $forwardingSet) { $out.Add("localhostForwarding=false"); $forwardingSet = $true }
    if (-not $sawWsl2) { $out.Add("[wsl2]"); $out.Add("localhostForwarding=false") }
    $new = (($out.ToArray()) -join "`n") + "`n"
    if ($new -eq $old) { return $false }
    # LF and no BOM: WSL's parser rejects a BOM outright.
    [System.IO.File]::WriteAllText($Path, $new, (New-Object System.Text.UTF8Encoding($false)))
    return $true
}


# ---------------------------------------------------------------------------
# The keep-alive client ("anchor").
# ---------------------------------------------------------------------------

function Get-AnchorArguments {
    return @("-d", $Distro, "-u", "root", "--exec", "/bin/sleep", $AnchorSleep)
}

function Test-ProcessAlive {
    param($Process)
    if ($null -eq $Process) { return $false }
    try { return (-not $Process.HasExited) } catch { return $false }
}

# Ours, whoever started it: this keeper before a restart, or an -ExportTo run.
function Find-Anchor {
    try {
        $rows = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='wsl.exe'" -ErrorAction Stop)
    } catch { return $null }
    foreach ($row in $rows) {
        $cmd = "$($row.CommandLine)"
        if ($cmd -match "(^|\s)-d\s+$([regex]::Escape($Distro))(\s|$)" -and $cmd -like "*--exec /bin/sleep ${AnchorSleep}*") {
            try { return [System.Diagnostics.Process]::GetProcessById([int]$row.ProcessId) } catch { }
        }
    }
    return $null
}

# Hidden and without a console of its own: closing this window, or Ctrl+C in
# it, must not take the shop's server with it.
function Start-Anchor {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName        = $script:WslExe
    $psi.Arguments       = ((Get-AnchorArguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join " ")
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    if (-not $p.Start()) { throw "wsl.exe did not start" }
    return $p
}


# ---------------------------------------------------------------------------
# The stack and the LAN bridge.
# ---------------------------------------------------------------------------

# Through the distro's own watchdog: the same code that heals the stack every 5
# minutes, and it stands down while an update holds the stack. Plain compose
# only on an install that never registered the watchdog.
function Start-Stack {
    $cmd = "if systemctl cat pointy-watchdog.service >/dev/null 2>&1; then " +
           "systemctl start --no-block pointy-watchdog.service; " +
           "else cd '${GuestDir}' && docker compose --env-file .env -f docker-compose.yml up -d; fi"
    $r = Invoke-Guest $cmd -TimeoutSec 600
    if ($r.ExitCode -ne 0) {
        Write-Log "could not start the stack: $($r.Output)" "WARN"
        return
    }
    Write-Log "asked the distro's watchdog to bring the stack up"
}

# eth0 specifically: once Docker runs, the distro also holds docker0 and bridge
# addresses, and forwarding the LAN to one of those blackholes every till.
function Get-WslIp {
    $r = Invoke-Guest "ip -4 -o addr show dev eth0" -TimeoutSec 60
    if ($r.ExitCode -ne 0) { return $null }
    if ($r.Output -match 'inet\s+(\d{1,3}(?:\.\d{1,3}){3})') { return $Matches[1] }
    return $null
}

# netsh portproxy is carried out by the IP Helper service; without it every
# `add` succeeds and forwards nothing.
function Enable-IpHelper {
    try {
        $svc = Get-Service -Name iphlpsvc -ErrorAction Stop
        if ("$($svc.StartType)" -ne "Automatic") { Set-Service -Name iphlpsvc -StartupType Automatic -ErrorAction Stop }
        if ("$($svc.Status)" -ne "Running") {
            Start-Service -Name iphlpsvc -ErrorAction Stop
            Write-Log "started the IP Helper service (the LAN forward needs it)"
        }
    } catch {
        Write-Log "could not make sure the IP Helper service runs: $($_.Exception.Message)" "WARN"
    }
}

function Get-PortProxyTarget {
    param([int]$Port)
    $r = Invoke-Native -File "netsh.exe" -Arguments @("interface", "portproxy", "show", "v4tov4")
    foreach ($line in ($r.Output -split "`r?`n")) {
        if ($line -match '^\s*(\S+)\s+(\d+)\s+(\S+)\s+(\d+)\s*$' -and [int]$Matches[2] -eq $Port) { return $Matches[3] }
    }
    return $null
}

# -Force re-creates a forward that looks right: whether its listener actually
# bound is a separate question, and re-adding it makes the IP Helper try again.
function Set-PortProxy {
    param([int]$Port, [string]$Target, [switch]$Force)
    $current = Get-PortProxyTarget -Port $Port
    if ($current -eq $Target -and -not $Force) { return }
    if ($current) {
        Invoke-Native -File "netsh.exe" -Arguments @("interface", "portproxy", "delete", "v4tov4",
            "listenaddress=0.0.0.0", "listenport=$Port") | Out-Null
    }
    $r = Invoke-Native -File "netsh.exe" -Arguments @("interface", "portproxy", "add", "v4tov4",
        "listenaddress=0.0.0.0", "listenport=$Port", "connectaddress=$Target", "connectport=$Port")
    if ($r.ExitCode -ne 0) {
        Write-Log "could not forward LAN port ${Port} to ${Target}: $($r.Output.Trim())" "ERROR"
        return
    }
    Write-Log "LAN port ${Port} -> ${Target}:${Port}"
}

# The same rule names the Pointy installer uses, so nothing is duplicated.
function Add-FirewallRule {
    param([string]$Name, [int]$Port)
    try {
        if (Get-NetFirewallRule -DisplayName $Name -ErrorAction SilentlyContinue) { return }
        New-NetFirewallRule -DisplayName $Name -Direction Inbound -Action Allow `
            -Protocol TCP -LocalPort $Port -Profile Any -ErrorAction Stop | Out-Null
        Write-Log "opened the firewall for inbound TCP ${Port}"
    } catch {
        Write-Log "could not add firewall rule '${Name}': $($_.Exception.Message)" "WARN"
    }
}

function Update-LanBridge {
    param([string]$WslIp, [switch]$Force)
    Enable-IpHelper
    foreach ($port in @($ApiPort, $WebPort)) { Set-PortProxy -Port $port -Target $WslIp -Force:$Force }
    Add-FirewallRule -Name "Pointy API (TCP $ApiPort)" -Port $ApiPort
    Add-FirewallRule -Name "Pointy Web (TCP $WebPort)" -Port $WebPort
}

# One of OUR front doors answering, not whatever else holds the port. No proxy:
# a shop PC's system proxy must never be asked for a local address.
function Test-PointyHttp {
    param([string]$Url, [int]$TimeoutMs = 4000)
    $response = $null
    try {
        $request = [System.Net.WebRequest]::Create($Url)
        $request.Proxy = $null
        $request.Timeout = $TimeoutMs
        $response = $request.GetResponse()
        return ([int]$response.StatusCode -eq 200)
    } catch {
        return $false
    } finally {
        if ($response) { $response.Close() }
    }
}

function Get-LanIPv4 {
    try {
        return @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object {
            $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" -and
            "$($_.AddressState)" -eq "Preferred" -and
            $_.InterfaceAlias -notmatch 'WSL|Default Switch|VirtualBox|VMware|Loopback'
        } | Select-Object -ExpandProperty IPAddress)
    } catch { return @() }
}


# ---------------------------------------------------------------------------
# Housekeeping.
# ---------------------------------------------------------------------------

# Two keepers fight over one distro, so the PointyWSL boot task goes off. The
# caller attaches its own anchor FIRST: stopping that task can end the client
# holding the distro, and a distro with no client is powered off in 15 s.
function Disable-OldBootTask {
    param([switch]$StopRunning)
    try {
        $task = Get-ScheduledTask -TaskName $OldTaskName -ErrorAction SilentlyContinue
        if (-not $task) { return }
        if ($StopRunning -and "$($task.State)" -eq "Running") {
            Stop-ScheduledTask -TaskName $OldTaskName -ErrorAction Stop
            Write-Log "stopped the running '${OldTaskName}' supervisor"
        }
        if ("$($task.State)" -ne "Disabled") {
            Disable-ScheduledTask -TaskName $OldTaskName -ErrorAction Stop | Out-Null
            Write-Log "turned off the '${OldTaskName}' boot task; this keeper replaces it"
        }
    } catch {
        Write-Log "could not turn off the '${OldTaskName}' task: $($_.Exception.Message)" "WARN"
    }
}

# No close button, and Ctrl+C is ignored: a cashier tidying the taskbar must not
# be able to stop the shop's server. Task Manager, or -Uninstall, still can.
function Protect-ConsoleWindow {
    try { [Console]::TreatControlCAsInput = $true } catch { }
    try {
        Add-Type -Namespace PointyKeepAlive -Name Win32 -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern IntPtr GetSystemMenu(IntPtr hWnd, bool bRevert);
[DllImport("user32.dll")] public static extern bool DeleteMenu(IntPtr hMenu, uint uPosition, uint uFlags);
'@
        $hwnd = [PointyKeepAlive.Win32]::GetConsoleWindow()
        if ($hwnd -ne [IntPtr]::Zero) {
            $menu = [PointyKeepAlive.Win32]::GetSystemMenu($hwnd, $false)
            # SC_CLOSE, by command
            if ($menu -ne [IntPtr]::Zero) { [void][PointyKeepAlive.Win32]::DeleteMenu($menu, 0xF060, 0) }
        }
    } catch {
        Write-Log "could not remove the window's close button: $($_.Exception.Message)" "WARN"
    }
}

function Write-KeeperState {
    param($Anchor, [string]$WslIp, [bool]$Healthy, [int]$Restarts)
    try {
        $anchorPid = 0
        if (Test-ProcessAlive $Anchor) { $anchorPid = [int]$Anchor.Id }
        @{ keeper_pid = $PID; heartbeat_at = (Get-Date -Format "o"); anchor_pid = $anchorPid; wsl_ip = "$WslIp"
           healthy = $Healthy; distro_restarts = $Restarts } |
            ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8
    } catch { }
}


# ---------------------------------------------------------------------------
# The keeper. What the PointyKeepAlive task runs at sign-in.
# ---------------------------------------------------------------------------
function Invoke-KeepAlive {
    Set-Title "STARTING"
    if (Test-Path $MovedFile) {
        Write-Log "this server was moved to Linux (see ${MovedFile}); there is nothing to keep running here"
        Set-Title "MOVED TO LINUX"
        return
    }

    # One keeper per session. The task's one-minute repetition relies on this.
    $created = $false
    $mutex = New-Object System.Threading.Mutex($true, "Local\PointyKeepAlive", [ref]$created)
    if (-not $created) {
        $owned = $false
        try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { Write-Log "a keeper is already running in this session"; return }
    }

    Protect-ConsoleWindow
    $script:WslExe = Get-WslExe
    Write-Log "keeper started (PID ${PID}) as ${env:USERDOMAIN}\${env:USERNAME}; wsl.exe: $($script:WslExe)"
    try {
        if (Update-WslConfig) {
            Write-Log ".wslconfig updated (localhostForwarding=false; removed autoMemoryReclaim/sparseVhd); WSL applies it at its next start"
        }
    } catch { Write-Log "could not update .wslconfig: $($_.Exception.Message)" "WARN" }

    $anchor = $null
    $wslIp = $null
    $failures = 0
    $restarts = 0
    $oldTaskHandled = $false
    $notRegisteredLogged = $false
    $lastHealthy = $null
    $sinceStart = 0
    $lastForwardRepair = [datetime]::MinValue
    $relayWarned = $false

    while ($true) {
        $healthy = $false
        try {
            if (Test-Path $MovedFile) {
                Write-Log "this server was moved to Linux; the keeper stops here"
                Set-Title "MOVED TO LINUX"
                return
            }

            # 1. The anchor: adopt ours if one survived a keeper restart, else start one.
            if (-not (Test-ProcessAlive $anchor)) { $anchor = Find-Anchor }
            if (-not (Test-ProcessAlive $anchor)) {
                $list = Get-RegisteredDistros
                if (-not $list.Ok) {
                    Write-Log "WSL is not answering ($($list.Error)); trying again shortly" "WARN"
                    Set-Title "WAITING FOR WSL"
                } elseif ($list.Names -notcontains $Distro) {
                    if (-not $notRegisteredLogged) {
                        Write-Log ("the '${Distro}' distro is not registered for ${env:USERDOMAIN}\${env:USERNAME}. " +
                                   "Sign in as the Windows user that installed Pointy.") "ERROR"
                        $notRegisteredLogged = $true
                    }
                    Set-Title "PROBLEM - see log"
                } else {
                    $anchor = Start-Anchor
                    Write-Log "started WSL for '${Distro}' (keep-alive PID $($anchor.Id))"
                    $sinceStart = 0
                    $wslIp = $null
                    if (-not (Test-DistroAnswers -TimeoutSec 180)) {
                        Write-Log "the distro has not answered yet; checking again shortly" "WARN"
                    } elseif (-not (Test-Path $HoldFile)) {
                        Start-Stack
                    }
                }
            }

            # 2. Only now, with our own client holding the distro, retire the old task.
            if (-not $oldTaskHandled -and (Test-ProcessAlive $anchor)) {
                Disable-OldBootTask -StopRunning
                $oldTaskHandled = $true
            }

            if (Test-Path $HoldFile) {
                # An export owns the stack: hold WSL open, touch nothing else.
                Set-Title "MAINTENANCE (export running)"
            } elseif (Test-ProcessAlive $anchor) {
                # 3. The LAN forward follows the VM's address, which changes when the VM starts.
                $ip = Get-WslIp
                if ($ip -and $ip -ne $wslIp) {
                    Update-LanBridge -WslIp $ip
                    $wslIp = $ip
                }

                # 4. The path a till takes: this PC's LAN address, the forward, the
                #    edge, the backend behind it. Not 127.0.0.1 - WSL's own
                #    localhost relay can answer there while the LAN forward is dead.
                $lanIps = @(Get-LanIPv4)
                $probe = "127.0.0.1"
                if ($lanIps.Count) { $probe = $lanIps[0] }
                $edge = Test-PointyHttp "http://${probe}:${ApiPort}/healthz-edge"
                if (-not $edge -and $wslIp -and ((Get-Date) - $lastForwardRepair).TotalMinutes -ge 10 -and
                    (Test-PointyHttp "http://${wslIp}:${ApiPort}/healthz-edge")) {
                    $lastForwardRepair = Get-Date
                    Write-Log "the stack answers inside the VM but not at ${probe}:${ApiPort}; re-creating the LAN forward" "WARN"
                    Update-LanBridge -WslIp $wslIp -Force
                    Start-Sleep -Seconds 2
                    $edge = Test-PointyHttp "http://${probe}:${ApiPort}/healthz-edge"
                    if (-not $edge -and -not $relayWarned -and (Test-PointyHttp "http://127.0.0.1:${ApiPort}/healthz-edge")) {
                        Write-Log ("WSL's own localhost relay holds port ${ApiPort}, so the LAN forward cannot bind. " +
                                   "Restart Windows once: .wslconfig now turns that relay off.") "ERROR"
                        $relayWarned = $true
                    }
                }
                $healthy = $edge -and (Test-PointyHttp "http://${probe}:${ApiPort}/healthz/" -TimeoutMs 8000)

                if ($healthy) {
                    if ($lastHealthy -ne $true) {
                        $where = (@(Get-LanIPv4) | ForEach-Object { "http://${_}:${ApiPort}" }) -join ", "
                        Write-Log "Pointy is up; tills reach it at ${where}"
                    }
                    $failures = 0
                    Set-Title "RUNNING"
                } else {
                    $failures++
                    # Three minutes of silence is not a slow start any more. Then
                    # once every ten minutes: the watchdog heals, the keeper nudges.
                    if ($failures -eq 3 -or ($failures -gt 3 -and $failures % 10 -eq 3)) {
                        Write-Log "Pointy has not answered for ${failures} minute(s); asking the stack to start" "WARN"
                        Start-Stack
                        if ($wslIp) { Update-LanBridge -WslIp $wslIp -Force }
                    }
                    if ($sinceStart -lt 600 -and $failures -lt 5) { Set-Title "STARTING" } else { Set-Title "PROBLEM - see log" }
                }
                $lastHealthy = $healthy
            }
            Write-KeeperState -Anchor $anchor -WslIp $wslIp -Healthy $healthy -Restarts $restarts
        } catch {
            # One bad cycle must not end the keeper.
            Write-Log "keeper cycle failed: $($_.Exception.Message)" "ERROR"
        }

        # 5. Sleep until the next check, but wake the moment WSL stops the distro.
        if (Test-ProcessAlive $anchor) {
            $exited = $false
            try { $exited = $anchor.WaitForExit($CheckEverySec * 1000) } catch { Start-Sleep -Seconds $CheckEverySec }
            $sinceStart += $CheckEverySec
            if ($exited) {
                Write-Log "WSL stopped the distro (a WSL update, 'wsl --shutdown', or a crash); starting it again" "WARN"
                $anchor = $null
                $restarts++
                $lastHealthy = $null
            }
        } else {
            Start-Sleep -Seconds 15
            $sinceStart += 15
        }
    }
}


# ---------------------------------------------------------------------------
# -Install / -Uninstall
# ---------------------------------------------------------------------------

# A server must not sleep: WSL can wedge on resume until Windows restarts, and
# a sleeping PC serves no till. Fast Startup off too, so "Shut down" is a real one.
function Set-ServerPowerSettings {
    foreach ($setting in @("standby-timeout-ac", "hibernate-timeout-ac")) {
        $r = Invoke-Native -File "powercfg.exe" -Arguments @("/change", $setting, "0")
        if ($r.ExitCode -ne 0) { Write-Log "could not set ${setting} to never: $($r.Output.Trim())" "WARN" }
    }
    try {
        $key = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power"
        Set-ItemProperty -Path $key -Name HiberbootEnabled -Value 0 -Type DWord -ErrorAction Stop
    } catch { Write-Log "could not turn Fast Startup off: $($_.Exception.Message)" "WARN" }
    Write-Log "power: this PC no longer sleeps or hibernates on mains power; Fast Startup is off"
}

function Find-MoveScript {
    foreach ($candidate in @((Join-Path $PSScriptRoot "move-server.sh"),
                             (Join-Path (Split-Path -Parent $PSScriptRoot) "move-server.sh"),
                             (Join-Path $InstallRoot "move-server.sh"))) {
        if (Test-Path $candidate) { return $candidate }
    }
    return $null
}

function Test-AutoSignIn {
    try {
        $w = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -ErrorAction Stop
        return ("$($w.AutoAdminLogon)" -eq "1")
    } catch { return $false }
}

function Register-KeeperTask {
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $powershell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $conhost    = Join-Path $env:SystemRoot "System32\conhost.exe"
    $psArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -File `"$StableScript`" " +
              "-Distro `"$Distro`" -ApiPort $ApiPort -WebPort $WebPort"
    # The classic console host, named explicitly: on Windows 11 the default
    # terminal may be Windows Terminal, which neither starts minimised reliably
    # nor lets the close button be taken away.
    if (Test-Path $conhost) {
        $action = New-ScheduledTaskAction -Execute $conhost -Argument "`"$powershell`" $psArgs"
    } else {
        $action = New-ScheduledTaskAction -Execute $powershell -Argument $psArgs
    }
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $trigger.Delay = "PT10S"
    # Every minute after sign-in: if the window was closed or crashed, it is back
    # within a minute. While it runs, IgnoreNew makes each repetition a no-op.
    $trigger.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date).Date `
        -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 3650)).Repetition
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    # Interactive: in the signed-in session, where wsl.exe has always worked.
    # Highest: netsh portproxy and the firewall need an administrator, and a task
    # gets that without a UAC prompt.
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal `
        -Settings $settings -Force -ErrorAction Stop | Out-Null
    Write-Log "registered the '${TaskName}' task for ${user}: at sign-in, re-checked every minute"
}

function Invoke-Install {
    if (-not (Test-Admin)) { Die "run this from an ELEVATED PowerShell (right-click, Run as administrator)." }
    $script:WslExe = Get-WslExe
    $list = Get-RegisteredDistros
    if (-not $list.Ok) { Die "WSL is not answering: $($list.Error)" }
    if ($list.Names -notcontains $Distro) {
        Die ("the '${Distro}' distro is not registered for ${env:USERDOMAIN}\${env:USERNAME}. Sign in to Windows as " +
             "the user that installed Pointy and run -Install again.")
    }
    New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
    if ($PSCommandPath -ne $StableScript) { Copy-Item -Force $PSCommandPath $StableScript }
    $mover = Find-MoveScript
    if ($mover -and $mover -ne (Join-Path $InstallRoot "move-server.sh")) {
        Copy-Item -Force $mover (Join-Path $InstallRoot "move-server.sh")
    }
    Write-Log "installed the keeper to ${StableScript}"

    Set-ServerPowerSettings
    try {
        if (Update-WslConfig) { Write-Log ".wslconfig updated; WSL applies it the next time it starts" }
    } catch { Write-Log "could not update .wslconfig: $($_.Exception.Message)" "WARN" }
    Register-KeeperTask
    # Off, not stopped: the keeper stops a running copy once its own client holds the distro.
    Disable-OldBootTask
    if (Test-Path $HoldFile) { Remove-Item -Force $HoldFile }

    Start-ScheduledTask -TaskName $TaskName
    Write-Log "started the keeper: a minimised window titled 'Pointy server' now holds WSL open"
    if (-not (Test-AutoSignIn)) {
        Write-Log ("Windows is not set to sign in by itself. Unless this account has no password, the server " +
                   "will stay down after a restart until someone signs in. Turn on automatic sign-in for " +
                   "${env:USERNAME} (Sysinternals Autologon, or netplwiz).") "WARN"
    }
    Write-Log "log: ${LogFile}"
}

function Invoke-Uninstall {
    if (-not (Test-Admin)) { Die "run this from an ELEVATED PowerShell (right-click, Run as administrator)." }
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Write-Log "removed the '${TaskName}' task"
    } catch { Write-Log "there was no '${TaskName}' task to remove" }
    try {
        if (Get-ScheduledTask -TaskName $OldTaskName -ErrorAction SilentlyContinue) {
            Enable-ScheduledTask -TaskName $OldTaskName -ErrorAction Stop | Out-Null
            Write-Log "turned the '${OldTaskName}' boot task back on"
        }
    } catch { Write-Log "could not turn the '${OldTaskName}' task back on: $($_.Exception.Message)" "WARN" }
    Write-Log "a keeper window that is still open keeps WSL up until Windows restarts (end it in Task Manager to stop it now)"
}


# ---------------------------------------------------------------------------
# -ExportTo: the Windows half of move-server.sh export.
# ---------------------------------------------------------------------------

function ConvertTo-WslPath {
    param([string]$WindowsPath)
    $full = [System.IO.Path]::GetFullPath($WindowsPath).TrimEnd('\')
    return "/mnt/" + $full.Substring(0, 1).ToLowerInvariant() + ($full.Substring(2) -replace '\\', '/')
}

function Invoke-Export {
    if (-not (Test-Admin)) { Die "run this from an ELEVATED PowerShell (right-click, Run as administrator)." }
    $script:WslExe = Get-WslExe
    $target = [System.IO.Path]::GetFullPath($ExportTo)
    if ($target -notmatch '^[A-Za-z]:\\') { Die "-ExportTo must be a folder on a drive letter, for example D:\PointyMove" }
    $mover = Find-MoveScript
    if (-not $mover) { Die "move-server.sh was not found next to this script or in ${InstallRoot}." }
    New-Item -ItemType Directory -Force -Path $target | Out-Null

    # An LF copy on the drive: the export runs it, and the new machine runs the
    # very same file to import. A CR left in a .sh is "\r: command not found".
    $text = [System.IO.File]::ReadAllText($mover) -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText((Join-Path $target "move-server.sh"), $text, (New-Object System.Text.UTF8Encoding($false)))

    # A USB drive plugged in after WSL started is not mounted inside it yet.
    $guestTarget = ConvertTo-WslPath $target
    $letter = $target.Substring(0, 1).ToLowerInvariant()
    $r = Invoke-Guest ("test -d /mnt/${letter} || { mkdir -p /mnt/${letter} && mount -t drvfs ${letter}: /mnt/${letter}; }; " +
                       "test -d '${guestTarget}'") -TimeoutSec 180
    if ($r.ExitCode -ne 0) { Die "WSL cannot see ${target}: $($r.Output)" }

    Set-Content -Path $HoldFile -Value ("export started " + (Get-Date -Format "o")) -Encoding UTF8
    Write-Log "the keeper now holds WSL open and leaves the stack to the export"

    $exportArgs = @("-d", $Distro, "-u", "root", "--exec", "/bin/bash", "${guestTarget}/move-server.sh", "export", $guestTarget)
    if ($KeepRunning) { $exportArgs += "--restart" }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        # To the screen, live: inside a function its output would otherwise
        # become this function's return value.
        & $script:WslExe @exportArgs | Out-Host
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prev }

    if ($code -ne 0) {
        Remove-Item -Force $HoldFile -ErrorAction SilentlyContinue
        Write-Log "the export FAILED (exit ${code}); the server keeps running on this PC. See the output above." "ERROR"
        return 1
    }
    if ($KeepRunning) {
        Remove-Item -Force $HoldFile -ErrorAction SilentlyContinue
        Write-Log "rehearsal finished: the stack is running again on this PC; ${target} holds a full copy"
        return 0
    }

    Set-Content -Path $MovedFile -Encoding UTF8 -Value @(
        ("Exported to " + $target + " on " + (Get-Date -Format "o") + "."),
        "The Pointy stack on this PC is stopped for good. To bring it back instead of moving:",
        "  1. delete this file",
        "  2. powershell -ExecutionPolicy Bypass -File $StableScript -Install",
        "  3. wsl -d $Distro -u root -- bash $GuestDir/register-autostart.sh")
    try { Disable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null } catch { }
    Write-Log "export complete. The stack on this PC is stopped for good and the keeper is off."
    Write-Log "Next: copy ${target} OFF this PC if Linux will be installed on it, then on the Linux machine run:" "WARN"
    Write-Log "  sudo bash <folder>/move-server.sh import <folder>" "WARN"
    return 0
}


# ---------------------------------------------------------------------------
# Entry point.
# ---------------------------------------------------------------------------
$modeCount = 0
if ($Install)         { $modeCount++ }
if ($Uninstall)       { $modeCount++ }
if ($ExportTo -ne "") { $modeCount++ }
if ($modeCount -gt 1) { Die "use only one of -Install, -Uninstall and -ExportTo." }
if ($Install)        { Invoke-Install; exit 0 }
if ($Uninstall)      { Invoke-Uninstall; exit 0 }
if ($ExportTo -ne "") { exit (Invoke-Export) }
Invoke-KeepAlive
