<#
  Pointy on-prem manual updater (Windows hosts).

  Applies a newer release bundle to THIS deployment — same safety rails as the
  remote update agent (database backup, config snapshot, health check,
  automatic rollback), but fed from a bundle you carry to the machine instead
  of one assigned by the relay. Use it for shops without internet/relay, or to
  update on your own schedule:

      powershell -ExecutionPolicy Bypass -File .\update.ps1 C:\path\pointy-onprem-1.5.0.zip
      powershell -ExecutionPolicy Bypass -File .\update.ps1 C:\path\pointy-onprem-1.5.0\

  Run it from the CURRENT deploy directory (next to docker-compose.yml + .env).
  Data (.env, volumes, backups) is preserved; only images + scripts change.
  Re-applying the already-installed version needs -Force.
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Bundle,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

function Write-Log($message) {
    Write-Host "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') [pointy-update] $message"
}
function Fail($message) { Write-Log "ERROR: $message"; exit 1 }

if (-not (Test-Path $Bundle)) { Fail "bundle not found: $Bundle" }
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { Fail "docker not found on PATH" }
if (-not (Test-Path ".env")) { Fail ".env not found next to this script - run from the deploy directory" }

$currentVersion = "unknown"
if (Test-Path "VERSION.txt") { $currentVersion = (Get-Content "VERSION.txt" -Raw).Trim() }

function Test-Healthy {
    for ($i = 0; $i -lt 60; $i++) {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:8000/readyz/" -TimeoutSec 5 | Out-Null
            return $true
        } catch {
            Start-Sleep -Seconds 5
        }
    }
    return $false
}

# 1. Stage the bundle (accept a zip or an already-extracted directory).
$staging = $null
if (Test-Path $Bundle -PathType Container) {
    $bundleDir = $Bundle
} else {
    $staging = Join-Path ([System.IO.Path]::GetTempPath()) ("pointy-update-" + [Guid]::NewGuid().ToString("n"))
    Write-Log "extracting $(Split-Path $Bundle -Leaf)..."
    Expand-Archive -Path $Bundle -DestinationPath $staging -Force
    $bundleDir = Get-ChildItem $staging -Directory -Filter "pointy-onprem-*" | Select-Object -First 1 -ExpandProperty FullName
    if (-not $bundleDir) { $bundleDir = $staging }
}
if (-not (Test-Path (Join-Path $bundleDir "images"))) { Fail "not a Pointy bundle: no images/ directory in $bundleDir" }
$assigned = "unknown"
$bundleVersionFile = Join-Path $bundleDir "VERSION.txt"
if (Test-Path $bundleVersionFile) { $assigned = (Get-Content $bundleVersionFile -Raw).Trim() }
if (($assigned -eq $currentVersion) -and (-not $Force)) {
    Fail "already on $currentVersion; pass -Force to re-apply"
}
Write-Log "updating $currentVersion -> $assigned"

# 2. Back up the database before any migration runs (best-effort).
New-Item -ItemType Directory -Force -Path "backups" | Out-Null
$backup = "backups\pre-update-$currentVersion-to-$assigned.sql"
try {
    docker compose --env-file .env -f docker-compose.yml exec -T postgres sh -c 'pg_dump -U "${POSTGRES_USER:-pointy}" "${POSTGRES_DB:-pointy}"' | Set-Content -Path $backup -Encoding UTF8
    Write-Log "database backed up to $backup"
} catch {
    Remove-Item -Path $backup -ErrorAction SilentlyContinue
    Write-Log "WARN: database backup failed (stack down?); continuing - rollback restores images, not data"
}

# 3. Snapshot the current config for rollback (old images stay loaded in Docker).
$snapshot = Join-Path ([System.IO.Path]::GetTempPath()) ("pointy-snapshot-" + [Guid]::NewGuid().ToString("n"))
New-Item -ItemType Directory -Force -Path $snapshot | Out-Null
Copy-Item ".env" (Join-Path $snapshot ".env")
if (Test-Path "docker-compose.yml") { Copy-Item "docker-compose.yml" (Join-Path $snapshot "docker-compose.yml") }

