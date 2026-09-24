#!/usr/bin/env pwsh
#
# Tests for the Windows half of the on-prem install.
#
# The bash suite covers everything that happens inside the distro. This covers
# the part that decides WHETHER THE DISTRO EVER EXISTS - and that code cannot be
# reasoned about safely, because its whole job is handling the ways Windows
# lies: an installer that reports failure after installing, a mutex held by
# Windows Update, a reboot that has to happen first.
#
#   pwsh deploy/onprem/wsl/tests/run-tests.ps1
$ErrorActionPreference = "Stop"
$pass = 0; $fail = 0; $failed = @()

function Case {
    param([string]$Name, [int]$ExpectExit, [string[]]$Expect = @(), [string[]]$Reject = @())
    $log = [IO.Path]::GetTempFileName()
    $env:POINTY_TEST_LOG = $log
    & (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $PSScriptRoot "case.ps1") -Name $Name *> $null
    $code = $LASTEXITCODE
    $text = if (Test-Path $log) { Get-Content -Raw $log } else { "" }
    Remove-Item $log -ErrorAction SilentlyContinue
    $problems = @()
    if ($code -ne $ExpectExit) { $problems += "exit ${code}, expected ${ExpectExit}" }
    foreach ($e in $Expect) { if ($text -notlike "*$e*") { $problems += "missing '${e}'" } }
    foreach ($r in $Reject) { if ($text -like  "*$r*") { $problems += "should not contain '${r}'" } }
    if ($problems.Count) {
        $script:fail++; $script:failed += $Name
        Write-Host ("FAIL {0}" -f $Name) -ForegroundColor Red
        $problems | ForEach-Object { Write-Host "       $_" -ForegroundColor Red }
        if ($env:VERBOSE) { Write-Host $text }
    } else { $script:pass++; Write-Host ("ok   {0}" -f $Name) -ForegroundColor Green }
}

Write-Host "# bootstrap-wsl.ps1 : Install-Wsl"

# A machine that already has working WSL must be left completely alone.
# Reinstalling over a good WSL is how a working shop gets broken.
Case -Name "already-working" -ExpectExit 0 `
     -Expect @("already present and working", "MARKER: msiexec-calls=0")

# THE BUG FROM THE SHOP. Windows Installer is single-threaded machine-wide, so
# the DISM feature-enable we just ran (or Windows Update) makes msiexec return
# 1618 instantly. It must retry, not die.
Case -Name "installer-busy-then-succeeds" -ExpectExit 0 `
     -Expect @("Windows Installer is busy", "MARKER: msiexec-calls=3", "MARKER: returned-normally") `
     -Reject @("ERROR:")

# msiexec says it failed; the machine disagrees. The outcome wins.
Case -Name "odd-exit-code-but-wsl-works" -ExpectExit 0 `
     -Expect @("returned 1603, but WSL works", "MARKER: returned-normally") `
     -Reject @("ERROR:")

# Installed, but not usable until a reboot. Exit 2 and say so - never pretend
# to continue into wsl --import, which would fail with an opaque HCS error.
Case -Name "reboot-required" -ExpectExit 2 `
     -Expect @("needs a REBOOT")

# A real failure must still be a failure, and must name the log to look in.
Case -Name "genuinely-broken" -ExpectExit 1 `
     -Expect @("ERROR:", "still does not run")

# No bundled MSI and no internet: say exactly what to put next to the script.
Case -Name "no-msi-no-internet" -ExpectExit 1 `
     -Expect @("ERROR:", "wsl.<version>.x64.msi")

# The LAN bridge suite runs in-process (no `exit` paths), so it is its own file.
Write-Host ""
& (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $PSScriptRoot "bridge.ps1")
if ($LASTEXITCODE -ne 0) { $fail++; $failed += "LAN bridge" }

Write-Host ""
& (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $PSScriptRoot "diagnostics.ps1")
if ($LASTEXITCODE -ne 0) { $fail++; $failed += "diagnostics" }

Write-Host ""
if ($fail -gt 0) {
    Write-Host ("# bootstrap-wsl: {0} passed, {1} failed -> {2}" -f $pass, $fail, ($failed -join ", ")) -ForegroundColor Red
    exit 1
}
Write-Host ("# bootstrap-wsl: {0} passed, 0 failed" -f $pass) -ForegroundColor Green
