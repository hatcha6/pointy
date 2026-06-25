<#
  Pointy uptime watchdog (Windows / Docker Desktop).

  Keeps the till online with zero manual intervention. It is idempotent and
  meant to run at logon and on a short schedule (see register-autostart.ps1).
  Every run it:
    0. starts Docker Desktop if it is installed but not running,
    1. waits for the Docker engine (it may still be coming up after a reboot),
    2. runs `docker compose up -d` — which (re)creates any container that
       crashed into a stopped state OR was destroyed/removed entirely, and
    3. restarts any container that is running but stuck "unhealthy" (Docker's
       own restart policy does NOT act on failed health checks).

  Layer this on top of `restart: always` in the compose file: the restart
  policy gives instant in-place crash recovery, and the watchdog catches
  everything the restart policy cannot (host reboot, removed containers, wedged
  processes, the engine not being up yet, Docker Desktop not started).
#>
$ErrorActionPreference = "Continue"
Set-Location -Path $PSScriptRoot

function Log($m) { Write-Host ("{0} [pointy-watchdog] {1}" -f (Get-Date -Format s), $m) }

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

# 2. Reconcile: start/recreate anything missing, stopped, or destroyed.
Log "reconciling stack (compose up -d)..."
docker compose --env-file .env -f docker-compose.yml up -d --remove-orphans

# 3. Heal: restart project containers that are running but unhealthy.
$project = if ($env:COMPOSE_PROJECT_NAME) { $env:COMPOSE_PROJECT_NAME } else { "pointy" }
$unhealthy = docker ps --filter "label=com.docker.compose.project=$project" --filter "health=unhealthy" -q
if ($unhealthy) {
    foreach ($id in $unhealthy) {
        Log "restarting unhealthy container: $id"
        docker restart $id | Out-Null
    }
}

Log "run complete."
