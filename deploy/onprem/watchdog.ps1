<#
  Pointy uptime watchdog (Windows / Docker Desktop).

  Keeps the till online with zero manual intervention. It is idempotent and
  meant to run at logon and on a short schedule (see register-autostart.ps1).
  Every run it:
    0. starts Docker Desktop if it is installed but not running,
    1. waits for the Docker engine (it may still be coming up after a reboot),
    2. runs `docker compose up -d --no-recreate` — which (re)creates any
       container that crashed into a stopped state OR was destroyed/removed
       entirely, without ever REPLACING a container that is running happily,
    3. puts the LAN front door back on the managed backend if a live update was
       interrupted and left it pointing at a container that no longer exists, and
    4. restarts any container that is running but stuck "unhealthy" (Docker's
       own restart policy does NOT act on failed health checks).

  It is availability, not convergence: `--no-recreate` is deliberate. Without it
  the watchdog would silently apply any pending configuration or image change at
  whatever minute its timer next fired — restarting the database under a trading
  shop to "fix" a drift nobody asked it to fix. Applying changes is install.ps1's
  and update.ps1's job, at a moment somebody chose.

  Layer this on top of `restart: always` in the compose file: the restart
  policy gives instant in-place crash recovery, and the watchdog catches
  everything the restart policy cannot (host reboot, removed containers, wedged
  processes, the engine not being up yet, Docker Desktop not started).
#>
$ErrorActionPreference = "Continue"
Set-Location -Path $PSScriptRoot

function Log($m) { Write-Host ("{0} [pointy-watchdog] {1}" -f (Get-Date -Format s), $m) }

# An update in flight owns the stack. Reconciling underneath it would fight it
# for the backend container mid-flip, so stand down — but only while the lock is
# fresh, so an update killed by a power cut cannot disable the watchdog for good.
function Update-InProgress {
    if (-not (Test-Path ".update.lock")) { return $false }
    $maxAge = 3600
    if ($env:POINTY_UPDATE_LOCK_MAX_AGE) { $maxAge = [int]$env:POINTY_UPDATE_LOCK_MAX_AGE }
    $age = ((Get-Date) - (Get-Item ".update.lock").LastWriteTime).TotalSeconds
    if ($age -lt $maxAge) { return $true }
    Log ("ignoring a stale update lock ({0:N0}s old)" -f $age)
    return $false
}

# A live update points the LAN front door at a temporary container while it swaps
# the backend. That container is not managed by compose and does not come back
# after a reboot, so if the update died in the middle, the front door would keep
# proxying to something that no longer exists — the shop's tills would see 502s
# with a perfectly healthy backend sitting right there. Put it back.
function Repair-FrontDoor {
    $pointer = "edge\active\upstream.conf"
    if (-not (Test-Path $pointer)) { return }
    $match = Select-String -Path $pointer -Pattern '^set \$pointy_upstream_name\s+"([^"]+)"' | Select-Object -First 1
    if (-not $match) { return }
    $target = $match.Matches[0].Groups[1].Value
    if ($target -eq "backend") { return }
    $running = docker inspect -f '{{.State.Running}}' $target 2>$null
    if ($LASTEXITCODE -eq 0 -and $running -eq "true") { return }

    Log "front door points at $target, which is not running; restoring the managed backend"
    $text = @(
        "# GENERATED - restored by watchdog.ps1 after an interrupted live update.",
        "set `$pointy_upstream      `"http://backend:8000`";",
        "set `$pointy_upstream_name `"backend`";"
    ) -join "`n"
    [System.IO.File]::WriteAllText(
        (Join-Path (Get-Location) $pointer), $text + "`n",
        (New-Object System.Text.UTF8Encoding($false)))
    docker compose --env-file .env -f docker-compose.yml exec -T edge nginx -s reload 2>$null | Out-Null
}

# 0. Start Docker Desktop if present and not already running. (It needs an
#    interactive user session — this is why the host must auto-login; see
#    INSTALL.md > Resilience.)
$dockerDesktop = Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe"
if ((Test-Path $dockerDesktop) -and -not (Get-Process "Docker Desktop" -ErrorAction SilentlyContinue)) {
    Log "starting Docker Desktop..."
    Start-Process $dockerDesktop | Out-Null
}

# 1. Wait for the Docker engine (up to ~5 minutes).
$engineUp = $false
for ($i = 1; $i -le 60; $i++) {
    docker info *> $null
    if ($LASTEXITCODE -eq 0) { $engineUp = $true; break }
    Log "waiting for Docker engine ($i/60)..."
    Start-Sleep -Seconds 5
}
if (-not $engineUp) {
    Log "Docker engine not reachable; will retry on the next run."
    exit 1
}

if (-not (Test-Path ".env")) {
    Log ".env not found next to this script; cannot manage the stack."
    exit 1
}

if (Update-InProgress) {
    Log "an update is in progress; standing down until it finishes."
    exit 0
}

# 2. Reconcile: start anything missing, stopped, or destroyed — but never
#    replace a running container (see the header).
Log "reconciling stack (compose up -d --no-recreate)..."
docker compose --env-file .env -f docker-compose.yml up -d --no-recreate --remove-orphans

# 2b. Undo a half-finished live update, if one died leaving traffic pointed at a
#     container that is gone.
Repair-FrontDoor

# 3. Heal: restart project containers that are running but unhealthy.
$project = if ($env:COMPOSE_PROJECT_NAME) { $env:COMPOSE_PROJECT_NAME } else { "pointy" }
# The oneoff filter excludes the temporary container a live update runs the new
# backend in: it belongs to the updater, which is watching it far more closely
# than this loop can.
$unhealthy = docker ps --filter "label=com.docker.compose.project=$project" `
    --filter "label=com.docker.compose.oneoff=False" --filter "health=unhealthy" -q
if ($unhealthy) {
    foreach ($id in $unhealthy) {
        Log "restarting unhealthy container: $id"
        docker restart $id | Out-Null
    }
}

Log "run complete."
