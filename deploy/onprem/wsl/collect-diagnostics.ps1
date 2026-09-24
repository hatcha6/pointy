<#
  Pointy on-prem - diagnostics for a Windows (WSL) server.

  "The stack did not come back after a restart" and "the stack keeps going
  down" leave their evidence in five places: Task Scheduler, the Windows event
  logs, WSL itself, systemd inside the distro, and Docker. Much of it is gone
  after the next restart. This gathers all of it into ONE zip on the Desktop,
  to carry to the developers.

      # Elevated PowerShell, logged in as the Windows user that installed Pointy:
      powershell -ExecutionPolicy Bypass -File .\collect-diagnostics.ps1

      # The same, and keep recording so the NEXT outage leaves a trail:
      powershell -ExecutionPolicy Bypass -File .\collect-diagnostics.ps1 -Arm

      # Stop recording once the cause is known:
      powershell -ExecutionPolicy Bypass -File .\collect-diagnostics.ps1 -Disarm

  Run it while the stack is DOWN if you can, before anyone brings it back by
  hand: it writes down the state it found before it touches anything. Reading
  the Linux side then starts the distro if it was stopped.

  Nothing in the zip is a credential. .env values that look like one are
  masked, container environments (they hold the database password) are never
  dumped, and every Linux log passes through the same mask.

  -Arm changes three things, none of which touches the running stack:
    * turns on Task Scheduler's own history (Windows ships it switched off),
    * makes the distro's systemd journal survive a restart (capped at 256 MB),
    * registers PointyProbe, a task that appends one line a minute to
      %ProgramData%\Pointy\logs\probe.csv: is the distro running, is the WSL
      VM up, does the stack answer, when did PointyWSL last run. It only asks
      WSL for a list; it never starts the distro.
#>
[CmdletBinding()]
param(
    # Keep recording after the snapshot (see above).
    [switch]$Arm,
    # Remove the PointyProbe task and stop. probe.csv is kept.
    [switch]$Disarm,
    [string]$Distro = "Pointy",
    [string]$InstallRoot = (Join-Path $env:ProgramData "Pointy"),
    # How far back to read the event logs and the container logs.
    [ValidateRange(1, 60)][int]$Days = 7
)

# A diagnostic that stops half way loses the one clue that mattered, so no
# error is terminating here: every section catches its own.
$ErrorActionPreference = "Continue"

# wsl.exe prints UTF-16LE unless told otherwise; see bootstrap-wsl.ps1.
$env:WSL_UTF8 = "1"

# These files are read by a person on another machine and parsed by this
# script: dates and numbers in one format whatever the shop's regional
# settings (an Arabic locale can even switch the calendar).
[System.Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture

$TaskName    = "PointyWSL"
$ProbeTask   = "PointyProbe"
$ProbeScript = Join-Path $InstallRoot "pointy-probe.ps1"
$ProbeLog    = Join-Path $InstallRoot "logs\probe.csv"
$BootLog     = Join-Path $InstallRoot "logs\bootstrap.log"
$DiagDir     = Join-Path $InstallRoot "diagnostics"
$Since       = (Get-Date).AddDays(-$Days)
$Name        = "pointy-diag-{0}-{1}" -f $env:COMPUTERNAME, (Get-Date -Format "yyyyMMdd-HHmmss")
$Work        = Join-Path $DiagDir $Name
$Findings    = New-Object System.Collections.ArrayList


# ---------------------------------------------------------------------------
# The Linux half. Written into the zip's folder and run inside the distro as
# root, so the command never crosses PowerShell -> wsl.exe -> bash quoting.
# ---------------------------------------------------------------------------
$GuestSource = @'
#!/usr/bin/env bash
# The Linux half of collect-diagnostics.ps1, run inside the distro as root.
#
#   bash linux-collect.sh collect <out-dir> <days>   read everything, change nothing
#   bash linux-collect.sh arm                        make the journal persistent
set -u
MODE="${1:-collect}"
DEPLOY=/opt/pointy

# Credentials never leave the machine: URL passwords and anything that reads
# like "password=...", "token: ..." are masked in every file written here.
redact() {
  sed -E \
    -e 's#([a-zA-Z][a-zA-Z0-9+.-]*://[^:/@[:space:]]+:)[^@[:space:]]+@#\1***@#g' \
    -e 's#((password|passwd|secret|token|api_?key|private_?key|signing_?key|credential)[a-z_]*"?[[:space:]]*[=:][[:space:]]*)[^[:space:],&]+#\1***#Ig' \
    -e 's#\b(bearer|basic)[[:space:]]+[A-Za-z0-9._~+/=-]{8,}#\1 ***#Ig'
}

# .env with every credential masked. Database URLs keep their host, which is
# what a diagnosis needs (pgbouncer or postgres?), and lose their password.
redact_env() {
  local line key value upper
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) printf '%s\n' "$line"; continue ;; esac
    key="${line%%=*}"; value="${line#*=}"
    if [ "$key" = "$line" ]; then printf '%s\n' "$line"; continue; fi
    upper="$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')"
    case "$upper" in
      *_URL|*_URI|*DSN*)
        value="$(printf '%s' "$value" | sed -E -e 's#(://[^:/@]+:)[^@]*@#\1***@#' \
          -e 's#([?&][A-Za-z_]*(key|token|secret|password|sig)[A-Za-z_]*=)[^&]*#\1***#Ig')" ;;
      *PASSWORD*|*PASSWD*|*SECRET*|*TOKEN*|*_KEY|*_KEY_*|*APIKEY*|*CRED*|*PRIVATE*|*SALT*|*_PIN|*_PIN_*|*OTP*|*COOKIE*|*SIGNING*|*_AUTH*|*CERT*)
        if [ -n "$value" ]; then value="***(set, ${#value} chars)"; else value="(empty)"; fi ;;
    esac
    printf '%s=%s\n' "$key" "$value"
  done
}

# run <file> <seconds> <command...>: one command, under a timeout (a wedged
# Docker daemon answers nothing, and this must still finish), masked.
run() {
  local file="$1" secs="$2"; shift 2
  mkdir -p "$(dirname "$OUT/$file")"
  {
    printf '$ %s\n' "$*"
    timeout "$secs" "$@" 2>&1 | redact
    printf '[exit %s]\n\n' "${PIPESTATUS[0]}"
  } >>"$OUT/$file"
}

arm() {
  # Say "persistent" explicitly rather than rely on /var/log/journal happening
  # to exist: otherwise the journal lives in /run and every restart erases the
  # only record of why the previous boot ended.
  mkdir -p /etc/systemd/journald.conf.d /var/log/journal
  printf '[Journal]\nStorage=persistent\nSystemMaxUse=256M\n' \
    >/etc/systemd/journald.conf.d/50-pointy-diagnostics.conf
  # A distro imported from a container image can boot with a transient
  # machine-id, which files each boot's journal where the next boot never
  # looks. Commit it.
  if [ ! -s /etc/machine-id ] || findmnt -rn /etc/machine-id >/dev/null 2>&1; then
    systemd-machine-id-setup --commit >/dev/null 2>&1 || systemd-machine-id-setup >/dev/null 2>&1 || true
  fi
  systemd-tmpfiles --create --prefix /var/log/journal >/dev/null 2>&1 || true
  systemctl restart systemd-journald >/dev/null 2>&1 || true
  journalctl --flush >/dev/null 2>&1 || true
  if find /var/log/journal -name '*.journal' 2>/dev/null | grep -q .; then
    echo "journal: persistent (/var/log/journal, capped at 256M)"
  else
    echo "journal: could NOT be made persistent"
    return 1
  fi
}

