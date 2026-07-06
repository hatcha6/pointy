<#
  Fixes the "backend goes down every N minutes" outages on an existing
  Pointy on-prem install (Windows / Docker Desktop).

  ROOT CAUSE — not the watchdog. The backend's ASGI workers were configured
  to self-terminate after 1000 requests (POINTY_ASGI_MAX_REQUESTS=1000).
  Steady polling from the tills drives all workers to that limit at nearly the
  same moment, so the whole API dies together and stays down for the length of
  a Django cold start — at fixed wall-clock intervals. When the gap dragged
  on, the container was also flagged unhealthy and restarted (by design).
  The watchdog is what BRINGS THE STACK BACK after reboots/power cuts — keep
  it; to disable it anyway, use disable-watchdog.ps1.

  This script:
    1. sets POINTY_ASGI_MAX_REQUESTS=0 (and its jitter) in .env — recycling off,
    2. recreates the backend container so the change takes effect,
    3. shows how to confirm the diagnosis from the old logs.

  Run from the bundle directory (next to docker-compose.yml):
      powershell -ExecutionPolicy Bypass -File .\fix-backend-outages.ps1
#>
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

function Log($m) { Write-Host ("{0} [pointy-fix] {1}" -f (Get-Date -Format s), $m) }

if (-not (Test-Path ".env")) { throw ".env not found next to this script." }

# --- 1. Pin recycling off in .env (add the keys if they are missing). -------
$envLines = Get-Content ".env"
$keys = @{
    "POINTY_ASGI_MAX_REQUESTS"        = "0"
    "POINTY_ASGI_MAX_REQUESTS_JITTER" = "0"
}
foreach ($key in $keys.Keys) {
    $value = $keys[$key]
    if ($envLines -match "^$key=") {
        $envLines = $envLines -replace "^$key=.*", "$key=$value"
        Log "set $key=$value"
    } else {
        $envLines += "$key=$value"
        Log "added $key=$value"
    }
}
Set-Content ".env" $envLines -Encoding UTF8

# --- 2. Show the proof in the CURRENT logs before restarting. ---------------
Log "checking the old logs for the worker-recycle signature..."
$signature = docker compose --env-file .env -f docker-compose.yml logs backend --tail 2000 2>$null |
    Select-String "Maximum request limit"
if ($signature) {
    Log ("CONFIRMED: found {0} worker-recycle event(s) in the recent backend logs." -f $signature.Count)
} else {
    Log "no recycle lines in the recent log window (they may have rotated out) — the fix applies either way."
}

# --- 3. Recreate the backend with the new setting. ---------------------------
Log "recreating the backend container..."
docker compose --env-file .env -f docker-compose.yml up -d backend
if ($LASTEXITCODE -ne 0) { throw "docker compose up failed" }

Log "waiting for the backend to come back..."
$healthy = $false
for ($i = 0; $i -lt 36; $i++) {
    try {
        Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:8000/readyz/" -TimeoutSec 5 | Out-Null
        $healthy = $true; break
    } catch { Start-Sleep -Seconds 5 }
}
if (-not $healthy) { throw "backend did not become ready within 3 minutes — check 'docker compose logs backend'." }

Log "done. Workers no longer self-terminate; the interval outages stop here."
Log "The watchdog task stays enabled (it is the reboot/power-cut recovery)."
