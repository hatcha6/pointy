<#
  Pointy on-prem remote update agent (Windows). Mirrors update-agent.sh.

  Polls the relay for the version this installation should run and, when a newer
  one is assigned, downloads the bundle FROM THE RELAY, verifies its sha256,
  backs up the database, applies it (docker load + compose up via install.ps1),
  health-checks the result, and rolls back automatically on failure. Runs as a
  Scheduled Task next to the watchdog. Use -Check to preview without applying.
#>
param([switch]$Check)
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$AgentVersion = "pointy-update-agent/1"
function Log($m) { Write-Host ("{0} [pointy-update-agent] {1}" -f (Get-Date -Format s), $m) }

# Self-update: a bundle stages the new agent as update-agent.ps1.new; promote it
# and re-exec before doing work (never overwrite the running script).
if ((Test-Path "update-agent.ps1.new") -and (-not $env:POINTY_AGENT_PROMOTED)) {
    Move-Item -Force "update-agent.ps1.new" "update-agent.ps1"
    $env:POINTY_AGENT_PROMOTED = "1"
    $forward = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ".\update-agent.ps1")
    if ($Check) { $forward += "-Check" }
    & powershell.exe @forward
    exit $LASTEXITCODE
}

$compose = @("compose", "--env-file", ".env", "-f", "docker-compose.yml")
function Compose { docker @compose @args }

function EnvValue($key) {
    $line = Select-String -Path ".env" -Pattern "^$key=" | Select-Object -First 1
    if (-not $line) { return "" }
    return ($line.Line -replace "^$key=", "").Trim().Trim('"')
}

$relay = (EnvValue "POINTY_RELAY_PUBLIC_API_URL").TrimEnd('/')
if (-not $relay) { throw "POINTY_RELAY_PUBLIC_API_URL is not set in .env" }

$current = "unknown"
if (Test-Path "VERSION.txt") { $current = (Get-Content "VERSION.txt" -Raw).Trim() }

# Connector token via `docker cp` (works even though the connector image is scratch).
$state = New-TemporaryFile
try { Compose cp connector:/var/lib/pointy/relay-connector.json $state.FullName 2>$null } catch {}
if ((-not (Test-Path $state)) -or ((Get-Item $state).Length -eq 0)) {
    Log "connector state unavailable yet; retrying next run"; exit 0
}
$token = (Get-Content $state.FullName -Raw | ConvertFrom-Json).connector_token
if (-not $token) { throw "connector token not found in connector state" }
$headers = @{ "X-Pointy-Connector-Token" = $token }