summary() {
  local up total=0 running=0 down="" limits_mb=0 name status exitcode oom mem
  up="$(cut -d. -f1 /proc/uptime)"
  echo "collected_at=$(date -Is)"
  echo "vm_boot=$(uptime -s 2>/dev/null)"
  echo "vm_uptime_min=$(( up / 60 ))"
  echo "pid1=$(ps -p 1 -o comm= 2>/dev/null)"
  echo "systemd_state=$(systemctl is-system-running 2>/dev/null)"
  echo "failed_units=$(systemctl --failed --plain --no-legend 2>/dev/null | awk '{print $1}' | paste -sd, -)"
  echo "docker_active=$(systemctl is-active docker 2>/dev/null)"
  echo "docker_restarts=$(systemctl show docker -p NRestarts --value 2>/dev/null)"
  echo "watchdog_timer=$(systemctl is-active pointy-watchdog.timer 2>/dev/null)"
  while IFS='|' read -r name status exitcode oom mem; do
    [ -n "$name" ] || continue
    total=$((total + 1))
    if [ "$status" = "running" ]; then
      running=$((running + 1))
    else
      down="${down}${name#/}:${status}:exit=${exitcode}:oom=${oom};"
    fi
    limits_mb=$((limits_mb + ${mem:-0} / 1048576))
  done < <(timeout 30 docker ps -aq 2>/dev/null | xargs -r timeout 30 docker inspect \
      --format '{{.Name}}|{{.State.Status}}|{{.State.ExitCode}}|{{.State.OOMKilled}}|{{.HostConfig.Memory}}' 2>/dev/null)
  echo "containers_total=${total}"
  echo "containers_running=${running}"
  echo "containers_down=${down}"
  echo "mem_limits_total_mb=${limits_mb}"
  echo "mem_total_mb=$(free -m | awk '/^Mem:/{print $2}')"
  echo "mem_available_mb=$(free -m | awk '/^Mem:/{print $7}')"
  echo "swap_used_mb=$(free -m | awk '/^Swap:/{print $3}')"
  echo "oom_kills=$(grep -ciE 'killed process|oom-kill' "$OUT/kernel-alerts.txt" 2>/dev/null || true)"
  echo "journal_boots=$(journalctl --list-boots --no-pager 2>/dev/null | grep -cE '^ *-?[0-9]+ ' || true)"
  # How long each boot lasted, oldest first, in minutes. WSL stops a distro
  # ~15 s after its last Windows-side client exits, whatever systemd is
  # running, and that leaves a trail of boots a minute or two long.
  local lengths first last s e b tail_text endings=""
  lengths="$(journalctl --list-boots --no-pager 2>/dev/null \
    | awk 'NR > 1 && NF >= 10 { print $4" "$5" "$6"|"$8" "$9" "$10 }' \
    | while IFS='|' read -r first last; do
        s="$(date -d "$first" +%s 2>/dev/null)" && e="$(date -d "$last" +%s 2>/dev/null)" && echo $(( (e - s) / 60 ))
      done)"
  echo "journal_boot_minutes_last20=$(printf '%s\n' "$lengths" | grep . | tail -n 20 | paste -sd' ' -)"
  echo "journal_boots_under_5min=$(printf '%s\n' "$lengths" | grep -cE '^[0-4]$' || true)"
  # How the last five boots ended: WSL asking systemd to power off, or cut off.
  for b in -1 -2 -3 -4 -5; do
    tail_text="$(journalctl -b "$b" -n 15 --no-pager 2>/dev/null)" || continue
    [ -n "$tail_text" ] || continue
    if printf '%s' "$tail_text" | grep -qiE 'powering down|power-off|systemd-shutdown|reached target.*(shutdown|power)|journal stopped'; then
      endings="${endings}poweroff "
    else
      endings="${endings}cut-off "
    fi
  done
  echo "journal_boot_endings=${endings% }"
  if find /var/log/journal -name '*.journal' 2>/dev/null | grep -q .; then
    echo "journal_persistent=yes"
  else
    echo "journal_persistent=no"
  fi
  if [ -f "$DEPLOY/.update.lock" ]; then
    echo "update_lock_age_s=$(( $(date +%s) - $(stat -c %Y "$DEPLOY/.update.lock") ))"
  else
    echo "update_lock_age_s="
  fi
  echo "version=$(tr -d '[:space:]' <"$DEPLOY/VERSION.txt" 2>/dev/null)"
}

collect() {
  mkdir -p "$OUT"
  cd "$DEPLOY" 2>/dev/null || echo "no ${DEPLOY} in this distro" >"$OUT/ERROR-no-deploy-dir.txt"

  echo "linux: machine"
  run system.txt 10 date -Is
  run system.txt 10 uptime -s
  run system.txt 10 cat /proc/uptime
  run system.txt 10 uname -a
  run system.txt 10 cat /etc/os-release
  run system.txt 10 ps -p 1 -o comm=
  run system.txt 10 systemctl is-system-running
  run system.txt 30 systemd-analyze
  run system.txt 30 bash -c 'systemd-analyze blame | head -25'
  run system.txt 10 cat /etc/wsl.conf
  run system.txt 10 cat /etc/docker/daemon.json
  run system.txt 10 cat /etc/timezone
  run system.txt 10 cat /etc/machine-id
  run system.txt 10 ip -4 -o addr show
  run system.txt 10 ss -ltnp
  run system.txt 10 df -h
  run system.txt 10 df -i

  echo "linux: memory"
  run memory.txt 10 free -m
  run memory.txt 10 swapon --show
  run memory.txt 10 cat /proc/pressure/memory /proc/pressure/cpu /proc/pressure/io
  run memory.txt 10 bash -c 'ps -eo pid,ppid,rss,etimes,comm,args --sort=-rss | head -30'
  run memory.txt 60 docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.PIDs}}'
  run memory.txt 10 cat /proc/meminfo

  echo "linux: systemd"
  run systemd.txt 10 systemctl --failed --no-pager
  run systemd.txt 10 systemctl list-timers --all --no-pager
  run systemd.txt 30 systemctl status docker.service docker.socket containerd.service \
    pointy-watchdog.timer pointy-watchdog.service pointy-update-agent.timer \
    pointy-update-agent.service pointy-discovery.service --no-pager -l -n 30
  run systemd.txt 10 systemctl show docker.service containerd.service \
    -p Id,ActiveState,SubState,Result,NRestarts,ActiveEnterTimestamp,InactiveEnterTimestamp,ExecMainStartTimestamp,ExecMainExitTimestamp,ExecMainStatus

  echo "linux: journal"
  run journal-boots.txt 30 journalctl --list-boots --no-pager
  run journal-boots.txt 10 journalctl --disk-usage
  run journal-boots.txt 10 ls -la /var/log/journal /run/log/journal
  run journal-boots.txt 10 bash -c 'cat /etc/systemd/journald.conf.d/*.conf 2>/dev/null; grep -v "^#" /etc/systemd/journald.conf | grep .'
  # How each earlier boot ENDED: an orderly systemd shutdown, or cut off
  # mid-line because the VM was killed underneath it.
  local b
  for b in -1 -2 -3 -4 -5; do
    run journal-boot-endings.txt 30 journalctl -b "$b" -n 40 -o short-iso --no-pager
  done
  run journal.txt 180 bash -c "journalctl --merge --since '${DAYS} days ago' -o short-iso --no-pager | tail -n 100000"
  run journal-units.txt 120 bash -c "journalctl -u docker -u containerd -u pointy-watchdog -u pointy-update-agent -u pointy-discovery --since '${DAYS} days ago' -o short-iso --no-pager | tail -n 50000"

  echo "linux: kernel"
  run kernel.txt 30 dmesg -T
  run kernel-history.txt 120 bash -c "journalctl -k --merge --since '${DAYS} days ago' -o short-iso --no-pager | tail -n 50000"
  { dmesg -T 2>/dev/null; journalctl -k --merge --since "${DAYS} days ago" -o short-iso --no-pager 2>/dev/null; } \
    | grep -iE 'out of memory|oom-kill|oom_reaper|invoked oom-killer|killed process|hung_task|blocked for more than|segfault|i/o error|ext4-fs (error|warning)|read-only' \
    | sort -u >"$OUT/kernel-alerts.txt"

  echo "linux: docker"
  run docker.txt 30 docker version
  run docker.txt 30 docker info
  run docker.txt 30 docker ps -a --no-trunc --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.CreatedAt}}'
  run docker.txt 60 docker system df
  # State only. A full `docker inspect` includes every container's
  # environment, and that is where the database password lives.
  run containers.txt 30 bash -c 'docker ps -aq | xargs -r docker inspect --format "{{.Name}} | {{.State.Status}} | exit={{.State.ExitCode}} oom={{.State.OOMKilled}} restarts={{.RestartCount}} | started={{.State.StartedAt}} finished={{.State.FinishedAt}} | health={{if .State.Health}}{{.State.Health.Status}} streak={{.State.Health.FailingStreak}}{{else}}none{{end}} | restart={{.HostConfig.RestartPolicy.Name}} mem={{.HostConfig.Memory}} | {{.Config.Image}} | error={{.State.Error}}"'
  run healthchecks.txt 30 bash -c 'docker ps -aq | xargs -r docker inspect --format "== {{.Name}}{{if .State.Health}}{{range .State.Health.Log}}{{println}}{{.Start}} rc={{.ExitCode}} {{.Output}}{{end}}{{end}}"'
  # Docker keeps events in memory only, so this reaches back to the daemon's
  # own start at most.
  run docker-events.txt 30 docker events --since "$(date -d "-${DAYS} days" +%s)" --until "$(date +%s)"
  if [ -f docker-compose.yml ] && [ -f .env ]; then
    run compose.txt 60 docker compose --env-file .env -f docker-compose.yml ps -a
  fi
  local container
  for container in $(timeout 30 docker ps -a --format '{{.Names}}' 2>/dev/null); do
    run "logs/${container}.log" 120 docker logs --timestamps --since "$((DAYS * 24))h" --tail 5000 "$container"
  done

  echo "linux: deploy directory"
  run deploy.txt 10 ls -la "$DEPLOY"
  run deploy.txt 10 cat "$DEPLOY/VERSION.txt"
  run deploy.txt 10 bash -c 'if [ -f .update.lock ]; then stat -c "%y (%s bytes)" .update.lock; cat .update.lock; else echo "no .update.lock"; fi'
  run deploy.txt 10 cat "$DEPLOY/edge/active/upstream.conf"
  run deploy.txt 10 bash -c 'sha256sum wsl/*.ps1'
  if [ -f "$DEPLOY/.env" ]; then redact_env <"$DEPLOY/.env" >"$OUT/env-redacted.txt"; fi
  run shell-history.txt 10 tail -n 300 /root/.bash_history

  summary >"$OUT/summary.txt"
  echo "linux: done"
}

case "$MODE" in
  arm) arm ;;
  collect) OUT="${2:?usage: collect <out-dir> <days>}"; DAYS="${3:-7}"; collect ;;
  *) echo "usage: $0 collect <out-dir> <days> | arm" >&2; exit 2 ;;
esac
'@


# ---------------------------------------------------------------------------
# The probe -Arm installs. Once a minute, one CSV row; see the header.
# ---------------------------------------------------------------------------
$ProbeSource = @'
# Pointy probe - written by collect-diagnostics.ps1 -Arm, removed by -Disarm.
# The PointyProbe task runs this once a minute; it appends one row to
# probe.csv. It never starts the distro: `wsl --list` only asks WSL what
# exists and what runs, and the HTTP checks go through the LAN forward
# exactly as a till's requests do.
param([string]$Distro = "Pointy", [string]$LogFile = "$env:ProgramData\Pointy\logs\probe.csv")
$ErrorActionPreference = "SilentlyContinue"
$env:WSL_UTF8 = "1"

