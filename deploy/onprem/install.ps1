<#
  Pointy on-prem installer (Windows hosts with Docker Desktop).

  Run this from inside an extracted release bundle. It loads the bundled Docker
  images (so the host never has to pull from a registry) and starts the stack.
  Re-run it any time — it is idempotent.

      powershell -ExecutionPolicy Bypass -File .\install.ps1
#>
$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "Docker Desktop is not installed or not on PATH. Install it and enable Linux containers."
}
try { docker info | Out-Null } catch {
    throw "Docker daemon is not reachable. Start Docker Desktop and try again."
}

Write-Host "==> Loading Pointy container images (this can take a minute)..."
$images = Get-ChildItem -Path "images" -Filter *.tar -ErrorAction SilentlyContinue
if (-not $images) {
    throw "No image archives found under .\images. Is this a complete bundle?"
}
foreach ($img in $images) {
    Write-Host "    - $($img.Name)"
    docker load -i $img.FullName
}

if (-not (Test-Path ".env")) {
    Copy-Item ".env.example" ".env"
    Write-Host ""
    Write-Host "A fresh .env was created from .env.example." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  >> Edit .env now: set the LAN IP, database/Redis passwords, Django"
    Write-Host "     secret, and relay settings. Replace every 'replace-with-...'"
    Write-Host "     placeholder, and point the backup drives at real Windows folders. <<"
    Write-Host ""
    Write-Host "Then re-run .\install.ps1 to start the stack."
    exit 0
}

Write-Host "==> Starting the Pointy stack..."
docker compose --env-file .env -f docker-compose.yml up -d

# Register the boot/crash watchdog so the till self-recovers with no operator.
# Needs elevation; fall back to a printed instruction if not admin.
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
  ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if ($isAdmin) {
    Write-Host "==> Registering reboot/crash watchdog (Scheduled Task)..."
    try { & (Join-Path $PSScriptRoot "register-autostart.ps1") }
    catch { Write-Warning "Watchdog registration failed: $($_.Exception.Message)" }
} else {
    Write-Host "==> To make the stack survive reboots/crashes, run ONCE in an" -ForegroundColor Yellow
    Write-Host "    elevated PowerShell:"
    Write-Host "      powershell -ExecutionPolicy Bypass -File .\register-autostart.ps1"
}

Write-Host ""
Write-Host "Done. Useful follow-ups:"
Write-Host "  Status : docker compose --env-file .env -f docker-compose.yml ps"
Write-Host "  Logs   : docker compose --env-file .env -f docker-compose.yml logs -f backend"
Write-Host "  Health : curl http://127.0.0.1:8000/healthz/   (web alive)"
Write-Host "           curl http://127.0.0.1:8000/readyz/    (web + database + Redis)"
Write-Host ""
Write-Host "Resilience: every service uses 'restart: always', and the watchdog re-runs"
Write-Host "the stack at logon + every 5 min. For unattended reboots, enable Windows"
Write-Host "automatic logon for this user (Docker Desktop only runs in a logged-in"
Write-Host "session). See INSTALL.md > Resilience."
