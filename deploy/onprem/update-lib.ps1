<#
  Pointy on-prem update engine (Windows) — shared by update.ps1 (a bundle you
  carry to the machine) and update-agent.ps1 (a bundle the relay assigns).
  Dot-source it; it only defines functions. Mirrors update-lib.sh.

  LIVE updates (the default) apply a new release WITHOUT closing the tills. The
  `edge` front door owns :8000, so the new backend can be started alongside the
  one serving customers, run its migrations, prove itself against /readyz, and
  only then take traffic — the flip is an nginx reload, which finishes in-flight
  requests on the old container and refuses nothing.

  RESTART updates are the old behaviour: stop everything, bring it back on the
  new images. Still the right tool in a maintenance window, and the automatic
  fallback when a live update is impossible (no front door yet) or when a
  release declares it needs one (UPDATE_STRATEGY.txt).

  The invariants that make a live update safe:
    * two app versions run against one database for ~a minute, so migrations
      must be backward compatible (expand now, contract in a later release) —
      a release that cannot honour that ships UPDATE_STRATEGY.txt = restart;
    * the database, cache, pooler and front door are NEVER recreated live —
      their new images stay staged for the next maintenance restart;
    * traffic only ever moves to a container that has already answered /readyz;
    * every failure path ends with the shop serving, from whichever version is
      healthy, and says which one that is.
#>

$script:PointyStandbyName = "pointy-backend-standby"
$script:PointyLockFile = ".update.lock"
$script:PointyUpstreamFile = "edge\active\upstream.conf"
if (-not $script:PointyLogTag) { $script:PointyLogTag = "pointy-update" }

function Write-PointyLog($message) {
    Write-Host ("{0} [{1}] {2}" -f (Get-Date -Format s), $script:PointyLogTag, $message)
}
function Write-PointyWarn($message) { Write-PointyLog "WARN: $message" }

function Invoke-Compose {
    docker compose --env-file .env -f docker-compose.yml @args
}

# Read a single KEY=value out of .env (no evaluation, so a password with shell
# metacharacters can never be executed).
function Get-PointyEnvValue($key) {
    if (-not (Test-Path ".env")) { return "" }
    $line = Select-String -Path ".env" -Pattern "^$key=" | Select-Object -First 1
    if (-not $line) { return "" }
    return ($line.Line -replace "^$key=", "").Trim().Trim('"').Trim("'")
}

function Get-PointyBackendPort {
    $port = Get-PointyEnvValue "POINTY_BACKEND_PORT"
    if ($port) { return $port }
    return "8000"
}

# nginx rejects a byte-order mark, and Windows PowerShell's UTF8 encoding writes
# one — so every config file we generate goes through this: UTF-8 without a BOM,
# LF line endings, exactly as the container expects.
function Write-PointyTextFile($path, $lines) {
    $parent = Split-Path -Parent $path
    if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $text = ($lines -join "`n") + "`n"
    [System.IO.File]::WriteAllText((Join-Path (Get-Location) $path), $text, (New-Object System.Text.UTF8Encoding($false)))
}

# ---------------------------------------------------------------------------
# Mutual exclusion with the watchdog
#
# The watchdog reconciles the stack every few minutes. It must not run `compose
# up` in the middle of a flip, so both sides respect this lock file. It carries a
# timestamp because the holder can die with the host: watchdog.ps1 ignores a lock
# older than POINTY_UPDATE_LOCK_MAX_AGE so a crashed update cannot disable the
# watchdog forever.
# ---------------------------------------------------------------------------
function Get-PointyUpdateLock {
    $maxAge = 3600
    if ($env:POINTY_UPDATE_LOCK_MAX_AGE) { $maxAge = [int]$env:POINTY_UPDATE_LOCK_MAX_AGE }
    if (Test-Path $script:PointyLockFile) {
        $age = ((Get-Date) - (Get-Item $script:PointyLockFile).LastWriteTime).TotalSeconds
        if ($age -lt $maxAge) {
            Write-PointyLog ("another update is already running ({0:N0}s ago); nothing to do" -f $age)
            return $false
        }
        Write-PointyWarn ("clearing a stale update lock ({0:N0}s old)" -f $age)
    }
    Write-PointyTextFile $script:PointyLockFile @("pid=$PID started=$(Get-Date -Format s)")
    return $true
}