function Get-WslNames([string[]]$Arguments) {
    $text = (& wsl.exe @Arguments 2>&1 | ForEach-Object { "$_" }) -join "`n"
    return @(($text -replace "`0", "") -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-Http([string]$Url) {
    $response = $null
    try {
        $request = [System.Net.WebRequest]::Create($Url)
        $request.Proxy = $null
        $request.Timeout = 3000
        $response = $request.GetResponse()
        return "$([int]$response.StatusCode)"
    } catch {
        $ex = $_.Exception
        while ($ex -and -not ($ex -is [System.Net.WebException])) { $ex = $ex.InnerException }
        if ($ex -and $ex.Response) { return "$([int]$ex.Response.StatusCode)" }
        return "down"
    } finally {
        if ($response) { $response.Close() }
    }
}

function Get-Clean([string]$Text) { return (($Text -replace '[,"\r\n]', ' ') -replace '\s+', ' ').Trim() }

$distroState = "unknown"
try {
    $names = @(Get-WslNames @("--list", "--quiet"))
    if ($names -contains $Distro) {
        $distroState = "stopped"
        if (@(Get-WslNames @("--list", "--running", "--quiet")) -contains $Distro) { $distroState = "running" }
    } else {
        # Not listed for this user: a wsl.exe error says why (the S4U session
        # could not reach WSL at all, say), so keep its first line.
        $first = ""
        if ($names.Count) { $first = $names[0] }
        $distroState = "not-visible: " + (Get-Clean $first)
        if ($distroState.Length -gt 90) { $distroState = $distroState.Substring(0, 90) }
    }
} catch { }

$vmStarted = ""; $vmMb = ""; $clients = @(); $sessions = ""
try {
    $vm = @(Get-CimInstance Win32_Process -Filter "Name='vmmemWSL' OR Name='vmmem'")
    if ($vm.Count) { $vmStarted = $vm[0].CreationDate.ToString("s"); $vmMb = [int]($vm[0].WorkingSetSize / 1MB) }
    $clients = @(Get-CimInstance Win32_Process -Filter "Name='wsl.exe' OR Name='wslhost.exe'")
    $sessions = (@($clients | ForEach-Object { $_.SessionId }) | Sort-Object -Unique) -join " "
} catch { }

$proxy = ""
try {
    foreach ($line in ((& netsh.exe interface portproxy show v4tov4 2>$null) -split "`r?`n")) {
        if ($line -match '^\s*\S+\s+8000\s+(\S+)\s+\d+\s*$') { $proxy = $Matches[1] }
    }
} catch { }

$taskState = ""; $taskRun = ""; $taskResult = ""
try {
    $task = Get-ScheduledTask -TaskName "PointyWSL"
    $taskState = "$($task.State)"
    $info = $task | Get-ScheduledTaskInfo
    $taskRun = $info.LastRunTime.ToString("s")
    $taskResult = "0x{0:X}" -f $info.LastTaskResult
} catch { }

$boot = ""; $freeMb = ""; $console = ""
try {
    $os = Get-CimInstance Win32_OperatingSystem
    $boot = $os.LastBootUpTime.ToString("s")
    $freeMb = [int]($os.FreePhysicalMemory / 1KB)
    $console = Get-Clean "$((Get-CimInstance Win32_ComputerSystem).UserName)"
} catch { }

$row = @(
    (Get-Date).ToString("s"), $boot, $distroState, $vmStarted, $vmMb, $clients.Count, $sessions,
    (Get-Http "http://127.0.0.1:8000/healthz-edge"), (Get-Http "http://127.0.0.1:8000/readyz/"),
    $proxy, $taskState, $taskRun, $taskResult, $console, $freeMb
) -join ","

$dir = Split-Path -Parent $LogFile
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt 10MB)) {
    Move-Item -Force $LogFile ($LogFile -replace '\.csv$', '.1.csv')
}
if (-not (Test-Path $LogFile)) {
    Set-Content -Path $LogFile -Encoding UTF8 -Value ("time,windows_boot,distro,vm_started,vm_mb,wsl_clients," +
        "wsl_client_sessions,edge_8000,ready_8000,portproxy_8000,task_state,task_last_run," +
        "task_last_result,console_user,host_free_mb")
}
Add-Content -Path $LogFile -Encoding UTF8 -Value $row
'@


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Step { param([string]$Message) Write-Host ("==> " + $Message) }

function Add-Finding { param([string]$Message) [void]$script:Findings.Add($Message) }

function Test-Admin {
    (New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent())
    ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

# UTF-8 with LF line ends: these files are read on a Mac or a Linux box, and
# the Linux script is executed by bash, which chokes on a CR. -Bom is for a
# .ps1 that Windows PowerShell 5.1 has to read (see bootstrap-wsl.ps1).
function Write-TextFile {
    param([string]$Path, [string]$Text, [switch]$Bom)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($Path, ($Text -replace "`r`n", "`n"),
        (New-Object System.Text.UTF8Encoding([bool]$Bom)))
}

# Run a native command and return everything it printed, never throwing.
# -Utf8 is for wsl.exe, which prints UTF-8 once WSL_UTF8 is set; everything
# else prints in the console codepage and is decoded as such.
function Invoke-Native {
    param([string]$File, [string[]]$Arguments = @(), [switch]$Utf8)
    $previous = $null
    if ($Utf8) {
        try {
            $previous = [Console]::OutputEncoding
            [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        } catch { $previous = $null }
    }
    try {
        $text = (& $File @Arguments 2>&1 | ForEach-Object { "$_" }) -join "`n"
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ("$text" -replace "`0", "") }
    } catch {
        return [pscustomobject]@{ ExitCode = -1; Output = "could not run ${File}: $($_.Exception.Message)" }
    } finally {
        if ($previous) { try { [Console]::OutputEncoding = $previous } catch { } }
    }
}

# One file per section. A section that throws writes why, and the collection
# goes on.
function Save-Section {
    param([string]$Name, [scriptblock]$Body)
    $text = ""
    try { $text = (& $Body 2>&1 | Out-String -Width 300) }
    catch { $text = "SECTION FAILED: $($_.Exception.Message)" }
    Write-TextFile -Path (Join-Path $script:Work $Name) -Text $text
}

function Format-Span {
    param([TimeSpan]$Span)
    if ($Span.TotalMinutes -lt 1) { return "{0}s" -f [int]$Span.TotalSeconds }
    return "{0}d {1}h {2}m" -f $Span.Days, $Span.Hours, $Span.Minutes
}

# C:\ProgramData\x -> /mnt/c/ProgramData/x. Only ever given absolute paths.
function ConvertTo-WslPath {
    param([string]$Path)
    return "/mnt/" + $Path.Substring(0, 1).ToLower() + ($Path.Substring(2) -replace '\\', '/')
}

function Test-SameAccount {
    param([string]$A, [string]$B)
    if (-not $A -or -not $B) { return $false }
    return ((($A -split '\\')[-1]) -ieq (($B -split '\\')[-1]))
}

# Where an account's profile (and so its .wslconfig) really is. Not
# $env:USERPROFILE: the collector may run as someone else, and a task that
# runs without a loaded profile sees a different one.
function Get-ProfilePath {
    param([string]$Account)
    try {
        $sid = (New-Object System.Security.Principal.NTAccount($Account)).Translate(
            [System.Security.Principal.SecurityIdentifier]).Value
        $profileRow = Get-CimInstance Win32_UserProfile -Filter "SID='$sid'" -ErrorAction Stop
        if ($profileRow) { return "$($profileRow.LocalPath)" }
    } catch { }
    return $null
}

# The value .wslconfig gives [Section] Key, or $null. WSL reads a key only in
# its own section: instanceIdleTimeout under [wsl2] does nothing at all.
function Get-WslConfigValue {
    param([string]$Text, [string]$Section, [string]$Key)
    $current = ""
    foreach ($line in ($Text -split "`r?`n")) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^\[(.+)\]$') { $current = $Matches[1].Trim(); continue }
        if ($current -ieq $Section -and $trimmed -match "^$([regex]::Escape($Key))\s*=\s*(.*)$") {
            return ($Matches[1] -replace '\s+#.*$', '').Trim()
        }
    }
    return $null
}

# Does the distro run right now? `wsl --list` asks WSL; unlike every other way
# of looking, it does not start the distro.
function Get-DistroState {
    $listed = Invoke-Native -File "wsl.exe" -Arguments @("--list", "--quiet") -Utf8
    $names = @($listed.Output -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($names -notcontains $Distro) {
        return [pscustomobject]@{ State = "not-visible"; Detail = $listed.Output.Trim() }
    }
    $running = Invoke-Native -File "wsl.exe" -Arguments @("--list", "--running", "--quiet") -Utf8
    $state = "stopped"
    if (@($running.Output -split "`n" | ForEach-Object { $_.Trim() }) -contains $Distro) { $state = "running" }
    return [pscustomobject]@{ State = $state; Detail = "" }
}

# The status a URL answers with ("200", "502"), or "down (why)".
function Get-HttpStatus {
    param([string]$Url, [int]$TimeoutMs = 4000)
    $response = $null
    try {
        $request = [System.Net.WebRequest]::Create($Url)
        $request.Proxy = $null
        $request.Timeout = $TimeoutMs
        $response = $request.GetResponse()
        return "$([int]$response.StatusCode)"
    } catch {
        $ex = $_.Exception
        while ($ex -and -not ($ex -is [System.Net.WebException])) { $ex = $ex.InnerException }
        if ($ex -and $ex.Response) { return "$([int]$ex.Response.StatusCode)" }
        if ($ex) { return "down ($($ex.Status))" }
        return "down ($($_.Exception.Message))"
    } finally {
        if ($response) { $response.Close() }
    }
}

function Get-LanIPv4 {
    try {
        return @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object {
                $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" -and
                "$($_.AddressState)" -eq "Preferred" -and
                $_.InterfaceAlias -notmatch 'WSL|Default Switch|VirtualBox|VMware|Loopback'
            } | Select-Object -ExpandProperty IPAddress)
    } catch { return @() }
}

