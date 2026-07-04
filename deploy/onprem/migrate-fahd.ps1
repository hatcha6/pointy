# One-shot legacy-data migration for a shop coming from Fahd (Access edition).
#
# Prepare the file on a workstation first (both scripts live in the repo):
#   scripts/mdb_to_sqlite.sh db.mdb fahd_data.sqlite
#   scripts/fahd_reconstruct.py fahd_data.sqlite fahd_migration.sqlite
# then bring fahd_migration.sqlite to this machine and run, from the deploy
# directory (next to docker-compose.yml):
#
#   powershell -ExecutionPolicy Bypass -File migrate-fahd.ps1 C:\path\fahd_migration.sqlite            # dry run
#   powershell -ExecutionPolicy Bypass -File migrate-fahd.ps1 C:\path\fahd_migration.sqlite -Import    # real import
#
# The dry run validates everything and writes nothing — read its report first.
# Stock quantities are intentionally NOT transferred (stock=none): the shop
# does a fresh stock count in Pointy afterwards. Re-running is safe (idempotent).
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$DbFile,
    [switch]$Import,
    [ValidateSet("none", "snapshot", "reconstruct")]
    [string]$Stock = "none",
    [switch]$TakeOver
)

$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

function Fail($message) { Write-Error $message; exit 1 }

if (-not (Test-Path $DbFile)) { Fail "File not found: $DbFile" }
if (-not (Test-Path "docker-compose.yml")) { Fail "docker-compose.yml not found - run this from the Pointy deploy directory." }
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { Fail "Docker is not installed." }

$running = docker compose ps --status running backend --quiet 2>$null
if (-not $running) { Fail "The backend container is not running. Start the stack first (install.ps1)." }

$mode = if ($Import) { "import" } else { "dry_run" }
# Stage on a real volume, NOT /tmp: the backend's /tmp is a small tmpfs (64 MB)
# and a real export easily exceeds it.
$containerPath = "/var/lib/pointy/backups/legacy-import.sqlite"

Write-Host "==> Copying $(Split-Path $DbFile -Leaf) into the backend container..."
docker compose cp "$DbFile" "backend:$containerPath"
if ($LASTEXITCODE -ne 0) { Fail "Copy into the container failed." }

Write-Host "==> Running migration ($mode, stock=$Stock)..."
$cliArgs = @(
    "compose", "exec", "-T", "backend",
    "python", "manage.py", "import_legacy",
    "--database", $containerPath,
    "--system", "fahd_sqlite",
    "--mode", $mode,
    "--stock", $Stock
)
if ($TakeOver) { $cliArgs += "--take-over" }
& docker @cliArgs
$migrationExit = $LASTEXITCODE

# Only remove the staged copy after a real import; keep it between a dry run
# and the import so the second run doesn't re-copy the large file.
if ($mode -eq "import") {
    docker compose exec -T backend rm -f $containerPath 2>$null | Out-Null
}
if ($migrationExit -ne 0) { Fail "Migration command failed (exit $migrationExit)." }

Write-Host ""
if ($mode -eq "dry_run") {
    Write-Host "Dry run finished. If the report looks right, run again with -Import:"
    Write-Host "  powershell -ExecutionPolicy Bypass -File migrate-fahd.ps1 $DbFile -Import"
} else {
    Write-Host "Import finished. Next steps:"
    Write-Host "  1. Open the app and scan a few known barcodes (including carton/pack codes)."
    Write-Host "  2. Spot-check a couple of old invoices and purchase bills."
    Write-Host "  3. Run a stock count in Pointy - quantities were intentionally not transferred."
}