function Remove-PointyUpdateLock {
    Remove-Item -Force $script:PointyLockFile -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Health
# ---------------------------------------------------------------------------

# The LAN front door answering /readyz — i.e. exactly what a till sees.
function Test-PointyHealthy([int]$tries = 60) {
    $port = Get-PointyBackendPort
    for ($i = 0; $i -lt $tries; $i++) {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/readyz/" -TimeoutSec 5 | Out-Null
            return $true
        } catch { Start-Sleep -Seconds 5 }
    }
    return $false
}

# Containers are addressed two different ways here and they are NOT the same
# string: nginx reaches a backend by its DNS name on the Compose network (the
# service alias `backend`, or the standby's container name), while docker
# inspect/logs need the real container (`pointy-backend-1`). Resolve one to the
# other — a compose service maps to its container, anything else is already one.
function Get-PointyContainerId($name) {
    $id = Invoke-Compose ps -aq $name 2>$null | Select-Object -First 1
    if ($LASTEXITCODE -eq 0 -and $id) { return $id }
    return $name
}

function Test-PointyContainerRunning($name) {
    $state = docker inspect -f '{{.State.Running}}' (Get-PointyContainerId $name) 2>$null
    return ($LASTEXITCODE -eq 0 -and $state -eq "true")
}

function Show-PointyContainerLogs($name) {
    docker logs --tail 40 (Get-PointyContainerId $name) 2>&1 | ForEach-Object { Write-Host "    $_" }
}

# Is the zero-downtime path available at all? It needs the front door to be up
# and holding the LAN port; a deployment installed before the front door existed
# updates the old way (once), and gets it from that update onwards.
function Test-PointyEdgeAvailable {
    $services = Invoke-Compose ps --status running --format '{{.Service}}' 2>$null
    if ($LASTEXITCODE -ne 0) { return $false }
    return (($services -split "`n") -contains "edge")
}