# 4. Apply: adopt the new bundle's files (keeping .env + volumes), pin the new
# image tags, then run the bundle's own installer (docker load + compose up).
$adopt = @(
    "docker-compose.yml", "install.sh", "install.ps1", "watchdog.sh", "watchdog.ps1",
    "register-autostart.sh", "register-autostart.ps1",
    "update.sh", "update-agent.sh", "update-agent.ps1",
    "discovery-responder.py", "discovery-responder.ps1",
    "migrate-fahd.sh", "migrate-fahd.ps1",
    ".env.example", "VERSION.txt", "INSTALL.md", "README.md"
)
foreach ($file in $adopt) {
    $sourceFile = Join-Path $bundleDir $file
    if (Test-Path $sourceFile) { Copy-Item -Force $sourceFile ".\$file" }
}
# This script itself is running: stage its next version for the next invocation.
$newSelf = Join-Path $bundleDir "update.ps1"
if (Test-Path $newSelf) { Copy-Item -Force $newSelf ".\update.ps1.new" }
if (Test-Path "images") { Remove-Item -Recurse -Force "images" }
Copy-Item -Recurse (Join-Path $bundleDir "images") ".\images"
if (Test-Path (Join-Path $bundleDir "clients")) {
    if (Test-Path "clients") { Remove-Item -Recurse -Force "clients" }
    Copy-Item -Recurse (Join-Path $bundleDir "clients") ".\clients"
}

$envText = Get-Content ".env" -Raw
$envText = $envText -replace "(?m)^POINTY_BACKEND_IMAGE=.*$", "POINTY_BACKEND_IMAGE=pointy-backend:$assigned"
$envText = $envText -replace "(?m)^POINTY_RELAY_IMAGE=.*$", "POINTY_RELAY_IMAGE=pointy-relay:$assigned"
$envText = $envText -replace "(?m)^POINTY_WEB_IMAGE=.*$", "POINTY_WEB_IMAGE=pointy-web:$assigned"
Set-Content ".env" $envText -Encoding UTF8

Write-Log "applying $assigned..."
$applied = $false
try {
    powershell -NoProfile -ExecutionPolicy Bypass -File ".\install.ps1"
    if ($LASTEXITCODE -eq 0 -and (Test-Healthy)) { $applied = $true }
} catch {
    Write-Log "installer failed: $($_.Exception.Message)"
}

if ($applied) {
    Set-Content "VERSION.txt" $assigned -Encoding UTF8
    if (Test-Path ".\update.ps1.new") { Move-Item -Force ".\update.ps1.new" ".\update.ps1" }
    if ($staging) { Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue }
    # Re-register autostart so tasks the new bundle ships (watchdog, update
    # agent, LAN discovery responder) are installed without anyone having to
    # remember it. Idempotent; needs elevation.
    $isAdmin = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
      ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
    if ($isAdmin) {
        Write-Log "re-registering autostart tasks..."
        try { & (Join-Path $PSScriptRoot "register-autostart.ps1") }
        catch { Write-Log "WARN: autostart registration failed: $($_.Exception.Message)" }
    } else {
        Write-Log "NOTE: not elevated - run register-autostart.ps1 once from an elevated"
        Write-Log "      PowerShell so tasks added by this update are registered."
    }
    Write-Log "updated to $assigned"
    exit 0
}

# 5. Roll back: restore the previous config and bring the old images back up.
Write-Log "update to $assigned failed health check; rolling back to $currentVersion"
Copy-Item -Force (Join-Path $snapshot ".env") ".env"
$snapshotCompose = Join-Path $snapshot "docker-compose.yml"
if (Test-Path $snapshotCompose) { Copy-Item -Force $snapshotCompose "docker-compose.yml" }
docker compose --env-file .env -f docker-compose.yml up -d --remove-orphans
if ($staging) { Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue }
if (Test-Healthy) {
    Fail "update to $assigned failed; rolled back to $currentVersion"
}
Fail "update to $assigned failed and rollback is unhealthy - manual intervention needed"
