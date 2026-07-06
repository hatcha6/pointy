<#
  Disables the Pointy uptime watchdog: stops the scheduled task, disables it,
  and removes its boot/logon/5-minute triggers so it never starts again.

  NOTE — the interval outages were NOT caused by the watchdog (see
  fix-backend-outages.ps1: the ASGI workers were self-terminating on a request
  limit; the watchdog only revived the stack afterwards). With the watchdog
  disabled, nothing restarts the stack after a reboot, a power cut, or a
  Docker crash: someone must run `docker compose up -d` by hand. Re-enable at
  any time with:  powershell -File .\register-autostart.ps1

  Usage (elevated PowerShell, from the bundle directory):
      powershell -ExecutionPolicy Bypass -File .\disable-watchdog.ps1
  Also disable the 30-minute remote update agent:
      powershell -ExecutionPolicy Bypass -File .\disable-watchdog.ps1 -IncludeUpdateAgent
  Remove the tasks entirely instead of disabling them:
      powershell -ExecutionPolicy Bypass -File .\disable-watchdog.ps1 -Remove
#>
param(
    [switch]$IncludeUpdateAgent,
    [switch]$Remove
)
$ErrorActionPreference = "Stop"

$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
  ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $isAdmin) { throw "Run this in an elevated (Administrator) PowerShell." }

$tasks = @("PointyAutostart")
if ($IncludeUpdateAgent) { $tasks += "PointyUpdateAgent" }

foreach ($name in $tasks) {
    $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if (-not $task) {
        Write-Host "Task '$name' is not registered — nothing to do."
        continue
    }
    Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if ($Remove) {
        Unregister-ScheduledTask -TaskName $name -Confirm:$false
        Write-Host "Task '$name' stopped and REMOVED."
    } else {
        Disable-ScheduledTask -TaskName $name | Out-Null
        Write-Host "Task '$name' stopped and DISABLED (boot/logon/interval triggers inert)."
    }
}

Write-Host ""
Write-Host "The watchdog no longer runs at boot or on its 5-minute schedule." -ForegroundColor Yellow
Write-Host "Remember: after a reboot or power cut the stack must now be started"
Write-Host "manually:  docker compose --env-file .env -f docker-compose.yml up -d"
Write-Host "Re-enable auto-recovery later with:  powershell -File .\register-autostart.ps1"