# Ask the front door itself whether a backend container is ready. This probes the
# exact path traffic will take after the flip — container DNS included — so a
# name nginx cannot resolve fails here instead of after the switch.
function Test-PointyUpstreamReady($name) {
    Invoke-Compose exec -T edge wget -q -O /dev/null "http://${name}:8000/readyz/" 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# Wait for a backend container to serve, giving up early if it dies.
function Wait-PointyUpstream($name, $label, [int]$tries = 180) {
    for ($i = 0; $i -lt $tries; $i++) {
        if (-not (Test-PointyContainerRunning $name)) {
            Write-PointyWarn "$label exited during startup; last log lines:"
            Show-PointyContainerLogs $name
            return $false
        }
        if (Test-PointyUpstreamReady $name) {
            Write-PointyLog "$label is ready"
            return $true
        }
        if ((($i + 1) % 12) -eq 0) { Write-PointyLog "still waiting for $label ($(($i + 1) * 10)s)..." }
        Start-Sleep -Seconds 10
    }
    Write-PointyWarn "$label never became ready; last log lines:"
    Show-PointyContainerLogs $name
    return $false
}

# ---------------------------------------------------------------------------
# The flip
# ---------------------------------------------------------------------------

# Point the LAN front door at a container and PROVE it took effect. nginx keeps
# serving its previous config if a reload fails, so "the command returned 0" is
# not evidence — the response header is.
function Set-PointyUpstream($target) {
    $port = Get-PointyBackendPort

    # Keep the previous pointer so a rejected config never survives on disk: the
    # front door re-reads this file when it restarts, so leaving a broken one
    # behind would turn a failed flip into an nginx that cannot start at all.
    $previous = $null
    if (Test-Path $script:PointyUpstreamFile) {
        $previous = Get-Content $script:PointyUpstreamFile -Raw
    }
    Write-PointyTextFile $script:PointyUpstreamFile @(
        "# GENERATED - see update-lib.ps1 (Set-PointyUpstream). Reset by install.ps1 and",
        "# by watchdog.ps1 whenever the container named here is not running.",
        "set `$pointy_upstream      `"http://${target}:8000`";",
        "set `$pointy_upstream_name `"$target`";"
    )

    Invoke-Compose exec -T edge nginx -t 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-PointyWarn "front-door config rejected by nginx -t; leaving traffic where it is"
        Invoke-Compose exec -T edge nginx -t 2>&1 | ForEach-Object { Write-Host "    $_" }
        if ($null -ne $previous) {
            [System.IO.File]::WriteAllText(
                (Join-Path (Get-Location) $script:PointyUpstreamFile), $previous,
                (New-Object System.Text.UTF8Encoding($false)))
        } else {
            Remove-Item -Force $script:PointyUpstreamFile -ErrorAction SilentlyContinue
        }
        return $false
    }
    Invoke-Compose exec -T edge nginx -s reload 2>$null | Out-Null

    for ($i = 0; $i -lt 10; $i++) {
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Method Head `
                -Uri "http://127.0.0.1:$port/healthz-edge" -TimeoutSec 5
            if ($response.Headers["X-Pointy-Upstream"] -eq $target) {
                Write-PointyLog "traffic now served by $target"
                return $true
            }
        } catch {}
        Start-Sleep -Seconds 1
    }
    Write-PointyWarn "front door did not report $target after reload"
    return $false
}

# ---------------------------------------------------------------------------
# Bundle handling
# ---------------------------------------------------------------------------

$script:PointyAdoptFiles = @(
    "docker-compose.yml", "install.sh", "install.ps1", "watchdog.sh", "watchdog.ps1",
    "register-autostart.sh", "register-autostart.ps1", "update.sh",
    "update-agent.sh", "update-lib.sh",
    "discovery-responder.py", "discovery-responder.ps1", "migrate-fahd.sh", "migrate-fahd.ps1",
    "disable-watchdog.sh", "disable-watchdog.ps1", "fix-backend-outages.sh", "fix-backend-outages.ps1",
    ".env.example", "VERSION.txt", "INSTALL.md", "README.md"
)

# The PowerShell scripts that are running (or dot-sourced) while the update runs.
# Windows can refuse to overwrite a .ps1 PowerShell still has open, and an update
# must not die on that — so these are staged as <name>.new and installed by the
# promote step at the top of update.ps1 / update-agent.ps1 on the next run.
$script:PointySelfFiles = @("update.ps1", "update-agent.ps1", "update-lib.ps1")

# Which strategy the release itself asks for. A release whose migrations cannot
# be applied while the previous version is still running ships
# UPDATE_STRATEGY.txt containing "restart", and gets a maintenance-style update
# even when the operator did not ask for one.
function Get-PointyBundleStrategy($bundleDir) {
    $file = Join-Path $bundleDir "UPDATE_STRATEGY.txt"
    if (-not (Test-Path $file)) { return "live" }
    $value = (Get-Content $file -Raw).Trim().ToLower()
    if ($value -in @("restart", "downtime", "offline")) { return "restart" }
    return "live"
}