function Get-WslProcesses {
    $filter = (@("wsl.exe", "wslhost.exe", "wslservice.exe", "wslrelay.exe", "vmmem", "vmmemWSL",
                 "vmcompute.exe", "vmwp.exe", "powershell.exe", "Docker Desktop.exe",
                 "com.docker.backend.exe") | ForEach-Object { "Name='$_'" }) -join " OR "
    return @(Get-CimInstance Win32_Process -Filter $filter -ErrorAction SilentlyContinue)
}

# Task Scheduler's result codes, for the ones a Pointy task actually returns.
function Format-TaskResult {
    param($Code)
    if ($null -eq $Code) { return "n/a" }
    $hex = "0x{0:X}" -f $Code
    $known = @{
        "0x0"        = "success"
        "0x1"        = "the script stopped with an error (bootstrap.log says which)"
        "0x2"        = "exit 2 (a reboot was requested, or a file was not found)"
        "0x41300"    = "ready"
        "0x41301"    = "running right now"
        "0x41303"    = "has never run"
        "0x41306"    = "terminated by a user or by Task Scheduler"
        "0x8004131F" = "skipped: an instance was already running"
        "0x800710E0" = "refused: a start condition was not met"
        "0x80070520" = "a specified logon session does not exist"
        "0x8007052E" = "logon failure: bad user name or password"
        "0x80070569" = "logon failure: the user lacks the logon right this task needs"
        "0x800704DD" = "the user is not logged on to the network"
        "0xC000013A" = "killed (console closed, or Windows shutting down)"
        "0xFFFD0000" = "PowerShell could not open the script file"
    }
    if ($known.ContainsKey($hex)) { return "$hex ($($known[$hex]))" }
    return $hex
}

function Get-TaskReport {
    param([string]$Task)
    $t = Get-ScheduledTask -TaskName $Task -ErrorAction SilentlyContinue
    if (-not $t) { return "task '$Task' is NOT registered" }
    $i = $t | Get-ScheduledTaskInfo
    "Task        : $($t.TaskPath)$($t.TaskName)"
    "State       : $($t.State)"
    "Runs as     : $($t.Principal.UserId)  LogonType=$($t.Principal.LogonType)  RunLevel=$($t.Principal.RunLevel)"
    "Last run    : $($i.LastRunTime)"
    "Last result : $(Format-TaskResult $i.LastTaskResult)"
    "Next run    : $($i.NextRunTime)"
    "Missed runs : $($i.NumberOfMissedRuns)"
    foreach ($tr in @($t.Triggers)) {
        $kind = ("$($tr.CimClass.CimClassName)" -replace '^MSFT_Task', '') -replace 'Trigger$', ''
        "Trigger     : $kind enabled=$($tr.Enabled) delay=$($tr.Delay) start=$($tr.StartBoundary) " +
            "repeat=$($tr.Repetition.Interval) for $($tr.Repetition.Duration)"
    }
    foreach ($a in @($t.Actions)) { "Action      : $($a.Execute) $($a.Arguments)" }
    $s = $t.Settings
    "Settings    : Enabled=$($s.Enabled) StartWhenAvailable=$($s.StartWhenAvailable) " +
        "MultipleInstances=$($s.MultipleInstances) ExecutionTimeLimit=$($s.ExecutionTimeLimit) " +
        "DisallowStartIfOnBatteries=$($s.DisallowStartIfOnBatteries) StopIfGoingOnBatteries=$($s.StopIfGoingOnBatteries) " +
        "RunOnlyIfIdle=$($s.RunOnlyIfIdle) RunOnlyIfNetworkAvailable=$($s.RunOnlyIfNetworkAvailable) WakeToRun=$($s.WakeToRun)"
}

function Get-LevelName {
    param($Level)
    switch ([int]$Level) { 1 { "CRIT" } 2 { "ERROR" } 3 { "WARN" } 5 { "VERB" } default { "INFO" } }
}

function Get-EventRecords {
    param([hashtable]$Filter, [int]$Max = 5000)
    $Filter["StartTime"] = $script:Since
    # Get-WinEvent reports "no events found" as an error; to us it is an answer.
    try { return @(Get-WinEvent -FilterHashtable $Filter -MaxEvents $Max -ErrorAction Stop | Sort-Object TimeCreated) }
    catch { return @() }
}

function Format-EventLine {
    param($Record, [string]$Source)
    $message = ""
    try { $message = "$($Record.Message)" } catch { }
    if (-not $message) {
        $message = "(no message) " + ((@($Record.Properties) | ForEach-Object { "$($_.Value)" }) -join " | ")
    }
    $message = ($message -replace '\s+', ' ').Trim()
    if ($message.Length -gt 400) { $message = $message.Substring(0, 400) + " ..." }
    return "{0:yyyy-MM-dd HH:mm:ss}  {1,-5} [{2}] {3} {4}: {5}" -f $Record.TimeCreated,
        (Get-LevelName $Record.Level), $Source, $Record.ProviderName, $Record.Id, $message
}

# The Linux half, with a hard time limit: a wedged VM must not keep the
# Windows half (already on disk) from reaching the zip.
function Invoke-GuestScript {
    param([string[]]$GuestArgs, [int]$TimeoutSec = 900)
    $wslArgs = @("-d", $Distro, "-u", "root", "--", "bash", $script:GuestScriptMnt) + $GuestArgs
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "wsl.exe"
    $psi.Arguments = ($wslArgs | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join " "
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    try { $p = [System.Diagnostics.Process]::Start($psi) }
    catch { return "could not start wsl.exe: $($_.Exception.Message)" }
    $stdout = $p.StandardOutput.ReadToEndAsync()
    $stderr = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill() } catch { }
        return "TIMED OUT after ${TimeoutSec}s"
    }
    return ("exit {0}`n{1}{2}" -f $p.ExitCode, $stdout.Result, $stderr.Result) -replace "`0", ""
}


# ---------------------------------------------------------------------------
# -Disarm
# ---------------------------------------------------------------------------

if ($Disarm) {
    if (-not (Test-Admin)) { Write-Host "Run this in an ELEVATED (Administrator) PowerShell." -ForegroundColor Red; exit 1 }
    if (Get-ScheduledTask -TaskName $ProbeTask -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $ProbeTask -Confirm:$false
        Write-Host "removed the $ProbeTask task"
    } else {
        Write-Host "$ProbeTask was not registered"
    }
    Remove-Item $ProbeScript -ErrorAction SilentlyContinue
    Write-Host "kept $ProbeLog. Task Scheduler history and the persistent journal stay on; both are harmless."
    exit 0
}


# ---------------------------------------------------------------------------
# Collect
# ---------------------------------------------------------------------------

$isAdmin = Test-Admin
if (-not $isAdmin) {
    if ($Arm) { Write-Host "-Arm needs an ELEVATED (Administrator) PowerShell." -ForegroundColor Red; exit 1 }
    Write-Host "Not elevated: some logs and process details will be missing. Prefer an Administrator PowerShell." -ForegroundColor Yellow
}
New-Item -ItemType Directory -Force -Path $Work | Out-Null
$me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$pointyTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
$owner = $me
if ($pointyTask) { $owner = "$($pointyTask.Principal.UserId)" }
$canGuest = Test-SameAccount $owner $me

# 1. Before anything else: the state the collector FOUND. Everything after
#    this may start the distro, and then the moment is gone.
Write-Step "recording the state before touching anything"
$before = Get-DistroState
$processesBefore = Get-WslProcesses
$vmBefore = @($processesBefore | Where-Object { $_.Name -like "vmmem*" }) | Select-Object -First 1
$clientsBefore = @($processesBefore | Where-Object { $_.Name -in @("wsl.exe", "wslhost.exe") })
$probes = [ordered]@{}
foreach ($url in @("http://127.0.0.1:8000/healthz-edge", "http://127.0.0.1:8000/readyz/", "http://127.0.0.1:80/healthz-web")) {
    $probes[$url] = Get-HttpStatus $url
}
foreach ($ip in @(Get-LanIPv4)) {
    $probes["http://${ip}:8000/healthz-edge"] = Get-HttpStatus "http://${ip}:8000/healthz-edge"
}
Save-Section "00-state-before.txt" {
    "Collected at      : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    "Distro '$Distro'  : $($before.State) $($before.Detail)"
    if ($vmBefore) { "WSL VM            : up since $($vmBefore.CreationDate) ($($vmBefore.Name), $([int]($vmBefore.WorkingSetSize / 1MB)) MB)" }
    else { "WSL VM            : NOT running (no vmmem process)" }
    "wsl.exe clients   : $($clientsBefore.Count) (sessions: $((@($clientsBefore | ForEach-Object { $_.SessionId }) | Sort-Object -Unique) -join ', '))"
    ""
    foreach ($url in $probes.Keys) { "{0,-44} -> {1}" -f $url, $probes[$url] }
}

