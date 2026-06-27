<#
  Registers the Pointy uptime watchdog as a Windows Scheduled Task so the till
  comes back online by itself after a reboot, crash, or power cut — with no one
  having to log in and start anything.

  Run this ONCE from inside the bundle, in an *elevated* PowerShell:

      powershell -ExecutionPolicy Bypass -File .\register-autostart.ps1

  The task runs watchdog.ps1:
    * at system startup,
    * at user logon, and
    * every 5 minutes thereafter (so a destroyed or wedged container is back
      within minutes even between reboots).

  IMPORTANT — for a truly unattended server you ALSO need (see INSTALL.md):
    1. Windows automatic logon for the POS user (Docker Desktop only runs inside
       a logged-in session), and
    2. Docker Desktop set to start at login.
  This script configures #2 for you and reminds you about #1.
#>
$ErrorActionPreference = "Stop"
$here = $PSScriptRoot
$watchdog = Join-Path $here "watchdog.ps1"
$taskName = "PointyAutostart"

if (-not (Test-Path $watchdog)) { throw "watchdog.ps1 not found next to this script." }

# Require elevation so the task can run with highest privileges and at startup.
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
  ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $isAdmin) {
    throw "Please run this in an elevated (Administrator) PowerShell."
}

Write-Host "==> Registering scheduled task '$taskName'..."

$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$watchdog`"" `
    -WorkingDirectory $here

# Fire at logon, and at startup repeating every 5 minutes indefinitely. (The
# 5-min repetition is attached to the startup trigger via .Repetition, the
# portable way to get a repeating trigger across Windows versions.)
$atStartup = New-ScheduledTaskTrigger -AtStartup
$atStartup.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 5) `
    -RepetitionDuration (New-TimeSpan -Days 3650)).Repetition
$triggers = @(
    (New-ScheduledTaskTrigger -AtLogOn),
    $atStartup
)

# Run as the current (POS) user, with highest privileges, in the interactive
# session where Docker Desktop lives.
$principal = New-ScheduledTaskPrincipal `
    -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType Interactive `
    -RunLevel Highest

# Keep retrying, never time out, survive battery transitions.
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $taskName -Action $action `
    -Trigger $triggers -Principal $principal -Settings $settings -Force | Out-Null

Write-Host "    Registered. Running it once now to bring the stack up..."
Start-ScheduledTask -TaskName $taskName

# Register the remote update agent (pulls + applies the relay-assigned version).
$updateAgent = Join-Path $here "update-agent.ps1"
if (Test-Path $updateAgent) {
    Write-Host "==> Registering scheduled task 'PointyUpdateAgent'..."
    $updateAction = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$updateAgent`"" `
        -WorkingDirectory $here
    # ~2 min after startup, then every 30 minutes.
    $updateStartup = New-ScheduledTaskTrigger -AtStartup
    $updateStartup.Delay = "PT2M"
    $updateStartup.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
            -RepetitionInterval (New-TimeSpan -Minutes 30) `
            -RepetitionDuration (New-TimeSpan -Days 3650)).Repetition
    $updateSettings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName "PointyUpdateAgent" -Action $updateAction `
        -Trigger $updateStartup -Principal $principal -Settings $updateSettings -Force | Out-Null
    Write-Host "    Registered. The update agent runs ~2 min after startup and every 30 minutes."
}

# Configure Docker Desktop to start at login (best effort).
try {
    $settingsPath = Join-Path $env:APPDATA "Docker\settings.json"
    if (Test-Path $settingsPath) {
        $cfg = Get-Content $settingsPath -Raw | ConvertFrom-Json
        $cfg | Add-Member -NotePropertyName "openUIOnStartupDisabled" -NotePropertyValue $true -Force
        $cfg | Add-Member -NotePropertyName "autoStart" -NotePropertyValue $true -Force
        $cfg | ConvertTo-Json -Depth 32 | Set-Content $settingsPath -Encoding UTF8
        Write-Host "    Set Docker Desktop to start at login."
    }
} catch {
    Write-Warning "Could not auto-configure Docker Desktop startup: $($_.Exception.Message)"
}

Write-Host ""
Write-Host "Done. The watchdog now runs at startup, at logon, and every 5 minutes." -ForegroundColor Green
Write-Host ""
Write-Host "ONE MANUAL STEP REMAINS for unattended reboots (e.g. after a power cut):" -ForegroundColor Yellow
Write-Host "  Enable Windows AUTOMATIC LOGON for this POS user, because Docker Desktop"
Write-Host "  only runs inside a logged-in session. Run 'netplwiz', untick"
Write-Host "  'Users must enter a user name and password to use this computer', and"
Write-Host "  enter the password. See INSTALL.md > Resilience for details."
