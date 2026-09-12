<#
  Pointy on-prem - the ONLY PowerShell we ship.

  Everything that deploys, updates, watches and heals the stack is bash under
  deploy/onprem/*.sh, running inside a WSL2 distro. This file exists solely
  because two jobs cannot be done from Linux:

    1. INSTALL  - enabling the Windows features, installing WSL, importing the
                  distro, and registering the boot task.
    2. -Boot    - bridging the Windows LAN into the NAT'd WSL VM (portproxy +
                  firewall), which must be re-done on every boot because the
                  WSL VM's IP changes each time it starts.

  It deliberately contains NO deployment logic. It hands off to install.sh
  inside the distro and never duplicates it.

      # First install (elevated PowerShell, from the extracted bundle):
      powershell -ExecutionPolicy Bypass -File .\wsl\bootstrap-wsl.ps1

      # What the scheduled task runs every boot + every 5 minutes:
      powershell -ExecutionPolicy Bypass -File .\wsl\bootstrap-wsl.ps1 -Boot

  Re-run the install form any time; it is idempotent.
#>
[CmdletBinding()]
param(
    # Boot-time reconcile: start the distro and re-point the LAN bridge at it.
    [switch]$Boot,
    # Distro name. Changing this on an existing install orphans the old one.
    [string]$Distro = "Pointy",
    # Where the distro's ext4.vhdx lives. MUST be a local NTFS disk.
    [string]$InstallRoot = (Join-Path $env:ProgramData "Pointy"),
    # LAN ports published from inside WSL to the shop network.
    [int]$ApiPort = 8000,
    [int]$WebPort = 80,
    # Skip the interactive confirmation when Docker Desktop is present.
    [switch]$Force
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# wsl.exe emits UTF-16LE by default, which turns every parsed line into
# "P\0o\0i\0n\0t\0y\0". WSL_UTF8 makes it emit UTF-8 (wsl.exe 0.64+); we still
# decode defensively below for the inbox Windows 10 build that ignores it.
$env:WSL_UTF8 = "1"

$BundleRoot  = Split-Path -Parent $PSScriptRoot   # ...\<bundle>\  (wsl\ is one down)
$LogDir      = Join-Path $InstallRoot "logs"
$LogFile     = Join-Path $LogDir "bootstrap.log"
$StateFile   = Join-Path $InstallRoot "bridge-state.json"
$TaskName    = "PointyWSL"
$GuestDir    = "/opt/pointy"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "{0} [pointy-wsl] {1} {2}" -f (Get-Date -Format "yyyy-MM-ddTHH:mm:ss"), $Level, $Message
    switch ($Level) {
        "WARN"  { Write-Host $line -ForegroundColor Yellow }
        "ERROR" { Write-Host $line -ForegroundColor Red }
        default { Write-Host $line }
    }
    try {
        if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
    } catch { }   # never let logging break the install
}

function Die { param([string]$Message) Write-Log $Message "ERROR"; exit 1 }

function Test-Admin {
    (New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent())
    ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

# Run a native command and return its stdout, without $ErrorActionPreference
# turning ordinary non-zero exits (which wsl.exe uses for "not installed") into
# terminating errors.
function Invoke-Native {
    param([string]$File, [string[]]$Arguments)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = & $File @Arguments 2>&1
        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output   = ($out | Out-String)
        }
    } finally { $ErrorActionPreference = $prev }
}

function Invoke-Wsl {
    param([string[]]$Arguments)
    Invoke-Native -File "wsl.exe" -Arguments $Arguments
}

# Run a command inside the distro as root, returning trimmed stdout.
function Invoke-Guest {
    param([string]$Command)
    $r = Invoke-Wsl @("-d", $Distro, "-u", "root", "--", "bash", "-lc", $Command)
    return [pscustomobject]@{ ExitCode = $r.ExitCode; Output = $r.Output.Trim() }
}

function Get-RegisteredDistros {
    $r = Invoke-Wsl @("--list", "--quiet")
    if ($r.ExitCode -ne 0) { return @() }
    # Strip NULs in case WSL_UTF8 was ignored (inbox Windows 10 wsl.exe).
    return ($r.Output -replace "`0", "") -split "`r?`n" |
        ForEach-Object { $_.Trim() } | Where-Object { $_ }
}

function Test-DistroExists { (Get-RegisteredDistros) -contains $Distro }


# ---------------------------------------------------------------------------
# -Boot : bridge the LAN into the NAT'd WSL VM.
#
# WSL2 sits behind a NAT with a fresh private IP on every VM start, and
# localhostForwarding only maps the Windows *loopback* - not the LAN. So the
# tills cannot reach the stack until we forward the host's ports at the WSL IP,
# and we must re-do it whenever that IP changes.
#
# We do NOT use mirrored networking (which would remove all of this) because it
# needs Windows 11 22H2+; the shop fleet includes Windows 10, and running two
# different network designs is the exact split this migration exists to end.
# ---------------------------------------------------------------------------

function Get-WslIp {
    # eth0 specifically, NOT `hostname -I`: once Docker is running the distro also
    # holds docker0 and per-network bridge addresses (172.17.x, 172.18.x), and
    # `hostname -I` returns them in no guaranteed order. Forwarding the LAN to a
    # docker bridge address silently blackholes every till.
    #
    # Parsed here rather than with awk/cut inside the guest: the command crosses
    # PowerShell -> wsl.exe -> bash quoting, and a nested quote is a real bug
    # waiting to happen for no benefit.
    $r = Invoke-Guest "ip -4 -o addr show dev eth0"
    if ($r.ExitCode -ne 0) { return $null }
    if (($r.Output -replace "`0", "") -match 'inet\s+(\d{1,3}(?:\.\d{1,3}){3})') {
        return $Matches[1]
    }
    return $null
}

# portproxy is implemented by the IP Helper service. Without it running, every
# `netsh ... add` silently succeeds and forwards nothing - the single most
# common reason a WSL deployment is unreachable from the LAN.
function Enable-IpHelper {
    try {
        $svc = Get-Service -Name iphlpsvc -ErrorAction Stop
        if ($svc.StartType -ne "Automatic") {
            Set-Service -Name iphlpsvc -StartupType Automatic -ErrorAction Stop
            Write-Log "set the IP Helper service to start automatically"
        }
        if ($svc.Status -ne "Running") {
            Start-Service -Name iphlpsvc -ErrorAction Stop
            Write-Log "started the IP Helper service (portproxy needs it)"
        }
    } catch {
        Write-Log "could not ensure the IP Helper service is running: $($_.Exception.Message)" "WARN"
    }
}

function Get-PortProxyTarget {
    param([int]$Port)
    $r = Invoke-Native -File "netsh.exe" -Arguments @("interface", "portproxy", "show", "v4tov4")
    foreach ($line in ($r.Output -split "`r?`n")) {
        # "0.0.0.0         8000        172.28.144.3    8000"
        if ($line -match '^\s*(\S+)\s+(\d+)\s+(\S+)\s+(\d+)\s*$' -and [int]$Matches[2] -eq $Port) {
            return $Matches[3]
        }
    }
    return $null
}

function Set-PortProxy {
    param([int]$Port, [string]$Target)
    $current = Get-PortProxyTarget -Port $Port
    if ($current -eq $Target) { return $false }
    if ($current) {
        Invoke-Native -File "netsh.exe" -Arguments @(
            "interface", "portproxy", "delete", "v4tov4",
            "listenaddress=0.0.0.0", "listenport=$Port") | Out-Null
    }
    $r = Invoke-Native -File "netsh.exe" -Arguments @(
        "interface", "portproxy", "add", "v4tov4",
        "listenaddress=0.0.0.0", "listenport=$Port",
        "connectaddress=$Target", "connectport=$Port")
    if ($r.ExitCode -ne 0) {
        Write-Log "failed to forward port ${Port} to ${Target}: $($r.Output.Trim())" "ERROR"
        return $false
    }
    Write-Log "LAN port ${Port} -> ${Target}:${Port} (was ${current})"
    return $true
}

# Windows very often already has something on :80 - IIS, the World Wide Web
# Publishing Service, a vendor's print or label server. `netsh ... add` still
# reports success in that case; the listener simply never binds, and the symptom
# is "the browser app doesn't load" with a perfectly healthy stack behind it.
# Name it at install time instead of leaving it to be debugged on site.
function Test-PortConflict {
    param([int]$Port)
    try {
        # portproxy's own listeners are owned by the System process (PID 4), so
        # anything else holding the port is a genuine conflict.
        $owners = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop |
            Where-Object { $_.OwningProcess -ne 4 } |
            Select-Object -ExpandProperty OwningProcess -Unique
        if (-not $owners) { return }
        $names = ($owners | ForEach-Object {
            (Get-Process -Id $_ -ErrorAction SilentlyContinue).ProcessName
        } | Where-Object { $_ }) -join ", "
        Write-Log ("port ${Port} is already held on this machine by: ${names}. The LAN " +
                   "forward for it will not bind, so that service will be unreachable.") "WARN"
        if ($Port -eq $WebPort) {
            Write-Log ("  Fix: set POINTY_WEB_PORT to a free port in /opt/pointy/.env, re-run " +
                       "install.sh inside the distro, and re-run this script with -WebPort <port>.") "WARN"
        } else {
            Write-Log "  Fix: stop the conflicting service, or set POINTY_BACKEND_PORT and -ApiPort together." "WARN"
        }
    } catch { }   # Get-NetTCPConnection throws when nothing is listening
}

function Add-FirewallRule {
    param([string]$Name, [int]$Port)
    try {
        if (Get-NetFirewallRule -DisplayName $Name -ErrorAction SilentlyContinue) { return }
        New-NetFirewallRule -DisplayName $Name -Direction Inbound -Action Allow `
            -Protocol TCP -LocalPort $Port -Profile Any -ErrorAction Stop | Out-Null
        Write-Log "opened the firewall for inbound TCP ${Port} ('${Name}')"
    } catch {
        Write-Log "could not add firewall rule '${Name}': $($_.Exception.Message)" "WARN"
    }
}

function Invoke-BootReconcile {
    if (-not (Test-DistroExists)) {
        Die "distro '$Distro' is not registered - run this script without -Boot to install."
    }

    # Starting any process boots the VM and, with systemd=true, PID 1 keeps it
    # alive afterwards. This is also what recovers from `wsl --shutdown`, which
    # Windows Update triggers when it services WSL.
    $ping = Invoke-Guest "true"
    if ($ping.ExitCode -ne 0) {
        Die "could not start distro '$Distro': $($ping.Output)"
    }

    Enable-IpHelper

    $ip = Get-WslIp
    if (-not $ip) { Die "could not read the distro's eth0 address; not touching the LAN bridge." }

    $changed = $false
    foreach ($port in @($ApiPort, $WebPort)) {
        Test-PortConflict -Port $port
        if (Set-PortProxy -Port $port -Target $ip) { $changed = $true }
    }
    Add-FirewallRule -Name "Pointy API (TCP $ApiPort)" -Port $ApiPort
    Add-FirewallRule -Name "Pointy Web (TCP $WebPort)" -Port $WebPort

    try {
        @{ wsl_ip = $ip; api_port = $ApiPort; web_port = $WebPort
           updated_at = (Get-Date -Format "o") } |
            ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8
    } catch { }

    if ($changed) { Write-Log "LAN bridge reconciled onto ${ip}" }
    else { Write-Log "LAN bridge already correct (${ip}); nothing to do" }
}


# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

function Assert-Preflight {
    if (-not (Test-Admin)) {
        Die "run this in an ELEVATED (Administrator) PowerShell."
    }
    if ([Environment]::Is64BitOperatingSystem -eq $false) {
        Die "WSL2 requires 64-bit Windows."
    }

    $build = [int](Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").CurrentBuildNumber
    if ($build -lt 19041) {
        Die ("Windows build ${build} is too old for WSL2 (needs 19041 / Windows 10 2004 or newer). " +
             "Update Windows, or install this shop on a newer machine.")
    }
    if ($build -lt 19044) {
        Write-Log ("Windows build ${build} is out of support; WSL2 works but you are on your own " +
                   "for OS security fixes. 19044 (21H2) or newer is strongly recommended.") "WARN"
    }
    Write-Log "Windows build ${build}: OK"

    # Virtualization must be on in firmware. This is the one failure that needs
    # a physical visit (a BIOS/UEFI setting), so name it precisely rather than
    # letting `wsl --import` fail with an opaque HCS error later.
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    if (-not $cs.HypervisorPresent) {
        $virt = (Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1).VirtualizationFirmwareEnabled
        if ($virt -eq $false) {
            Die ("Hardware virtualization is DISABLED in this machine's BIOS/UEFI. " +
                 "Reboot into firmware setup and enable Intel VT-x / AMD-V (often called " +
                 "'Virtualization Technology' or 'SVM Mode'), then re-run this script.")
        }
        Write-Log "no hypervisor running yet - expected before the Windows features are enabled" "INFO"
    }

    $drive = (Get-Item $InstallRoot -ErrorAction SilentlyContinue)
    $root  = if ($drive) { $drive.PSDrive.Name } else { (Split-Path -Qualifier $InstallRoot).TrimEnd(':') }
    try {
        $free = (Get-PSDrive -Name $root).Free / 1GB
        if ($free -lt 20) {
            Write-Log ("only {0:N1} GB free on {1}: - the distro, images and Postgres data all live " +
                       "here and the virtual disk only ever grows. 20 GB+ recommended." -f $free, $root) "WARN"
        }
    } catch { }

    if (Get-Service -Name "com.docker.service" -ErrorAction SilentlyContinue) {
        Write-Log ("Docker Desktop is installed on this machine. This installer does NOT migrate an " +
                   "existing Docker Desktop deployment - it builds a clean WSL one alongside it.") "WARN"
        if (-not $Force) {
            $answer = Read-Host "Continue anyway? Type 'yes' to proceed"
            if ($answer -ne "yes") { Die "aborted at the operator's request." }
        }
    }
}

function Enable-WindowsFeatures {
    $needed = @("Microsoft-Windows-Subsystem-Linux", "VirtualMachinePlatform")
    $rebootRequired = $false
    foreach ($feature in $needed) {
        $state = Invoke-Native -File "dism.exe" -Arguments @(
            "/online", "/get-featureinfo", "/featurename:$feature")
        if ($state.Output -match "State\s*:\s*Enabled") {
            Write-Log "Windows feature ${feature}: already enabled"
            continue
        }
        Write-Log "enabling Windows feature ${feature}..."
        # DISM works with no internet, unlike the Store-based paths.
        $r = Invoke-Native -File "dism.exe" -Arguments @(
            "/online", "/enable-feature", "/featurename:$feature", "/all", "/norestart")
        if ($r.ExitCode -eq 3010) { $rebootRequired = $true }
        elseif ($r.ExitCode -ne 0) { Die "could not enable ${feature}: $($r.Output.Trim())" }
    }
    if ($rebootRequired) {
        Write-Log "" 
        Write-Log "REBOOT REQUIRED to finish enabling the Windows virtualization features." "WARN"
        Write-Log "Reboot, then run this exact command again to continue the install:" "WARN"
        Write-Log "  powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`"" "WARN"
        exit 2
    }
}

# Is a working, modern wsl.exe actually present? This is the ONLY thing that
# decides whether the WSL step succeeded. An installer exit code is a hint about
# one attempt; this is the outcome, and the outcome is what the next step needs.
function Test-WslReady {
    $ver = Invoke-Wsl @("--version")
    if ($ver.ExitCode -eq 0 -and (($ver.Output -replace "`0","") -match "WSL[^\d]*\d+\.\d+")) {
        return $true
    }
    # Older inbox builds have no --version but do answer --status.
    $st = Invoke-Wsl @("--status")
    return ($st.ExitCode -eq 0)
}

function Get-WslVersionLine {
    $ver = Invoke-Wsl @("--version")
    if ($ver.ExitCode -ne 0) { return "unknown" }
    return ((($ver.Output -replace "`0","") -split "`r?`n" | Select-Object -First 1).Trim())
}

function Install-Wsl {
    # Already working (a re-run, or an up-to-date machine)? Do nothing. Installing
    # over a good WSL is how a working machine gets broken.
    if (Test-WslReady) {
        Write-Log "WSL already present and working: $(Get-WslVersionLine)"
        $r = Invoke-Wsl @("--set-default-version", "2")
        if ($r.ExitCode -ne 0) { Write-Log "could not set WSL default version 2: $($r.Output.Trim())" "WARN" }
        return
    }

    # Prefer the MSI we ship: it is the same modern wsl.exe on Windows 10 and 11,
    # needs no internet and no Microsoft Store (shops are frequently offline, and
    # the Store is commonly stripped from POS images).
    $msi = Get-ChildItem -Path $PSScriptRoot -Filter "wsl*.msi" -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1

    $rebootHint = $false
    $lastCode   = $null
    $lastOutput = ""

    if ($msi) {
        # Windows Installer is single-threaded machine-wide. The DISM feature
        # enable we just ran, Windows Update, or a vendor updater will hold that
        # mutex and msiexec returns 1618 IMMEDIATELY. That is a "come back in a
        # moment", not a failure - and it is why this step used to fail on the
        # first run and pass on the second.
        $transient = @(1618, 1601)   # 1601 = Windows Installer service unavailable
        $attempts  = 5
        for ($i = 1; $i -le $attempts; $i++) {
            Write-Log "installing WSL from the bundled $($msi.Name) (attempt ${i}/${attempts})..."
            # Verbose MSI log next to our own, so a genuine failure is diagnosable
            # on site instead of being a bare exit code.
            $msiLog = Join-Path $LogDir ("wsl-msi-{0}.log" -f $i)
            try { if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null } } catch { }
            # No manual quoting: PowerShell quotes each array element itself, and
            # adding our own passes literal quote characters through to msiexec.
            $r = Invoke-Native -File "msiexec.exe" -Arguments @(
                "/i", $msi.FullName, "/quiet", "/norestart", "/l*v", $msiLog)
            $lastCode = $r.ExitCode; $lastOutput = $r.Output.Trim()

            if ($r.ExitCode -in @(0, 1638)) { break }          # 1638 = same-or-newer installed
            if ($r.ExitCode -in @(3010, 1641)) { $rebootHint = $true; break }
            if ($r.ExitCode -in $transient -and $i -lt $attempts) {
                Write-Log ("Windows Installer is busy (exit $($r.ExitCode)); another install is " +
                           "running. Waiting 20s and retrying.") "WARN"
                Start-Sleep -Seconds 20
                continue
            }
            Write-Log "msiexec returned $($r.ExitCode); verifying whether WSL works anyway. Log: ${msiLog}" "WARN"
            break
        }
    } else {
        Write-Log "no bundled WSL MSI found; falling back to 'wsl --update' (needs internet)" "WARN"
        $r = Invoke-Wsl @("--update")
        $lastCode = $r.ExitCode; $lastOutput = $r.Output.Trim()
    }

    # THE decision. `wsl --update` reports non-zero when there is nothing to do,
    # and msiexec can report an odd code for an install that landed perfectly, so
    # neither exit code is trusted over the machine's actual state.
    if (Test-WslReady) {
        if ($null -ne $lastCode -and $lastCode -notin @(0, 1638)) {
            Write-Log "the WSL installer returned ${lastCode}, but WSL works - continuing." "WARN"
        }
        Write-Log "WSL: $(Get-WslVersionLine)"
        $r = Invoke-Wsl @("--set-default-version", "2")
        if ($r.ExitCode -ne 0) { Write-Log "could not set WSL default version 2: $($r.Output.Trim())" "WARN" }
        return
    }

    # Not working. Now the exit code earns its keep as the explanation.
    if ($rebootHint) {
        Write-Log ""
        Write-Log "WSL was installed but needs a REBOOT before it can run." "WARN"
        Write-Log "Reboot, then run this exact command again to continue the install:" "WARN"
        Write-Log "  powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`"" "WARN"
        exit 2
    }
    if (-not $msi) {
        Die ("WSL is not installed and could not be updated online (exit ${lastCode}). Put the WSL MSI " +
             "(wsl.<version>.x64.msi) next to this script and re-run. ${lastOutput}")
    }
    Die ("WSL still does not run after installing $($msi.Name) (msiexec exit ${lastCode}). " +
         "The verbose MSI log is under ${LogDir}. If this machine has never had the " +
         "virtualization features enabled, reboot once and re-run this script. ${lastOutput}")
}

function Write-WslConfig {
    # Host-wide WSL2 VM tuning. Unknown keys are ignored with a warning by older
    # wsl.exe, so we only write the modern ones when the running WSL supports
    # them - otherwise every single `wsl` call prints noise into our logs.
    $totalGb = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    $memGb   = [int][math]::Max(4, [math]::Min(8, [math]::Floor($totalGb / 2)))
    $cpus    = [int][math]::Max(2, [math]::Min(4, [Environment]::ProcessorCount))

    $modern = $false
    $ver = Invoke-Wsl @("--version")
    if ($ver.ExitCode -eq 0 -and (($ver.Output -replace "`0","") -match 'WSL[^\d]*(\d+)\.(\d+)')) {
        $modern = ([int]$Matches[1] -ge 2)
    }

    $lines = @(
        "# GENERATED by bootstrap-wsl.ps1 - Pointy on-prem.",
        "[wsl2]",
        "memory=${memGb}GB",
        "processors=${cpus}",
        "swap=2GB",
        "# The tills reach the stack through netsh portproxy (see -Boot); this only",
        "# covers apps running on the server itself, e.g. a till app on this same PC.",
        "localhostForwarding=true",
        "guiApplications=false",
        "nestedVirtualization=false"
    )
    if ($modern) {
        $lines += @(
            "# Let the virtual disk hand free space back to Windows. Without this the",
            "# vhdx only ever grows - a year of image churn silently fills C:.",
            "sparseVhd=true",
            "autoMemoryReclaim=gradual",
            "# Never idle-stop the VM: it is a server, not a developer shell.",
            "vmIdleTimeout=-1"
        )
    }

    $path = Join-Path $env:USERPROFILE ".wslconfig"
    # LF + no BOM: the WSL config parser rejects a BOM outright.
    [System.IO.File]::WriteAllText($path, ($lines -join "`n") + "`n",
        (New-Object System.Text.UTF8Encoding($false)))
    Write-Log "wrote ${path} (memory=${memGb}GB, processors=${cpus})"
}

function Import-Distro {
    if (Test-DistroExists) {
        Write-Log "distro '${Distro}' is already registered; leaving it and its data alone"
        return
    }
    $rootfs = Get-ChildItem -Path $PSScriptRoot -Filter "pointy-wsl-rootfs*.tar*" -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $rootfs) {
        Die ("no distro image found. Expected pointy-wsl-rootfs.tar.gz next to this script - " +
             "is this a complete bundle?")
    }
    $target = Join-Path $InstallRoot "distro"
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Write-Log "importing '${Distro}' from $($rootfs.Name) into ${target} (this takes a few minutes)..."
    $r = Invoke-Wsl @("--import", $Distro, $target, $rootfs.FullName, "--version", "2")
    if ($r.ExitCode -ne 0) {
        $detail = ($r.Output -replace "`0", "").Trim()
        Die "wsl --import failed: ${detail}"
    }
    Write-Log "distro '${Distro}' imported"
}

function Set-GuestTimezone {
    # A freshly imported distro is UTC. Z-reports, day rollups, holiday tagging
    # and shift boundaries are all business-local, so an unset timezone silently
    # files the evening's sales on the wrong day.
    try {
        $winTz = (Get-TimeZone).Id
        $map = Join-Path $PSScriptRoot "timezone-map.txt"
        $ianaTz = $null
        if (Test-Path $map) {
            foreach ($line in (Get-Content $map)) {
                if ($line -match '^\s*#') { continue }
                $parts = $line -split '\|', 2
                if ($parts.Count -eq 2 -and $parts[0].Trim() -eq $winTz) { $ianaTz = $parts[1].Trim(); break }
            }
        }
        if (-not $ianaTz) {
            Write-Log "no IANA mapping for Windows time zone '${winTz}'; the distro stays on UTC." "WARN"
            Write-Log "  Set it by hand:  wsl -d ${Distro} -u root ln -sf /usr/share/zoneinfo/<Area/City> /etc/localtime" "WARN"
            return
        }
        Invoke-Guest "ln -sf /usr/share/zoneinfo/${ianaTz} /etc/localtime && echo ${ianaTz} > /etc/timezone" | Out-Null
        Write-Log "distro time zone set to ${ianaTz} (from Windows '${winTz}')"
    } catch {
        Write-Log "could not set the distro time zone: $($_.Exception.Message)" "WARN"
    }
}

function Copy-BundleIntoGuest {
    # Stream the bundle in as a tar over stdin. A Windows-side file copy would
    # go through DrvFs and can rewrite line endings; a single CRLF in a .sh makes
    # bash fail with "\r: command not found", and a CRLF in .env puts a trailing
    # \r inside the generated Postgres password - a failure that only shows up
    # later, as an unexplained authentication error.
    Write-Log "copying the bundle into ${GuestDir} inside the distro..."
    Invoke-Guest "mkdir -p ${GuestDir}" | Out-Null

    $tar = Join-Path $env:TEMP ("pointy-bundle-{0}.tar" -f ([guid]::NewGuid().ToString("N")))
    try {
        # bsdtar ships in Windows 10 17063+.
        #
        # wsl/ goes IN (minus its install-only inputs): update.sh adopts
        # wsl/bootstrap-wsl.ps1 out of each new bundle, and -Boot copies it back
        # out to Windows - that is the only way a fix to the LAN bridge ever
        # reaches an installed shop. The rootfs tarball and the MSI are excluded:
        # they are one-time install inputs and together are most of the bundle.
        $r = Invoke-Native -File "tar.exe" -Arguments @(
            "-cf", $tar, "-C", $BundleRoot,
            "--exclude", "./wsl/pointy-wsl-rootfs*",
            "--exclude", "./wsl/*.msi",
            ".")
        if ($r.ExitCode -ne 0) { Die "could not archive the bundle: $($r.Output.Trim())" }

        $guestTar = "/tmp/pointy-bundle.tar"
        $winTar   = $tar -replace '\\', '/'
        # Read it from the Windows filesystem in BINARY through /mnt - the copy
        # is byte-exact because tar content is opaque to DrvFs.
        $mnt = "/mnt/" + $winTar.Substring(0,1).ToLower() + $winTar.Substring(2)
        $x = Invoke-Guest "cp '${mnt}' ${guestTar} && tar -xf ${guestTar} -C ${GuestDir} && rm -f ${guestTar}"
        if ($x.ExitCode -ne 0) { Die "could not unpack the bundle inside the distro: $($x.Output)" }

        Invoke-Guest "chmod +x ${GuestDir}/*.sh 2>/dev/null; true" | Out-Null
        # Belt and braces: strip any CR that survived, so bash never sees one.
        Invoke-Guest "sed -i 's/\r$//' ${GuestDir}/*.sh 2>/dev/null; true" | Out-Null
        Write-Log "bundle unpacked into ${GuestDir}"
    } finally {
        Remove-Item $tar -ErrorAction SilentlyContinue
    }
}

function Invoke-GuestInstall {
    Write-Log "running install.sh inside the distro - this is where the stack actually comes up..."
    # Stream it live: this step loads images and starts Postgres, and takes
    # minutes. A silent installer here reads as a hang.
    $code = 1
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        # `cd` inside the command rather than wsl.exe's --cd, which only exists
        # in newer wsl.exe builds.
        & wsl.exe -d $Distro -u root -- bash -lc "cd '$GuestDir' && bash ./install.sh"
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prev }
    if ($code -ne 0) { Die "install.sh failed inside the distro (exit ${code}). See the output above." }
    Write-Log "install.sh completed"
}

# The scheduled task must NOT point into the extracted bundle folder: an
# operator tidying up their Downloads directory would silently disable the LAN
# bridge, and the bundle is not where updates land anyway. Keep a copy at a
# stable path and run that.
function Install-BootstrapToStablePath {
    New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
    foreach ($name in @("bootstrap-wsl.ps1", "timezone-map.txt")) {
        $src = Join-Path $PSScriptRoot $name
        if (Test-Path $src) { Copy-Item -Force $src (Join-Path $InstallRoot $name) }
    }
    Write-Log "installed the bootstrap to ${InstallRoot}"
}

# Promote a newer bootstrap that arrived inside the distro with a release
# bundle, then re-exec into it. This mirrors update-agent.sh's self-promote: the
# Windows half of the deployment has to be updatable from the Linux half, or
# every shop keeps the bridge it was installed with forever.
function Update-BootstrapFromGuest {
    $stable = Join-Path $InstallRoot "bootstrap-wsl.ps1"
    if ($PSCommandPath -ne $stable) { return $false }   # only self-update the installed copy
    if ($env:POINTY_BOOTSTRAP_PROMOTED -eq "1") { return $false }

    $guestPath = "${GuestDir}/wsl/bootstrap-wsl.ps1"
    $r = Invoke-Guest "test -f '${guestPath}' && sha256sum '${guestPath}' | cut -c1-64"
    if ($r.ExitCode -ne 0) { return $false }
    $guestHash = ($r.Output -replace "`0", "").Trim()
    if ($guestHash -notmatch '^[0-9a-f]{64}$') { return $false }

    $localHash = (Get-FileHash -Path $stable -Algorithm SHA256).Hash.ToLower()
    if ($guestHash -eq $localHash) { return $false }

    Write-Log "a newer bootstrap arrived with a release update; promoting it"
    foreach ($name in @("bootstrap-wsl.ps1", "timezone-map.txt")) {
        $win = (Join-Path $InstallRoot $name) -replace '\\', '/'
        $mnt = "/mnt/" + $win.Substring(0,1).ToLower() + $win.Substring(2)
        Invoke-Guest "test -f '${GuestDir}/wsl/${name}' && cp -f '${GuestDir}/wsl/${name}' '${mnt}'" | Out-Null
    }
    return $true
}

function Register-BootTask {
    # ONE task. It boots the distro (systemd then runs the watchdog, the update
    # agent and the stack) and re-points the LAN bridge. Everything else that
    # used to be a Windows scheduled task is now a systemd unit inside Linux.
    $stable = Join-Path $InstallRoot "bootstrap-wsl.ps1"
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument (
        "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$stable`" " +
        "-Boot -Distro `"$Distro`" -InstallRoot `"$InstallRoot`" -ApiPort $ApiPort -WebPort $WebPort")

    $atStartup = New-ScheduledTaskTrigger -AtStartup
    $atStartup.Delay = "PT30S"
    $atStartup.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
        -RepetitionInterval (New-TimeSpan -Minutes 5) `
        -RepetitionDuration (New-TimeSpan -Days 3650)).Repetition

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -MultipleInstances IgnoreNew

    # S4U runs as this user WITHOUT an interactive session and WITHOUT storing a
    # password. That is the whole point of the migration: Docker Desktop could
    # only run inside a logged-in session, which forced shops to enable Windows
    # auto-logon with the password in clear text under Winlogon. This does not.
    #
    # The distro is registered to THIS user's SID, so the task must run as this
    # user - not SYSTEM, which cannot see it.
    $userId = "$env:USERDOMAIN\$env:USERNAME"
    try {
        $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType S4U -RunLevel Highest
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $atStartup `
            -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
        Write-Log "registered scheduled task '${TaskName}' as ${userId} (LogonType=S4U)"
    } catch {
        # We deliberately do NOT prompt for the password and store it ourselves.
        # Task Scheduler asks for it in its own secure dialog and keeps it in the
        # protected credential store; routing it through this script would put
        # the shop's password in a PowerShell variable for no benefit.
        Write-Log "could not register '${TaskName}' automatically: $($_.Exception.Message)" "ERROR"
        Die ("Create the task by hand in Task Scheduler (taskschd.msc):`n" +
             "  Name    : ${TaskName}`n" +
             "  Run as  : ${userId}   <- must be THIS user; WSL distros are per-user`n" +
             "            tick 'Run whether user is logged on or not'`n" +
             "            tick 'Run with highest privileges'`n" +
             "  Trigger : At startup, delay 30s, repeat every 5 minutes indefinitely`n" +
             "  Action  : powershell.exe`n" +
             "  Args    : -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$stable`" -Boot")
    }
}


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if ($Boot) {
    if (-not (Test-DistroExists)) {
        Die "distro '$Distro' is not registered - run this script without -Boot to install."
    }
    # Start the distro first: the promotion check has to read a file inside it.
    $ping = Invoke-Guest "true"
    if ($ping.ExitCode -ne 0) { Die "could not start distro '$Distro': $($ping.Output)" }

    if (Update-BootstrapFromGuest) {
        $env:POINTY_BOOTSTRAP_PROMOTED = "1"
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $InstallRoot "bootstrap-wsl.ps1") `
            -Boot -Distro $Distro -InstallRoot $InstallRoot -ApiPort $ApiPort -WebPort $WebPort
        exit $LASTEXITCODE
    }
    Invoke-BootReconcile
    exit 0
}

Write-Log "=== Pointy on-prem WSL bootstrap ==="
Assert-Preflight
Enable-WindowsFeatures
Install-Wsl
Write-WslConfig
Import-Distro
Set-GuestTimezone
Copy-BundleIntoGuest
Invoke-GuestInstall
Install-BootstrapToStablePath
Register-BootTask
Invoke-BootReconcile

$ip = Get-WslIp
$lan = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" -and
                   $_.InterfaceAlias -notlike "*WSL*" -and $_.InterfaceAlias -notlike "*Hyper-V*" } |
    Select-Object -First 1).IPAddress

Write-Log ""
Write-Log "Done. The stack runs inside WSL distro '${Distro}' (VM address ${ip})."
Write-Log ""
Write-Log "  Tills reach it at : http://${lan}:${ApiPort}"
Write-Log "  Browser app       : http://${lan}:${WebPort}"
Write-Log "  Shell in          : wsl -d ${Distro} -u root --cd ${GuestDir}"
Write-Log "  Stack status      : wsl -d ${Distro} -u root --cd ${GuestDir} -- docker compose ps"
Write-Log "  Watchdog log      : wsl -d ${Distro} -u root -- journalctl -u pointy-watchdog -f"
Write-Log ""
Write-Log "Everything from here on is Linux. There is no second set of Windows scripts:"
Write-Log "updates, healing and the watchdog all run as systemd units inside the distro."