Write-Step "Windows: machine, power, services, WSL, tasks, network"
# A broken WMI repository is common on old shop PCs; everything below copes
# with these being empty.
$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
$cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
$uptime = [TimeSpan]::Zero
if ($os -and $os.LastBootUpTime) { $uptime = (Get-Date) - $os.LastBootUpTime }
$fastStartup = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -ErrorAction SilentlyContinue).HiberbootEnabled
Save-Section "windows\system.txt" {
    "Computer        : $env:COMPUTERNAME"
    "Windows         : $($os.Caption) $($os.Version) (build $($os.BuildNumber))"
    "Booted          : $($os.LastBootUpTime) (up $(Format-Span $uptime))"
    "Memory          : $([int]($cs.TotalPhysicalMemory / 1MB)) MB total, $([int]($os.FreePhysicalMemory / 1KB)) MB free"
    "Commit          : $([int](($os.TotalVirtualMemorySize - $os.FreeVirtualMemory) / 1KB)) of $([int]($os.TotalVirtualMemorySize / 1KB)) MB in use"
    "CPU             : $((Get-CimInstance Win32_Processor | Select-Object -First 1).Name), $([Environment]::ProcessorCount) logical"
    "Hypervisor      : present=$($cs.HypervisorPresent)"
    "Time zone       : $((Get-TimeZone).Id)"
    "Console user    : $($cs.UserName)"
    "Collector user  : $me (admin: $isAdmin)"
    "Distro owner    : $owner (from the $TaskName task)"
    ""
    "## logged-on sessions"
    (Invoke-Native "quser.exe").Output
    ""
    "## execution policy"
    Get-ExecutionPolicy -List | Format-Table -AutoSize
    "## hypervisor launch (bcdedit)"
    (Invoke-Native "bcdedit.exe" @("/enum", "{current}")).Output
}
Save-Section "windows\power.txt" {
    "Fast Startup (HiberbootEnabled): $fastStartup"
    ""
    "## powercfg /a"
    (Invoke-Native "powercfg.exe" @("/a")).Output
    "## sleep settings of the active plan (values are seconds, AC then DC)"
    (Invoke-Native "powercfg.exe" @("/q", "SCHEME_CURRENT", "SUB_SLEEP")).Output
    "## powercfg /requests"
    (Invoke-Native "powercfg.exe" @("/requests")).Output
    "## powercfg /lastwake"
    (Invoke-Native "powercfg.exe" @("/lastwake")).Output
}
Save-Section "windows\services.txt" {
    Get-Service -Name WSLService, LxssManager, vmcompute, vmms, hns, iphlpsvc, Schedule, com.docker.service, wuauserv, UsoSvc -ErrorAction SilentlyContinue |
        Select-Object Name, DisplayName, Status, StartType | Format-Table -AutoSize
    "Docker Desktop installed: $(Test-Path (Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'))"
}
Save-Section "windows\processes.txt" {
    $processesBefore | Sort-Object CreationDate |
        Select-Object ProcessId, ParentProcessId, Name, SessionId, CreationDate,
            @{ n = "MB"; e = { [int]($_.WorkingSetSize / 1MB) } }, CommandLine |
        Format-Table -AutoSize -Wrap
}
$ownerProfile = Get-ProfilePath $owner
Save-Section "windows\wsl.txt" {
    "## wsl --version"
    (Invoke-Native "wsl.exe" @("--version") -Utf8).Output
    "## wsl --status"
    (Invoke-Native "wsl.exe" @("--status") -Utf8).Output
    "## wsl --list --verbose (as $me)"
    (Invoke-Native "wsl.exe" @("--list", "--verbose") -Utf8).Output
    # From a session-0 task, System32\wsl.exe has been seen to fail with
    # "Access is denied" where the Program Files copy works (microsoft/WSL#9231).
    "## which wsl.exe"
    (@(Get-Command wsl.exe -All -ErrorAction SilentlyContinue) | ForEach-Object { $_.Source }) -join "`n"
    "Program Files copy present: $(Test-Path (Join-Path $env:ProgramFiles 'WSL\wsl.exe'))"
    ""
    # The one WSL reads is the owner's. The others only exist if a task ran
    # without the owner's profile loaded and wrote its config somewhere WSL
    # never looks.
    $candidates = @()
    if ($ownerProfile) { $candidates += (Join-Path $ownerProfile ".wslconfig") }
    $candidates += @((Join-Path $env:USERPROFILE ".wslconfig"),
                     (Join-Path $env:SystemRoot "System32\config\systemprofile\.wslconfig"),
                     (Join-Path $env:SystemDrive "Users\Default\.wslconfig"))
    foreach ($path in ($candidates | Select-Object -Unique)) {
        if (Test-Path $path) {
            "## $path (modified $((Get-Item $path).LastWriteTime))"
            Get-Content -Raw $path
        } else {
            "## $path : absent"
        }
    }
    "## distro disk"
    Get-ChildItem -Force (Join-Path $InstallRoot "distro") -ErrorAction SilentlyContinue |
        Select-Object Name, @{ n = "GB"; e = { [math]::Round($_.Length / 1GB, 2) } }, LastWriteTime | Format-Table -AutoSize
    "## free space"
    Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" |
        Select-Object DeviceID, @{ n = "FreeGB"; e = { [math]::Round($_.FreeSpace / 1GB, 1) } },
            @{ n = "SizeGB"; e = { [math]::Round($_.Size / 1GB, 1) } } | Format-Table -AutoSize
}
Save-Section "windows\tasks.txt" {
    Get-TaskReport $TaskName
    ""
    Get-TaskReport $ProbeTask
    ""
    "## every scheduled task that mentions Pointy, WSL or Docker"
    Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        $actions = (@($_.Actions) | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join " "
        ("$($_.TaskName) $actions") -match 'pointy|wsl|docker'
    } | ForEach-Object {
        "{0}{1}  state={2}  runs-as={3} ({4})" -f $_.TaskPath, $_.TaskName, $_.State, $_.Principal.UserId, $_.Principal.LogonType
    }
    ""
    "## Task Scheduler history log"
    (Invoke-Native "wevtutil.exe" @("gl", "Microsoft-Windows-TaskScheduler/Operational")).Output
}
foreach ($task in @($TaskName, $ProbeTask)) {
    try {
        $xml = Export-ScheduledTask -TaskName $task -ErrorAction Stop
        Write-TextFile -Path (Join-Path $Work "windows\task-$task.xml") -Text $xml
    } catch { }
}
Save-Section "windows\network.txt" {
    "## portproxy (the LAN bridge)"
    (Invoke-Native "netsh.exe" @("interface", "portproxy", "show", "v4tov4")).Output
    "## listeners on the Pointy ports"
    foreach ($port in @(8000, 80)) {
        Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue |
            Select-Object LocalAddress, LocalPort, OwningProcess,
                @{ n = "Process"; e = { (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName } } |
            Format-Table -AutoSize
    }
    "## IPv4 addresses"
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Select-Object InterfaceAlias, IPAddress, PrefixLength, AddressState | Format-Table -AutoSize
    "## adapters"
    Get-NetAdapter -ErrorAction SilentlyContinue | Select-Object Name, InterfaceDescription, Status, LinkSpeed | Format-Table -AutoSize
    "## firewall"
    Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction SilentlyContinue |
        Select-Object Name, Enabled, DefaultInboundAction, AllowLocalFirewallRules | Format-Table -AutoSize
    Get-NetFirewallRule -DisplayName "Pointy*" -ErrorAction SilentlyContinue |
        Select-Object DisplayName, Enabled, Direction, Action, Profile | Format-Table -AutoSize
    "## security products"
    Get-CimInstance -Namespace "root/SecurityCenter2" -ClassName AntiVirusProduct -ErrorAction SilentlyContinue |
        Select-Object displayName, productState | Format-Table -AutoSize
}
Save-Section "windows\updates.txt" {
    "Windows Update history, newest first. result: 2=ok 3=ok-with-errors 4=failed 5=aborted. Times are UTC."
    try {
        $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
        $count = $searcher.GetTotalHistoryCount()
        if ($count -gt 0) {
            $searcher.QueryHistory(0, [math]::Min($count, 100)) | ForEach-Object {
                "{0:yyyy-MM-dd HH:mm}  result={1}  {2}" -f $_.Date, $_.ResultCode, $_.Title
            }
        }
    } catch { "unavailable: $($_.Exception.Message)" }
}


Write-Step "Windows event logs, last $Days days (this can take a minute)"
$timeline = New-Object System.Collections.ArrayList
function Add-Timeline {
    param([datetime]$Time, [string]$Line)
    [void]$script:timeline.Add([pscustomobject]@{ Time = $Time; Line = $Line })
}
# The events that tell a boot, shutdown, sleep, power cut or update apart.
$keyEvents = @{
    "Microsoft-Windows-Kernel-General"               = @(12, 13)
    "Microsoft-Windows-Kernel-Boot"                  = @(27)
    "Microsoft-Windows-Kernel-Power"                 = @(41, 42, 107, 109, 506, 507)
    "Microsoft-Windows-Power-Troubleshooter"         = @(1)
    "EventLog"                                       = @(6005, 6006, 6008)
    "User32"                                         = @(1074, 1076)
    "Microsoft-Windows-WindowsUpdateClient"          = @(19, 20, 43)
    "Microsoft-Windows-Resource-Exhaustion-Detector" = @(2004)
    "Service Control Manager"                        = @(7000, 7009, 7011, 7023, 7024, 7031, 7034)
    "Microsoft-Windows-WER-SystemErrorReporting"     = @(1001)
    # A sign-out ends the WSL session of whoever called WSL first after boot.
    "Microsoft-Windows-Winlogon"                     = @(7001, 7002)
}
$wslServices = 'WSL|Linux|Lxss|Hyper-V|Host Compute|IP Helper|Docker'

$systemEvents = Get-EventRecords @{ LogName = "System" } 20000
Write-TextFile -Path (Join-Path $Work "events\system.txt") -Text (($systemEvents | ForEach-Object { Format-EventLine $_ "System" }) -join "`n")
foreach ($e in $systemEvents) {
    $ids = $keyEvents[$e.ProviderName]
    $isKey = $ids -and ($ids -contains $e.Id)
    $isWslService = ($e.ProviderName -eq "Service Control Manager") -and ($e.Id -in @(7036, 7040)) -and ("$($e.Message)" -match $wslServices)
    $isHyperV = ($e.ProviderName -like "*Hyper-V*") -and ($e.Level -in @(1, 2, 3))
    if ($isKey -or $isWslService -or $isHyperV) { Add-Timeline $e.TimeCreated (Format-EventLine $e "System") }
}

$appEvents = Get-EventRecords @{ LogName = "Application"; Level = @(1, 2, 3) } 5000
Write-TextFile -Path (Join-Path $Work "events\application-problems.txt") -Text (($appEvents | ForEach-Object { Format-EventLine $_ "App" }) -join "`n")
foreach ($e in $appEvents) {
    if ("$($e.ProviderName) $($e.Message)" -match 'wsl|lxss|vmmem|vmcompute|vmwp|docker|pointy|powershell') {
        Add-Timeline $e.TimeCreated (Format-EventLine $e "App")
    }
}

# The WSL package itself: an MSI install, or the Store updating it in place.
$wslPackage = @(Get-EventRecords @{ LogName = "Application"; ProviderName = "MsiInstaller" } 2000) +
              @(Get-EventRecords @{ LogName = "Microsoft-Windows-AppXDeploymentServer/Operational" } 5000) |
    Where-Object { "$($_.Message)" -match 'Subsystem for Linux|WindowsSubsystemForLinux|Microsoft\.WSL' }
Write-TextFile -Path (Join-Path $Work "events\wsl-package.txt") -Text ((@($wslPackage) | ForEach-Object { Format-EventLine $_ "WslPkg" }) -join "`n")
foreach ($e in @($wslPackage)) { Add-Timeline $e.TimeCreated (Format-EventLine $e "WslPkg") }

# The WSL VM is a Hyper-V compute system: these channels are its start/stop record.
$hyperV = @()
foreach ($channel in @("Microsoft-Windows-Hyper-V-Compute-Operational", "Microsoft-Windows-Hyper-V-Compute-Admin",
                       "Microsoft-Windows-Hyper-V-Worker-Admin")) {
    $hyperV += @(Get-EventRecords @{ LogName = $channel } 5000)
}
$hyperV = @($hyperV | Sort-Object TimeCreated)
Write-TextFile -Path (Join-Path $Work "events\hyper-v.txt") -Text (($hyperV | ForEach-Object { Format-EventLine $_ "HyperV" }) -join "`n")
foreach ($e in $hyperV) { Add-Timeline $e.TimeCreated (Format-EventLine $e "HyperV") }

# PointyWSL's own history - only there if Task Scheduler history is on.
$taskEvents = @()
$ms = [int64]$Days * 86400000
try {
    $taskEvents = @(Get-WinEvent -LogName "Microsoft-Windows-TaskScheduler/Operational" -ErrorAction Stop -FilterXPath (
        "*[System[TimeCreated[timediff(@SystemTime) <= $ms]] and EventData[Data[@Name='TaskName']='\$TaskName' " +
        "or Data[@Name='TaskName']='\$ProbeTask']]") | Sort-Object TimeCreated)
} catch { }
Write-TextFile -Path (Join-Path $Work "events\task-scheduler.txt") -Text (($taskEvents | ForEach-Object { Format-EventLine $_ "Task" }) -join "`n")
foreach ($e in $taskEvents) { Add-Timeline $e.TimeCreated (Format-EventLine $e "Task") }


Write-Step "Pointy's own Windows-side logs"
$pointyDir = Join-Path $Work "pointy"
New-Item -ItemType Directory -Force -Path $pointyDir | Out-Null
foreach ($file in @($BootLog, (Join-Path $InstallRoot "bridge-state.json"), $ProbeLog,
                    ($ProbeLog -replace '\.csv$', '.1.csv'), (Join-Path $InstallRoot "bootstrap-wsl.ps1"))) {
    if (Test-Path $file) { Copy-Item -Force $file $pointyDir -ErrorAction SilentlyContinue }
}
Save-Section "pointy\install-root.txt" {
    Get-ChildItem -Force -Recurse -Depth 1 $InstallRoot -ErrorAction SilentlyContinue |
        Select-Object FullName, Length, LastWriteTime | Format-Table -AutoSize
}

# bootstrap.log is the task's diary: one "-Boot" run every 5 minutes. A gap
# is a stretch in which the task did not run at all.
$bootRuns = New-Object System.Collections.ArrayList
$bootNotAnswering = 0
$bootErrors = New-Object System.Collections.ArrayList
if (Test-Path $BootLog) {
    foreach ($line in [System.IO.File]::ReadAllLines($BootLog)) {
        if ($line -notmatch '^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}) \[pointy-wsl\] (\w+) (.*)$') { continue }
        $time = [datetime]::ParseExact($Matches[1], "yyyy-MM-dd'T'HH:mm:ss", [Globalization.CultureInfo]::InvariantCulture)
        if ($time -lt $Since) { continue }
        $level = $Matches[2]; $text = $Matches[3]
        [void]$bootRuns.Add($time)
        if ($text -like "*not answering inside WSL yet*") { $bootNotAnswering++ }
        if ($level -eq "ERROR") { [void]$bootErrors.Add($line) }
        # "nothing to do" is the heartbeat; the gaps below speak for it.
        if ($text -notlike "*nothing to do*") { Add-Timeline $time ("{0:yyyy-MM-dd HH:mm:ss}  {1,-5} [Boot] {2}" -f $time, $level, $text) }
    }
}
$windowsStarts = @($systemEvents | Where-Object { $_.ProviderName -eq "Microsoft-Windows-Kernel-General" -and $_.Id -eq 12 } |
    ForEach-Object { $_.TimeCreated })
$gaps = New-Object System.Collections.ArrayList
$runTimes = @($bootRuns | Sort-Object -Unique)
for ($n = 1; $n -lt $runTimes.Count; $n++) {
    $from = $runTimes[$n - 1]; $to = $runTimes[$n]
    if (($to - $from).TotalMinutes -le 11) { continue }
    $note = ""
    $bootsInside = @($windowsStarts | Where-Object { $_ -gt $from -and $_ -lt $to })
    if ($bootsInside.Count) {
        $lastStart = $bootsInside[-1]
        $note = "; Windows started at {0:HH:mm:ss}, first run {1} after it" -f $lastStart, (Format-Span ($to - $lastStart))
    }
    $gapLine = "{0:yyyy-MM-dd HH:mm} -> {1:yyyy-MM-dd HH:mm} ({2} with no PointyWSL run{3})" -f $from, $to, (Format-Span ($to - $from)), $note
    [void]$gaps.Add($gapLine)
    Add-Timeline $from ("{0:yyyy-MM-dd HH:mm:ss}  GAP   [Boot] {1}" -f $from, $gapLine)
}

# probe.csv, if -Arm ran before: only the rows where something changed.
if (Test-Path $ProbeLog) {
    $last = ""
    foreach ($row in (Import-Csv $ProbeLog -ErrorAction SilentlyContinue)) {
        $key = "$($row.distro)|$($row.edge_8000)|$($row.ready_8000)|$($row.vm_started)"
        if ($key -eq $last) { continue }
        $last = $key
        try {
            $time = [datetime]::ParseExact($row.time, "s", [Globalization.CultureInfo]::InvariantCulture)
            Add-Timeline $time ("{0:yyyy-MM-dd HH:mm:ss}  PROBE [Probe] distro={1} vm_started={2} edge={3} ready={4} wsl_clients={5} task_last_run={6} result={7}" -f
                $time, $row.distro, $row.vm_started, $row.edge_8000, $row.ready_8000, $row.wsl_clients, $row.task_last_run, $row.task_last_result)
        } catch { }
    }
}


# 2. The Linux side. This is the step that starts the distro if it was down.
$guest = @{}
$guestOutput = ""
$linuxDir = Join-Path $Work "linux"
$script:GuestScriptMnt = ConvertTo-WslPath (Join-Path $Work "linux-collect.sh")
Write-TextFile -Path (Join-Path $Work "linux-collect.sh") -Text $GuestSource
if (-not $canGuest) {
    $guestOutput = "skipped: the distro belongs to $owner and this ran as $me"
} elseif ($before.State -eq "not-visible") {
    $guestOutput = "skipped: distro '$Distro' is not registered for $me"
} else {
    Write-Step "Linux side, inside the distro (a minute or two)"
    New-Item -ItemType Directory -Force -Path $linuxDir | Out-Null
    $guestOutput = Invoke-GuestScript @("collect", (ConvertTo-WslPath $linuxDir), "$Days") 900
    $summaryFile = Join-Path $linuxDir "summary.txt"
    if (Test-Path $summaryFile) {
        foreach ($line in [System.IO.File]::ReadAllLines($summaryFile)) {
            if ($line -match '^([a-z0-9_]+)=(.*)$') { $guest[$Matches[1]] = $Matches[2] }
        }
    }
}
Write-TextFile -Path (Join-Path $Work "linux-collect.log") -Text $guestOutput


# 3. What the evidence already says. Each line names what was seen, and the
#    file that shows it.
Write-Step "summary"
$taskInfo = $null
if ($pointyTask) { $taskInfo = $pointyTask | Get-ScheduledTaskInfo }
$bootTypes = @{ 0 = "a full (cold) boot"; 1 = "a Fast Startup (hybrid) boot"; 2 = "a resume from hibernation" }
$lastBootType = @($systemEvents | Where-Object { $_.ProviderName -eq "Microsoft-Windows-Kernel-Boot" -and $_.Id -eq 27 }) | Select-Object -Last 1
$lastBootTypeText = "unknown"
if ($lastBootType) {
    $value = [int]$lastBootType.Properties[0].Value
    $lastBootTypeText = $bootTypes[$value]
    if (-not $lastBootTypeText) { $lastBootTypeText = "boot type $value" }
}
$count = @{}
foreach ($pair in @(@("Microsoft-Windows-Kernel-General", 12, "starts"), @("Microsoft-Windows-Kernel-Power", 41, "unclean"),
                    @("Microsoft-Windows-Kernel-Power", 42, "sleeps"), @("Microsoft-Windows-Kernel-Boot", 27, "boots"))) {
    $count[$pair[2]] = @($systemEvents | Where-Object { $_.ProviderName -eq $pair[0] -and $_.Id -eq $pair[1] }).Count
}
$fastBoots = @($systemEvents | Where-Object { $_.ProviderName -eq "Microsoft-Windows-Kernel-Boot" -and $_.Id -eq 27 -and
    [int]$_.Properties[0].Value -eq 1 }).Count
$sleepAc = ""
$sleepQuery = (Invoke-Native "powercfg.exe" @("/q", "SCHEME_CURRENT", "SUB_SLEEP", "STANDBYIDLE")).Output
$sleepValues = @([regex]::Matches($sleepQuery, '0x[0-9a-fA-F]{8}') | ForEach-Object { $_.Value })
if ($sleepValues.Count -ge 2) { $sleepAc = [Convert]::ToInt32($sleepValues[-2], 16) }
$historyOn = (Invoke-Native "wevtutil.exe" @("gl", "Microsoft-Windows-TaskScheduler/Operational")).Output -match 'enabled:\s*true'

# WSL powers a distro off ~15 s after its last Windows-side client (wsl.exe,
# wslhost.exe) exits. systemd running inside does not count, and
# vmIdleTimeout only keeps the empty VM. [general] instanceIdleTimeout=-1
# (WSL 2.5.4+) is the switch; the owner's .wslconfig is the one WSL reads.
$wslVersion = @((Invoke-Native "wsl.exe" @("--version") -Utf8).Output -split "`n")[0]
$wslVersionNumber = $null
if ($wslVersion -match '(\d+)\.(\d+)\.(\d+)') { $wslVersionNumber = [version]"$($Matches[1]).$($Matches[2]).$($Matches[3])" }
$ownerWslConfig = $null
if ($ownerProfile) { $ownerWslConfig = Join-Path $ownerProfile ".wslconfig" }
elseif ($canGuest) { $ownerWslConfig = Join-Path $env:USERPROFILE ".wslconfig" }
$wslConfigText = ""
if ($ownerWslConfig -and (Test-Path $ownerWslConfig)) { $wslConfigText = [System.IO.File]::ReadAllText($ownerWslConfig) }
$instanceIdle = Get-WslConfigValue $wslConfigText "general" "instanceIdleTimeout"
if ($null -eq $instanceIdle) { $instanceIdle = "not set" }

if (-not $pointyTask) {
    Add-Finding "!! The $TaskName task does not exist, so nothing starts the distro after a restart. Re-running bootstrap-wsl.ps1 registers it."
} else {
    if ("$($pointyTask.State)" -eq "Disabled") { Add-Finding "!! The $TaskName task is DISABLED." }
    if ("$($pointyTask.State)" -eq "Running" -and $taskInfo -and ((Get-Date) - $taskInfo.LastRunTime).TotalMinutes -gt 15) {
        Add-Finding ("!! $TaskName has been running since $($taskInfo.LastRunTime). With MultipleInstances=IgnoreNew a run that " +
                     "never ends blocks every later one. The stuck powershell.exe is in windows\processes.txt.")
    }
    if ($taskInfo -and $taskInfo.LastRunTime -lt $os.LastBootUpTime -and $uptime.TotalMinutes -gt 10) {
        Add-Finding "!! $TaskName has not run since Windows started at $($os.LastBootUpTime) ($(Format-Span $uptime) ago)."
    }
    if ($taskInfo -and ($taskInfo.LastTaskResult -notin @(0, 0x41301))) {
        Add-Finding "!  ${TaskName}'s last run ($($taskInfo.LastRunTime)) ended: $(Format-TaskResult $taskInfo.LastTaskResult)."
    }
    foreach ($a in @($pointyTask.Actions)) {
        if ("$($a.Arguments)" -match '-File\s+"([^"]+)"' -and -not (Test-Path $Matches[1])) {
            Add-Finding "!! $TaskName runs $($Matches[1]), which does not exist."
        }
    }
}
if (-not $canGuest) {
    Add-Finding "!! This ran as $me, but the distro belongs to $owner. Log in as $owner and run it again; the Linux half was skipped."
}
if ($instanceIdle -ne "-1") {
    $where = "the owner's .wslconfig"
    if ($ownerWslConfig) { $where = $ownerWslConfig }
    if ($wslVersionNumber -and $wslVersionNumber -ge [version]"2.5.4") {
        Add-Finding ("!! $where does not set [general] instanceIdleTimeout=-1 (it is: $instanceIdle). WSL powers a distro off " +
                     "~15 s after the last Windows-side wsl.exe/wslhost.exe exits - systemd inside does not count - so between " +
                     "$TaskName runs the stack is down unless a WSL window is open. To stop it now: add the two lines " +
                     "'[general]' and 'instanceIdleTimeout=-1' to that file, then run 'wsl --shutdown' once.")
    } else {
        $versionText = "(version unreadable)"
        if ($wslVersionNumber) { $versionText = "$wslVersionNumber" }
        Add-Finding ("!! WSL $versionText powers a distro off ~15 s after the last Windows-side wsl.exe/wslhost.exe " +
                     "exits - systemd inside does not count - and only WSL 2.5.4+ can be told not to (instanceIdleTimeout). " +
                     "Between $TaskName runs the stack is down unless a WSL window is open.")
    }
}
foreach ($key in @("sparseVhd", "autoMemoryReclaim")) {
    if ($null -ne (Get-WslConfigValue $wslConfigText "wsl2" $key)) {
        Add-Finding "   .wslconfig sets $key under [wsl2], where WSL ignores it with a warning (it is an [experimental] key)."
    }
}
foreach ($line in @($bootErrors | Where-Object { $_ -match 'could not start distro' } | Select-Object -Last 1)) {
    Add-Finding "!! $TaskName could not start the distro. Its last attempt: $line"
}
if ($before.State -eq "stopped") {
    Add-Finding ("!! The distro was STOPPED when this started. Nothing inside it (Docker, the watchdog) runs while it is stopped; " +
                 "only a Windows-side wsl.exe starts it. Reading the Linux side started it for this collection.")
}
if (-not $vmBefore) { Add-Finding "!! The WSL VM itself was not running (no vmmem process)." }
if ($before.State -eq "running" -and $probes["http://127.0.0.1:8000/healthz-edge"] -ne "200") {
    Add-Finding "!  The distro was running but http://127.0.0.1:8000/healthz-edge answered: $($probes['http://127.0.0.1:8000/healthz-edge'])."
}
if ($gaps.Count) {
    Add-Finding "!  bootstrap.log shows $($gaps.Count) stretch(es) of over 11 minutes with no $TaskName run (listed below)."
}
if ($bootNotAnswering) {
    Add-Finding "!  $bootNotAnswering of $($bootRuns.Count) logged $TaskName runs found the stack not answering inside WSL."
}
if ($fastStartup -eq 1) {
    Add-Finding "!  Fast Startup is ON: 'Shut down' hibernates the kernel instead of ending it. The last start was $lastBootTypeText."
}
if ("$sleepAc" -ne "" -and [int]$sleepAc -gt 0) {
    Add-Finding "!  This PC goes to sleep after $([int]($sleepAc / 60)) minutes on mains power. A sleeping server drops every till."
}
if ($count["sleeps"]) { Add-Finding "!  Windows went to sleep $($count['sleeps']) time(s) in the last $Days days." }
if ($count["unclean"]) { Add-Finding "!  Windows restarted without a clean shutdown $($count['unclean']) time(s) (power cut or crash)." }
if (-not $historyOn) { Add-Finding "   Task Scheduler history is off, so $TaskName's past runs are not recorded. -Arm turns it on." }
if (@($processesBefore | Where-Object { $_.Name -like "*docker*" }).Count -or (Get-Service com.docker.service -ErrorAction SilentlyContinue)) {
    Add-Finding "!  Docker Desktop is on this PC. If it still starts an old Pointy stack, it competes for ports 8000 and 80."
}
$otherTasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like "Pointy*" -and $_.TaskName -notin @($TaskName, $ProbeTask) })
if ($otherTasks.Count) {
    Add-Finding "!  Other Pointy tasks exist: $((@($otherTasks) | ForEach-Object { $_.TaskName }) -join ', ') (left over from the Docker Desktop install?)."
}
foreach ($stray in @((Join-Path $env:SystemRoot "System32\config\systemprofile\.wslconfig"), (Join-Path $env:SystemDrive "Users\Default\.wslconfig"))) {
    if (Test-Path $stray) { Add-Finding "!  A .wslconfig exists at $stray, where WSL never reads it: something wrote it without the owner's profile." }
}
if ($guest.Count) {
    if ($guest["containers_down"]) { Add-Finding "!! Containers not running: $($guest['containers_down'])" }
    if ([int]("0" + $guest["oom_kills"]) -gt 0) {
        Add-Finding "!! The Linux kernel killed processes for lack of memory $($guest['oom_kills']) time(s) (linux\kernel-alerts.txt)."
    }
    if ($guest["mem_total_mb"] -and [int]$guest["mem_limits_total_mb"] -gt [int]$guest["mem_total_mb"]) {
        Add-Finding ("!  The containers may use up to $($guest['mem_limits_total_mb']) MB between them, but the WSL VM has " +
                     "$($guest['mem_total_mb']) MB.")
    }
    if ($guest["journal_persistent"] -eq "no") {
        Add-Finding "   The distro's journal does not survive a restart, so only this boot's Linux logs are here. -Arm keeps them."
    }
    if ($guest["docker_restarts"] -and [int]$guest["docker_restarts"] -gt 0) {
        Add-Finding "!  systemd has restarted the Docker daemon $($guest['docker_restarts']) time(s) since the distro started."
    }
    if ($guest["failed_units"]) { Add-Finding "!  Failed systemd units: $($guest['failed_units'])" }
    if ($guest["watchdog_timer"] -and $guest["watchdog_timer"] -ne "active") {
        Add-Finding "!! The watchdog timer is '$($guest['watchdog_timer'])', not active."
    }
    if ($guest["update_lock_age_s"]) { Add-Finding "!  An update lock exists ($($guest['update_lock_age_s'])s old)." }
}

