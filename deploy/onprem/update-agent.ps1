<#
  Pointy on-prem remote update agent (Windows). Mirrors update-agent.sh.

  Polls the relay for the version this installation should run and, when a newer
  one is assigned, downloads the bundle FROM THE RELAY, verifies its sha256,
  backs up the database, applies it, health-checks the result, and rolls back
  automatically on failure. Runs as a Scheduled Task next to the watchdog.

  It applies updates LIVE by default (see update-lib.ps1): the new backend is
  brought up beside the running one and only takes traffic once it has answered
  /readyz, so a shop can be updated in the middle of the trading day without a
  till noticing. That matters most here — this agent fires on a timer, and
  before it could do that safely the only responsible schedule was "after
  hours". Releases that cannot be applied that way say so in the bundle and get
  a full restart instead.

  Use -Check to preview without applying.
#>
param([switch]$Check, [switch]$Restart, [switch]$Live)
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

# Self-update: a bundle stages the new agent as update-agent.ps1.new; promote it
# and re-exec before doing work (never overwrite the running script).
if ((Test-Path "update-agent.ps1.new") -and (-not $env:POINTY_AGENT_PROMOTED)) {
    Move-Item -Force "update-agent.ps1.new" "update-agent.ps1"
    $env:POINTY_AGENT_PROMOTED = "1"
    $forward = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ".\update-agent.ps1")
    if ($Check) { $forward += "-Check" }
    if ($Restart) { $forward += "-Restart" }
    if ($Live) { $forward += "-Live" }
    & powershell.exe @forward
    exit $LASTEXITCODE
}

# The agent's own file is promoted and re-exec'd above; the rest are installed
# here, before update-lib.ps1 is dot-sourced.
foreach ($self in @("update.ps1", "update-lib.ps1")) {
    if (Test-Path "$self.new") { Move-Item -Force "$self.new" $self }
}

$script:PointyLogTag = "pointy-update-agent"
. .\update-lib.ps1

$AgentVersion = "pointy-update-agent/2"
$mode = "auto"
if ($Restart) { $mode = "restart" }
if ($Live) { $mode = "live" }

$relay = (Get-PointyEnvValue "POINTY_RELAY_PUBLIC_API_URL").TrimEnd('/')
if (-not $relay) { throw "POINTY_RELAY_PUBLIC_API_URL is not set in .env" }

$current = Get-PointyCurrentVersion

# Connector token via `docker cp` (works even though the connector image is scratch).
$state = New-TemporaryFile
try { Invoke-Compose cp connector:/var/lib/pointy/relay-connector.json $state.FullName 2>$null } catch {}
if ((-not (Test-Path $state)) -or ((Get-Item $state).Length -eq 0)) {
    Write-PointyLog "connector state unavailable yet; retrying next run"; exit 0
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

try { $manifest = Invoke-RestMethod -Uri "$relay/v1/agent/manifest" -Headers $headers }
catch { Write-PointyLog "manifest fetch failed; retrying next run"; exit 0 }

$directive = $manifest.directive
$assigned = $manifest.assigned_version
if ($directive -ne "apply" -or -not $assigned -or $assigned -eq $current) {
    Write-PointyLog "up to date (current=$current, directive=$directive, assigned=$assigned)"
    Report $current "idle" ""
    exit 0
}
Write-PointyLog "update available: $current -> $assigned"
if ($Check) { Write-PointyLog "-Check: would apply $assigned"; exit 0 }

# Take the update lock before downloading: it also tells the watchdog to keep
# its hands off the stack for the duration.
if (-not (Get-PointyUpdateLock)) { exit 0 }

Report $current "applying" ""

$staging = (New-Item -ItemType Directory -Path (Join-Path $env:TEMP ("pointy-update-" + [guid]::NewGuid()))).FullName
$staged = $null
try {
    $zip = Join-Path $staging "bundle.zip"
    try { Invoke-WebRequest -UseBasicParsing -Uri "$relay$($manifest.bundle.path)" -Headers $headers -OutFile $zip }
    catch { Report $current "failed" "bundle download failed"; throw }

    $expected = $manifest.bundle.sha256
    $actual = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLower()
    if ($expected -and ($actual -ne $expected.ToLower())) {
        Report $current "failed" "sha256 mismatch"
        throw "sha256 mismatch (want $expected got $actual)"
    }

    $staged = Expand-PointyBundle $zip
    if (Invoke-PointyApplyBundle $staged.Dir $current $assigned $mode) {
        Report $assigned "succeeded" ""
        exit 0
    }
    Report (Get-PointyCurrentVersion) "failed" "update to $assigned failed"
    exit 1
} finally {
    if ($staged -and $staged.Staging) { Remove-Item -Recurse -Force $staged.Staging -ErrorAction SilentlyContinue }
    Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue
    Remove-PointyUpdateLock
}
