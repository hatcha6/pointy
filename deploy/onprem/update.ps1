<#
  Pointy on-prem manual updater (Windows hosts).

  Applies a newer release bundle to THIS deployment. By default it is a LIVE
  update: the new backend is started alongside the one serving customers, runs
  its migrations, has to pass /readyz, and only then takes traffic — so you can
  update a shop in the middle of the trading day without closing a till. Use it
  for shops without internet/relay, or to update on your own schedule:

      powershell -ExecutionPolicy Bypass -File .\update.ps1 C:\path\pointy-onprem-1.5.0.zip
      powershell -ExecutionPolicy Bypass -File .\update.ps1 C:\path\pointy-onprem-1.5.0\

  Options:
      -Restart   apply the old way — stop the whole stack and bring it back on
                 the new images. Only for a maintenance window; the tills are
                 offline for the length of a full restart.
      -Force     re-apply the version that is already installed.

  Run it from the CURRENT deploy directory (next to docker-compose.yml + .env).
  Data (.env, volumes, backups) is preserved; only images + scripts change.

  What a live update deliberately does NOT touch: the database, the cache, the
  connection pooler and the LAN front door. Their new images ship in the bundle
  and install at the next full restart (install.ps1), because replacing them
  means recreating them — the one thing that cannot be done under a trading shop.
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Bundle,
    [switch]$Restart,
    [switch]$Live,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

# Install any script staged by a previous update before doing anything else:
# Windows can refuse to overwrite a .ps1 that PowerShell has open, so updates
# stage these as <name>.new and the next run promotes them.
foreach ($self in @("update.ps1", "update-agent.ps1", "update-lib.ps1")) {
    if (Test-Path "$self.new") { Move-Item -Force "$self.new" $self }
}

$script:PointyLogTag = "pointy-update"
. .\update-lib.ps1

function Fail($message) { Write-PointyLog "ERROR: $message"; exit 1 }

if (-not (Test-Path $Bundle)) { Fail "bundle not found: $Bundle" }
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { Fail "docker not found on PATH" }
if (-not (Test-Path ".env")) { Fail ".env not found next to this script - run from the deploy directory" }

$mode = "auto"
if ($Restart) { $mode = "restart" }
if ($Live) { $mode = "live" }

if (-not (Get-PointyUpdateLock)) { exit 1 }

$staged = $null
try {
    $staged = Expand-PointyBundle $Bundle
    $current = Get-PointyCurrentVersion
    if ($staged.Version -eq $current -and -not $Force) {
        Fail "already on $current; pass -Force to re-apply"
    }
    if (Invoke-PointyApplyBundle $staged.Dir $current $staged.Version $mode) { exit 0 }
    exit 1
} finally {
    if ($staged -and $staged.Staging) {
        Remove-Item -Recurse -Force $staged.Staging -ErrorAction SilentlyContinue
    }
    Remove-PointyUpdateLock
}
