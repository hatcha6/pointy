<#
  Pointy on-prem installer (Windows hosts with Docker Desktop).

  Run this from inside an extracted release bundle. If Docker Desktop isn't
  installed it installs it automatically (run elevated), then loads the bundled
  Docker images (so the host never has to pull from a registry) and starts the
  stack. Re-run it any time — it is idempotent.

      powershell -ExecutionPolicy Bypass -File .\install.ps1
#>
$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

function Test-DockerReady {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return $false }
    try { docker info *> $null } catch { return $false }
    return ($LASTEXITCODE -eq 0)
}

# Installs Docker Desktop (latest) when it's missing so a fresh shop only has to
# run this one script. Prefers winget; falls back to the official installer.
function Install-DockerDesktop {
    Write-Host "==> Docker Desktop not found; installing it automatically..."
    $isAdmin = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
      ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
    if (-not $isAdmin) {
        throw "Docker Desktop isn't installed. Re-run this script in an ELEVATED (Administrator) PowerShell so it can be installed automatically."
    }
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "    Installing via winget (Docker.DockerDesktop)..."
        winget install --id Docker.DockerDesktop --exact --silent `
            --accept-package-agreements --accept-source-agreements
    } else {
        $url = "https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe"
        $installer = Join-Path $env:TEMP "DockerDesktopInstaller.exe"
        Write-Host "    Downloading Docker Desktop installer..."
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $installer
        Write-Host "    Running the installer (quiet)..."
        Start-Process -Wait -FilePath $installer -ArgumentList @("install", "--quiet", "--accept-license")
        Remove-Item $installer -ErrorAction SilentlyContinue
    }
    # Make docker visible in THIS session, then start Docker Desktop.
    $dockerBin = Join-Path $env:ProgramFiles "Docker\Docker\resources\bin"
    if (Test-Path $dockerBin) { $env:Path = "$env:Path;$dockerBin" }
    $desktop = Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe"
    if (Test-Path $desktop) { Start-Process -FilePath $desktop | Out-Null }
    Write-Host "    Docker Desktop installed. It may need a one-time sign-out or reboot to finish."
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Install-DockerDesktop
} elseif (-not (Test-DockerReady)) {
    # Installed but not running — start Docker Desktop (best-effort).
    $desktop = Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe"
    if (Test-Path $desktop) { Start-Process -FilePath $desktop | Out-Null }
}

Write-Host "==> Waiting for the Docker daemon..."
$dockerReady = $false
for ($i = 0; $i -lt 60; $i++) {
    if (Test-DockerReady) { $dockerReady = $true; break }
    Start-Sleep -Seconds 5
}
if (-not $dockerReady) {
    throw "Docker isn't running yet. If it was just installed, sign out/reboot to finish setup, then re-run .\install.ps1."
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
    # LICENSING TEMPORARILY OFF ("for now"): on-prem installs don't require a
    # license key, so a shop with no internet can run fully offline. The license
    # gate unlocks by redeeming the key with the relay *online* - which an offline
    # shop can never reach - so requiring it would brick the till. If a license.key
    # is present we still record it, so re-enabling licensing later (set
    # POINTY_REQUIRE_LICENSE=true once the shop has internet) enrolls without a
    # reinstall. To restore enforcement: make the file required again (exit 1) and
    # set POINTY_REQUIRE_LICENSE "true" below.
    $licenseFile = if ($env:POINTY_LICENSE_FILE) { $env:POINTY_LICENSE_FILE } else { "license.key" }
    $licenseKey = ""
    if (Test-Path $licenseFile) {
        $licenseKey = (Get-Content $licenseFile -Raw).Trim()
    } else {
        Write-Warning "No license key at .\$licenseFile - installing without a license (offline mode)."
    }

    Copy-Item ".env.example" ".env"

    function Set-EnvVar([string]$Key, [string]$Value) {
        $pattern = "^$([regex]::Escape($Key))="
        $lines = Get-Content ".env"
        if ($lines -match $pattern) {
            ($lines | ForEach-Object { if ($_ -match $pattern) { "$Key=$Value" } else { $_ } }) |
                Set-Content ".env"
        } else {
            Add-Content ".env" "$Key=$Value"
        }
    }

    function New-Secret([int]$Bytes) {
        $buffer = New-Object 'System.Byte[]' $Bytes
        [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($buffer)
        ($buffer | ForEach-Object { $_.ToString("x2") }) -join ""
    }

    $pgPassword = New-Secret 24
    Set-EnvVar "POINTY_POSTGRES_PASSWORD" $pgPassword
    Set-EnvVar "POINTY_DATABASE_URL" "postgres://pointy:$pgPassword@postgres:5432/pointy"
    Set-EnvVar "DJANGO_SECRET_KEY" (New-Secret 48)
    Set-EnvVar "POINTY_RELAY_CONNECTOR_SETUP_TOKEN" (New-Secret 24)
    Set-EnvVar "POINTY_RELAY_ENROLLMENT_TOKEN" $licenseKey
    Set-EnvVar "POINTY_REQUIRE_LICENSE" "false"

    Write-Host "==> Created .env: generated local secrets (licensing off - offline install)." -ForegroundColor Green
}

Write-Host "==> Starting the Pointy stack..."
docker compose --env-file .env -f docker-compose.yml up -d

# Publish the bundled client installers into the volume Django serves on the LAN.
if (Test-Path "clients") {
    Write-Host "==> Publishing client installers for LAN download..."
    try {
        docker compose --env-file .env -f docker-compose.yml cp clients/. backend:/var/lib/pointy/clients/
        docker compose --env-file .env -f docker-compose.yml exec -u 0 -T backend chmod -R a+rX /var/lib/pointy/clients 2>$null
    } catch {
        Write-Warning "Could not publish client installers; re-run .\install.ps1 once the backend is up."
    }
}

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