$timelineText = ($timeline | Sort-Object Time | ForEach-Object { $_.Line }) -join "`n"
Write-TextFile -Path (Join-Path $Work "timeline.txt") -Text $timelineText

$summaryLines = New-Object System.Collections.ArrayList
function Add-Line { param([string]$Line = "") [void]$script:summaryLines.Add($Line) }
Add-Line "Pointy diagnostics - $env:COMPUTERNAME - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Add-Line "Collected by $me (admin: $isAdmin). The distro belongs to $owner."
Add-Line
Add-Line "FINDINGS  (!! = very likely part of the problem, ! = worth a look)"
if ($Findings.Count) { foreach ($f in $Findings) { Add-Line "  $f" } } else { Add-Line "  nothing stood out" }
Add-Line
Add-Line "WINDOWS"
Add-Line "  $($os.Caption) (build $($os.BuildNumber)), started $($os.LastBootUpTime), up $(Format-Span $uptime), $lastBootTypeText"
Add-Line "  last $Days days: $($count['starts']) starts ($fastBoots via Fast Startup), $($count['unclean']) unclean, $($count['sleeps']) sleeps"
Add-Line "  Fast Startup: $fastStartup   sleep on mains after (s): $sleepAc   memory: $([int]($cs.TotalPhysicalMemory / 1MB)) MB"
$vmText = "not running"
if ($vmBefore) { $vmText = "up since $($vmBefore.CreationDate)" }
Add-Line "WSL"
Add-Line "  $wslVersion"
Add-Line "  distro when collection started: $($before.State)   VM: $vmText"
Add-Line "  wsl.exe clients attached: $($clientsBefore.Count)"
Add-Line "  [general] instanceIdleTimeout: $instanceIdle   ($ownerWslConfig)"
Add-Line "TASK $TaskName"
if ($pointyTask) {
    Add-Line "  state $($pointyTask.State), runs as $($pointyTask.Principal.UserId) ($($pointyTask.Principal.LogonType))"
    if ($taskInfo) {
        Add-Line "  last run $($taskInfo.LastRunTime) -> $(Format-TaskResult $taskInfo.LastTaskResult)"
        Add-Line "  next run $($taskInfo.NextRunTime), missed runs $($taskInfo.NumberOfMissedRuns)"
    }
} else { Add-Line "  NOT registered" }
$historyText = "off"
if ($historyOn) { $historyText = "on" }
Add-Line "  Task Scheduler history: $historyText"
Add-Line "STACK, as found (before the distro was touched)"
foreach ($url in $probes.Keys) { Add-Line ("  {0,-44} {1}" -f $url, $probes[$url]) }
Add-Line "BOOTSTRAP LOG, last $Days days"
Add-Line "  $($bootRuns.Count) lines, $bootNotAnswering 'not answering inside WSL', $($bootErrors.Count) errors"
foreach ($g in @($gaps | Select-Object -Last 15)) { Add-Line "  gap: $g" }
foreach ($e in @($bootErrors | Select-Object -Last 5)) { Add-Line "  $e" }
Add-Line "LINUX"
if ($guest.Count) { foreach ($k in ($guest.Keys | Sort-Object)) { Add-Line "  $k = $($guest[$k])" } }
else { foreach ($line in @($guestOutput -split "`n" | Select-Object -First 3)) { Add-Line "  $line" } }
$summaryText = ($summaryLines -join "`n")
Write-TextFile -Path (Join-Path $Work "00-summary.txt") -Text $summaryText