function Report($cur, $status, $err) {
    try {
        $body = @{ current_version = $cur; agent_version = $AgentVersion; update_status = $status; update_error = $err } | ConvertTo-Json -Compress
        Invoke-RestMethod -Method Post -Uri "$relay/v1/agent/status" -Headers $headers -ContentType "application/json" -Body $body | Out-Null
    } catch {}
}
function Healthy {
    for ($i = 0; $i -lt 60; $i++) {
        try { Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:8000/readyz/" -TimeoutSec 5 | Out-Null; return $true }
        catch { Start-Sleep 5 }
    }
    return $false
}

try { $manifest = Invoke-RestMethod -Uri "$relay/v1/agent/manifest" -Headers $headers }
catch { Log "manifest fetch failed; retrying next run"; exit 0 }

$directive = $manifest.directive
$assigned = $manifest.assigned_version
if ($directive -ne "apply" -or -not $assigned -or $assigned -eq $current) {
    Log "up to date (current=$current, directive=$directive, assigned=$assigned)"
    Report $current "idle" ""
    exit 0
}
Log "update available: $current -> $assigned"
if ($Check) { Log "--check: would apply $assigned"; exit 0 }
Report $current "applying" ""

$bundlePath = $manifest.bundle.path
$bundleSha = $manifest.bundle.sha256
$staging = New-Item -ItemType Directory -Path (Join-Path $env:TEMP ("pointy-update-" + [guid]::NewGuid()))
$zip = Join-Path $staging.FullName "bundle.zip"
try { Invoke-WebRequest -UseBasicParsing -Uri "$relay$bundlePath" -Headers $headers -OutFile $zip }
catch { Report $current "failed" "bundle download failed"; throw }

$actual = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLower()
if ($bundleSha -and ($actual -ne $bundleSha.ToLower())) {
    Report $current "failed" "sha256 mismatch"; throw "sha256 mismatch (want $bundleSha got $actual)"
}
Expand-Archive -Path $zip -DestinationPath (Join-Path $staging.FullName "bundle") -Force
$bundleDir = Get-ChildItem -Path (Join-Path $staging.FullName "bundle") -Directory |
    Where-Object { $_.Name -like "pointy-onprem-*" } | Select-Object -First 1
$bundleDir = if ($bundleDir) { $bundleDir.FullName } else { Join-Path $staging.FullName "bundle" }

# Database backup (best-effort).
New-Item -ItemType Directory -Force -Path "backups" | Out-Null
$backup = "backups/pre-update-$current-to-$assigned.sql"
try { Compose exec -T postgres sh -c 'pg_dump -U "${POSTGRES_USER:-pointy}" "${POSTGRES_DB:-pointy}"' | Out-File -Encoding ascii $backup }
catch { Log "WARN: database backup failed; continuing" }

# Snapshot for rollback.
$snap = New-Item -ItemType Directory -Path (Join-Path $env:TEMP ("pointy-rollback-" + [guid]::NewGuid()))
Copy-Item ".env" (Join-Path $snap.FullName ".env") -Force
if (Test-Path "docker-compose.yml") { Copy-Item "docker-compose.yml" (Join-Path $snap.FullName "docker-compose.yml") -Force }

# Adopt the new bundle's files (keep .env), stage the agent self-update, pin tags.
foreach ($f in @(
        "docker-compose.yml", "install.ps1", "install.sh",
        "watchdog.ps1", "watchdog.sh",
        "register-autostart.ps1", "register-autostart.sh",
        "update.ps1", "update.sh",
        "discovery-responder.ps1", "discovery-responder.py",
        "migrate-fahd.ps1", "migrate-fahd.sh",
        ".env.example", "VERSION.txt", "INSTALL.md", "README.md")) {
    $p = Join-Path $bundleDir $f
    if (Test-Path $p) { Copy-Item $p (Join-Path "." $f) -Force }
}
if (Test-Path (Join-Path $bundleDir "images")) {
    Remove-Item -Recurse -Force "images" -ErrorAction SilentlyContinue
    Copy-Item (Join-Path $bundleDir "images") "images" -Recurse -Force
}
# Refresh bundled client installers so a backend update also updates the LAN clients.
if (Test-Path (Join-Path $bundleDir "clients")) {
    Remove-Item -Recurse -Force "clients" -ErrorAction SilentlyContinue
    Copy-Item (Join-Path $bundleDir "clients") "clients" -Recurse -Force
}
if (Test-Path (Join-Path $bundleDir "update-agent.ps1")) { Copy-Item (Join-Path $bundleDir "update-agent.ps1") "update-agent.ps1.new" -Force }
if (Test-Path (Join-Path $bundleDir "update-agent.sh")) { Copy-Item (Join-Path $bundleDir "update-agent.sh") "update-agent.sh" -Force }

$envText = Get-Content ".env"
$envText = $envText -replace "^POINTY_BACKEND_IMAGE=.*", "POINTY_BACKEND_IMAGE=pointy-backend:$assigned"
$envText = $envText -replace "^POINTY_RELAY_IMAGE=.*", "POINTY_RELAY_IMAGE=pointy-relay:$assigned"
$envText = $envText -replace "^POINTY_WEB_IMAGE=.*", "POINTY_WEB_IMAGE=pointy-web:$assigned"
Set-Content ".env" $envText -Encoding UTF8

Log "applying $assigned ..."
$applied = $false
try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\install.ps1"
    if ($LASTEXITCODE -eq 0 -and (Healthy)) { $applied = $true }
} catch { $applied = $false }

if ($applied) {
    Set-Content "VERSION.txt" $assigned -Encoding UTF8
    # Re-register autostart so tasks the new bundle ships (watchdog, discovery
    # responder, this agent) are installed hands-off. The scheduled task runs
    # elevated, so this normally just works; idempotent either way.
    try { & (Join-Path $PSScriptRoot "register-autostart.ps1") }
    catch { Log "WARN: autostart re-registration failed: $($_.Exception.Message)" }
    Report $assigned "succeeded" ""
    Log "updated to $assigned"
    exit 0
}

Log "update to $assigned failed; rolling back to $current"
Copy-Item (Join-Path $snap.FullName ".env") ".env" -Force
if (Test-Path (Join-Path $snap.FullName "docker-compose.yml")) { Copy-Item (Join-Path $snap.FullName "docker-compose.yml") "docker-compose.yml" -Force }
Compose up -d --remove-orphans
if (Healthy) { Report $current "failed" "update to $assigned failed; rolled back"; throw "update failed; rolled back to $current" }
Report $current "failed" "update to $assigned failed AND rollback unhealthy"
throw "update to $assigned failed and rollback is unhealthy - manual intervention needed"