function Write-PointyDefaultUpstream {
    Write-PointyTextFile $script:PointyUpstreamFile @(
        "# GENERATED - the backend the LAN front door is currently sending traffic to.",
        "set `$pointy_upstream      `"http://backend:8000`";",
        "set `$pointy_upstream_name `"backend`";"
    )
}

# Copy the bundle over this deployment, keeping everything stateful: .env,
# volumes, backups, and the front door's current upstream pointer.
function Invoke-PointyAdoptBundle($bundleDir, $assigned) {
    foreach ($file in $script:PointyAdoptFiles) {
        $source = Join-Path $bundleDir $file
        if (Test-Path $source) { Copy-Item -Force $source (Join-Path "." $file) }
    }
    foreach ($file in $script:PointySelfFiles) {
        $source = Join-Path $bundleDir $file
        if (Test-Path $source) { Copy-Item -Force $source (Join-Path "." "$file.new") }
    }

    # The front door's own config travels inside its image; only the "which
    # backend is live" pointer lives here, and it is state — it must survive the
    # update untouched.
    if (-not (Test-Path $script:PointyUpstreamFile)) { Write-PointyDefaultUpstream }

    Remove-Item -Recurse -Force "images" -ErrorAction SilentlyContinue
    Copy-Item -Recurse -Force (Join-Path $bundleDir "images") ".\images"
    if (Test-Path (Join-Path $bundleDir "clients")) {
        Remove-Item -Recurse -Force "clients" -ErrorAction SilentlyContinue
        Copy-Item -Recurse -Force (Join-Path $bundleDir "clients") ".\clients"
    }

    # Pin the app images. Infrastructure images (postgres, redis, pgbouncer, the
    # front door) are deliberately left alone — see Import-PointyImages.
    $envText = Get-Content ".env"
    $envText = $envText -replace "^POINTY_BACKEND_IMAGE=.*", "POINTY_BACKEND_IMAGE=pointy-backend:$assigned"
    $envText = $envText -replace "^POINTY_RELAY_IMAGE=.*", "POINTY_RELAY_IMAGE=pointy-relay:$assigned"
    $envText = $envText -replace "^POINTY_WEB_IMAGE=.*", "POINTY_WEB_IMAGE=pointy-web:$assigned"
    Write-PointyTextFile ".env" $envText
}

# Load images from .\images. A live update loads ONLY the application images:
# loading a new postgres/redis/pgbouncer/front-door tar would change what the
# compose file resolves to and hand the next `compose up` a reason to recreate
# the database or the LAN front door — precisely the outage we are avoiding.
# Those tars stay staged in .\images and install at the next full restart.
function Import-PointyImages($mode) {
    $tars = Get-ChildItem -Path "images" -Filter "*.tar" -ErrorAction SilentlyContinue
    if (-not $tars) { Write-PointyWarn "no image archives under .\images"; return $false }
    $loaded = 0
    foreach ($tar in $tars) {
        if ($mode -eq "live") {
            if ($tar.Name -like "pointy-edge*") { continue }
            if ($tar.Name -notlike "pointy-*") { continue }
        }
        Write-PointyLog "loading $($tar.Name)..."
        docker load -i $tar.FullName | Out-Null
        if ($LASTEXITCODE -ne 0) { return $false }
        $loaded++
    }
    if ($loaded -eq 0) { Write-PointyWarn "no application images found in .\images"; return $false }
    return $true
}

# Infrastructure images the bundle carries but a live update did not apply.
function Show-PointyStagedInfra {
    $tars = Get-ChildItem -Path "images" -Filter "*.tar" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "pointy-edge*" -or $_.Name -notlike "pointy-*" }
    if (-not $tars) { return }
    $names = ($tars | ForEach-Object { $_.BaseName }) -join " "
    Write-PointyLog "staged for the next maintenance restart (not applied live): $names"
}

# ---------------------------------------------------------------------------
# Applying
# ---------------------------------------------------------------------------

function Remove-PointyStandby {
    docker rm -f $script:PointyStandbyName 2>$null | Out-Null
}

# Start the new backend beside the running one. `compose run` builds it from the
# very same service definition (env, volumes, limits) but publishes no port and
# carries the one-off label, so it cannot collide with the live container and
# `compose up --remove-orphans` will not sweep it away. Its boot runs the new
# release's migrations against the live database — the expand/contract window.
function Start-PointyStandby {
    Remove-PointyStandby
    Write-PointyLog "starting the new backend alongside the live one (migrations run here)..."
    Invoke-Compose run -d --no-deps --name $script:PointyStandbyName backend | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# Recreate one service on the new image without touching its dependencies.
function Invoke-PointyRecreate {
    Invoke-Compose up -d --no-deps --force-recreate @args 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# The zero-downtime path. Returns 0 on success, 1 if it aborted before moving any
# traffic (the shop never noticed), 2 if it failed after the flip and the caller
# must roll the backend back.
function Invoke-PointyLiveApply($assigned) {
    if (-not (Import-PointyImages "live")) { return 1 }
    if (-not (Start-PointyStandby)) { Write-PointyWarn "could not start the new backend"; return 1 }

    $tries = 180
    if ($env:POINTY_STANDBY_READY_TRIES) { $tries = [int]$env:POINTY_STANDBY_READY_TRIES }
    if (-not (Wait-PointyUpstream $script:PointyStandbyName "the new backend" $tries)) {
        Remove-PointyStandby
        Write-PointyWarn "the new backend never became ready - nothing was switched over"
        return 1
    }

    # From here traffic moves. Every step below keeps one healthy backend serving.
    if (-not (Set-PointyUpstream $script:PointyStandbyName)) { Remove-PointyStandby; return 1 }

    # Promote: rebuild the long-lived `backend` container on the new image while
    # the standby serves, then hand the traffic back to it. The standby is a
    # one-off container with no restart policy, so it must never be the thing the
    # shop depends on overnight.
    Write-PointyLog "rebuilding the managed backend on $assigned..."
    if (-not (Invoke-PointyRecreate backend)) {
        Write-PointyWarn "could not recreate the backend service"
        return 2
    }
    if (-not (Wait-PointyUpstream "backend" "the rebuilt backend" 120)) { return 2 }
    if (-not (Set-PointyUpstream "backend")) { return 2 }
    Remove-PointyStandby

    # Everything else can be replaced normally now: none of it holds the LAN port,
    # and the tills are already being served by the new backend.
    Write-PointyLog "updating background workers, relay connector and web app..."
    if (-not (Invoke-PointyRecreate celery-worker celery-beat)) {
        Write-PointyWarn "background workers did not restart cleanly; check 'compose ps'"
    }
    if (-not (Invoke-PointyRecreate connector)) {
        Write-PointyWarn "relay connector did not restart cleanly; check 'compose ps'"
    }
    if (-not (Invoke-PointyRecreate web)) {
        Write-PointyWarn "web app did not restart cleanly; check 'compose ps'"
    }

    Publish-PointyClients
    Show-PointyStagedInfra
    return 0
}

# The maintenance path: the pre-existing behaviour — run the bundle's own
# installer, which loads every image and brings the whole stack up on it. The
# tills are offline for the length of a full restart.
function Invoke-PointyRestartApply {
    Write-PointyLog "applying with a full restart (the stack will be briefly offline)..."
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\install.ps1"
    return ($LASTEXITCODE -eq 0)
}

# Publish the bundled client installers into the volume Django serves on the LAN,
# so tills self-update too. install.ps1 does this on the restart path.
function Publish-PointyClients {
    if (-not (Test-Path "clients")) { return }
    Write-PointyLog "publishing client installers for LAN download..."
    Invoke-Compose cp clients/. backend:/var/lib/pointy/clients/ 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Invoke-Compose exec -u 0 -T backend chmod -R a+rX /var/lib/pointy/clients 2>$null | Out-Null
    } else {
        Write-PointyWarn "could not publish client installers; re-run install.ps1 once the backend is up"
    }
}

# Re-register autostart after every update so tasks a new bundle ships (watchdog,
# update agent, LAN discovery responder) are installed hands-off. Idempotent.
function Register-PointyAutostart {
    $isAdmin = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
      ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
    if ($isAdmin) {
        Write-PointyLog "re-registering autostart tasks..."
        try { & (Join-Path $PSScriptRoot "register-autostart.ps1") }
        catch { Write-PointyWarn "autostart registration failed: $($_.Exception.Message)" }
    } else {
        Write-PointyLog "NOTE: not elevated - run register-autostart.ps1 once from an elevated"
        Write-PointyLog "      PowerShell so tasks added by this update are registered."
    }
}

# Back up before any migration runs: a forward migration is the one thing a
# rollback cannot fully undo on its own. Best-effort, as before.
function Backup-PointyDatabase($current, $assigned) {
    New-Item -ItemType Directory -Force -Path "backups" | Out-Null
    $backup = "backups\pre-update-$current-to-$assigned.sql"
    try {
        Invoke-Compose exec -T postgres sh -c 'pg_dump -U "${POSTGRES_USER:-pointy}" "${POSTGRES_DB:-pointy}"' |
            Set-Content -Path $backup -Encoding UTF8
        if ($LASTEXITCODE -eq 0) {
            Write-PointyLog "database backed up to $backup"
            return
        }
    } catch {}
    Remove-Item -Path $backup -ErrorAction SilentlyContinue
    Write-PointyWarn "database backup failed (stack down?); continuing - rollback restores images, not data"
}

function Restore-PointySnapshot($snapshot) {
    Copy-Item -Force (Join-Path $snapshot ".env") ".env"
    $composeSnapshot = Join-Path $snapshot "docker-compose.yml"
    if (Test-Path $composeSnapshot) { Copy-Item -Force $composeSnapshot "docker-compose.yml" }
    Remove-Item -Recurse -Force $snapshot -ErrorAction SilentlyContinue
}

# Traffic had already moved to the new version when something downstream failed.
# Bring the previous release's backend back and hand the front door to it.
function Invoke-PointyLiveRollback($snapshot, $current, $assigned) {
    Write-PointyWarn "update to $assigned failed after the switchover; rolling back to $current"
    Restore-PointySnapshot $snapshot
    if ((Invoke-PointyRecreate backend) -and (Wait-PointyUpstream "backend" "the restored backend" 120)) {
        Set-PointyUpstream "backend" | Out-Null
        Remove-PointyStandby
        Write-PointyWarn "rolled back to $current; the shop stayed open throughout"
        return
    }
    # The old release will not come back. The new one is running and serving, so
    # leave it serving — but give it a restart policy first, because it was
    # created as a temporary container and would not survive a crash or a reboot.
    if (Test-PointyContainerRunning $script:PointyStandbyName) {
        docker update --restart=unless-stopped $script:PointyStandbyName 2>$null | Out-Null
        Set-PointyUpstream $script:PointyStandbyName | Out-Null
        Write-PointyWarn "could not restore $current; the shop is being served by $assigned from a"
        Write-PointyWarn "temporary container. Run install.ps1 at the next opportunity to make it permanent."
        return
    }
    Write-PointyWarn "no healthy backend left - run install.ps1 now"
}

# ---------------------------------------------------------------------------
# Orchestration: the whole update, including rollback. Front-ends call this.
# mode: auto | live | restart. Returns $true on success.
# ---------------------------------------------------------------------------
function Invoke-PointyApplyBundle($bundleDir, $current, $assigned, $mode = "auto") {
    $strategy = $mode
    if ($mode -eq "auto") {
        $strategy = Get-PointyBundleStrategy $bundleDir
        if ($strategy -eq "live" -and -not (Test-PointyEdgeAvailable)) {
            Write-PointyLog "no LAN front door in this deployment yet - this one update needs a restart;"
            Write-PointyLog "it installs the front door, and updates after it are applied live."
            $strategy = "restart"
        }
    } elseif ($mode -eq "live" -and -not (Test-PointyEdgeAvailable)) {
        Write-PointyWarn "a live update needs the LAN front door, which is not running; falling back to a restart"
        $strategy = "restart"
    }
    if ($mode -eq "live" -and (Get-PointyBundleStrategy $bundleDir) -eq "restart") {
        Write-PointyWarn "release $assigned declares it cannot be applied live (UPDATE_STRATEGY.txt); restarting"
        $strategy = "restart"
    }

    if ($strategy -eq "live") {
        Write-PointyLog "updating $current -> $assigned live (the shop keeps trading)"
    } else {
        Write-PointyLog "updating $current -> $assigned with a full restart"
    }

    Backup-PointyDatabase $current $assigned

    $snapshot = (New-Item -ItemType Directory -Path (Join-Path $env:TEMP ("pointy-rollback-" + [guid]::NewGuid()))).FullName
    Copy-Item -Force ".env" (Join-Path $snapshot ".env")
    if (Test-Path "docker-compose.yml") { Copy-Item -Force "docker-compose.yml" (Join-Path $snapshot "docker-compose.yml") }

    Invoke-PointyAdoptBundle $bundleDir $assigned

    if ($strategy -eq "live") {
        $result = Invoke-PointyLiveApply $assigned
        if ($result -eq 0 -and (Test-PointyHealthy 24)) {
            Write-PointyTextFile "VERSION.txt" @($assigned)
            Register-PointyAutostart
            Remove-Item -Recurse -Force $snapshot -ErrorAction SilentlyContinue
            Write-PointyLog "updated to $assigned - no downtime"
            return $true
        }
        if ($result -eq 1) {
            # Nothing was ever switched over: the old backend is still the one
            # serving. Put the configuration back so the watchdog cannot apply
            # the half-staged release behind our back.
            Restore-PointySnapshot $snapshot
            Write-PointyWarn "update to $assigned aborted before any traffic moved; still on $current"
            return $false
        }
        Invoke-PointyLiveRollback $snapshot $current $assigned
        return $false
    }

    if ((Invoke-PointyRestartApply) -and (Test-PointyHealthy)) {
        Write-PointyTextFile "VERSION.txt" @($assigned)
        Register-PointyAutostart
        Remove-Item -Recurse -Force $snapshot -ErrorAction SilentlyContinue
        Write-PointyLog "updated to $assigned"
        return $true
    }

    Write-PointyWarn "update to $assigned failed health check; rolling back to $current"
    Restore-PointySnapshot $snapshot
    Invoke-Compose up -d --remove-orphans 2>$null | Out-Null
    if (Test-PointyHealthy) {
        Write-PointyWarn "update to $assigned failed; rolled back to $current"
        return $false
    }
    Write-PointyWarn "update to $assigned failed AND the rollback is unhealthy - manual intervention needed"
    return $false
}

# ---------------------------------------------------------------------------
# Staging a bundle from a zip or a directory. Returns @{ Dir; Version; Staging }.
# ---------------------------------------------------------------------------
function Expand-PointyBundle($source) {
    $staging = $null
    if (Test-Path $source -PathType Container) {
        $bundleDir = (Resolve-Path $source).Path
    } else {
        $staging = (New-Item -ItemType Directory -Path (Join-Path $env:TEMP ("pointy-update-" + [guid]::NewGuid()))).FullName
        Write-PointyLog "extracting $(Split-Path $source -Leaf)..."
        Expand-Archive -Path $source -DestinationPath $staging -Force
        $inner = Get-ChildItem $staging -Directory -Filter "pointy-onprem-*" | Select-Object -First 1
        $bundleDir = if ($inner) { $inner.FullName } else { $staging }
    }
    if (-not (Test-Path (Join-Path $bundleDir "images"))) {
        throw "not a Pointy bundle: no images/ directory in $bundleDir"
    }
    $version = "unknown"
    $versionFile = Join-Path $bundleDir "VERSION.txt"
    if (Test-Path $versionFile) { $version = (Get-Content $versionFile -Raw).Trim() }
    return @{ Dir = $bundleDir; Version = $version; Staging = $staging }
}

function Get-PointyCurrentVersion {
    if (Test-Path "VERSION.txt") { return (Get-Content "VERSION.txt" -Raw).Trim() }
    return "unknown"
}