# 4. -Arm: leave a recorder behind for the next outage.
if ($Arm) {
    Write-Step "arming: recording from now on"
    $armLines = New-Object System.Collections.ArrayList
    $r = Invoke-Native "wevtutil.exe" @("sl", "Microsoft-Windows-TaskScheduler/Operational", "/e:true", "/ms:20971520")
    if ($r.ExitCode -eq 0) { [void]$armLines.Add("Task Scheduler history: on") }
    else { [void]$armLines.Add("Task Scheduler history: FAILED - $($r.Output.Trim())") }

    if ($canGuest -and $before.State -ne "not-visible") {
        [void]$armLines.Add("Linux: " + ((Invoke-GuestScript @("arm") 120) -replace "`n", " ").Trim())
    } else {
        [void]$armLines.Add("Linux journal: skipped (run as $owner to arm it)")
    }

    try {
        Write-TextFile -Path $ProbeScript -Text $ProbeSource -Bom
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument (
            "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ProbeScript`" " +
            "-Distro `"$Distro`" -LogFile `"$ProbeLog`"")
        # A time trigger, not only a boot trigger: its repeat keeps going
        # whether or not Windows counts a start as a boot.
        $everyMinute = New-ScheduledTaskTrigger -Once -At (Get-Date).Date `
            -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 3650)
        $atStartup = New-ScheduledTaskTrigger -AtStartup
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
        # Same account and logon type as PointyWSL: WSL distros are per user,
        # and whether an S4U task can see the distro at all is part of the question.
        $principal = New-ScheduledTaskPrincipal -UserId $owner -LogonType S4U -RunLevel Highest
        Register-ScheduledTask -TaskName $ProbeTask -Action $action -Trigger @($everyMinute, $atStartup) `
            -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
        $armedAt = Get-Date
        Start-ScheduledTask -TaskName $ProbeTask -ErrorAction SilentlyContinue
        $firstRow = ""
        for ($n = 0; $n -lt 30 -and -not $firstRow; $n++) {
            Start-Sleep -Seconds 1
            if ((Test-Path $ProbeLog) -and (Get-Item $ProbeLog).LastWriteTime -ge $armedAt.AddSeconds(-1)) {
                $firstRow = Get-Content $ProbeLog -Tail 1
            }
        }
        [void]$armLines.Add("PointyProbe: registered as $owner (S4U), one row a minute to $ProbeLog")
        if ($firstRow) {
            [void]$armLines.Add("PointyProbe first row: $firstRow")
            if ($firstRow -match ',not-visible') {
                [void]$armLines.Add("!! Running as a task, WSL could not see the distro. That alone would stop PointyWSL from ever starting it.")
            }
        } else {
            [void]$armLines.Add("PointyProbe: no row after 30s. Check the task in Task Scheduler (taskschd.msc).")
        }
    } catch {
        [void]$armLines.Add("PointyProbe: FAILED to register - $($_.Exception.Message)")
    }
    Write-TextFile -Path (Join-Path $Work "armed.txt") -Text ($armLines -join "`n")
    $summaryText += "`n`nARMED`n  " + ($armLines -join "`n  ")
    Write-TextFile -Path (Join-Path $Work "00-summary.txt") -Text $summaryText
}


# 5. Zip it, keep the newest five, and put a copy on the Desktop.
Write-Step "packing"
Write-Host ""
Write-Host $summaryText
Write-Host ""
$zip = Join-Path $DiagDir ($Name + ".zip")
try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory($Work, $zip,
        [System.IO.Compression.CompressionLevel]::Optimal, $true)
    Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
} catch {
    Write-Host "could not zip ($($_.Exception.Message)); the files are in $Work" -ForegroundColor Yellow
    exit 1
}
Get-ChildItem $DiagDir -Filter "pointy-diag-*.zip" | Sort-Object LastWriteTime -Descending |
    Select-Object -Skip 5 | Remove-Item -Force -ErrorAction SilentlyContinue
$desktop = [Environment]::GetFolderPath("Desktop")
if ($desktop -and (Test-Path $desktop)) {
    Copy-Item -Force $zip $desktop
    $zip = Join-Path $desktop (Split-Path -Leaf $zip)
}
Write-Host "Done. Send this file to the developers:" -ForegroundColor Green
Write-Host "  $zip" -ForegroundColor Green
if ($Arm) {
    Write-Host "Recording is on. After the next outage or failed restart, run this again WITHOUT -Arm and send the new zip." -ForegroundColor Green
}
