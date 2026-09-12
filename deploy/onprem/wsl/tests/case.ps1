# One scenario, one process - Install-Wsl can end in `exit`, which no in-process
# assertion would survive.
param([Parameter(Mandatory)][string]$Name)
. "$PSScriptRoot/lib.ps1"

$script:MsiMakesItWork = $true
switch ($Name) {
    "already-working" {
        $script:WslReady = $true
    }
    "installer-busy-then-succeeds" {
        # 1618 = another install in progress. This is the one that made the
        # bootstrap fail on the first run and pass on the second.
        $script:MsiQueue.Enqueue(1618); $script:MsiQueue.Enqueue(1618); $script:MsiQueue.Enqueue(0)
    }
    "odd-exit-code-but-wsl-works" {
        $script:MsiQueue.Enqueue(1603)     # "fatal error during installation"
        $script:MsiMakesItWork = $true
        # 1603 is not treated as success, so force the post-check to find WSL up.
        $script:WslReady = $false
    }
    "reboot-required" {
        $script:MsiQueue.Enqueue(3010); $script:MsiMakesItWork = $false
    }
    "genuinely-broken" {
        $script:MsiQueue.Enqueue(1603); $script:MsiMakesItWork = $false
    }
    "no-msi-no-internet" {
        $script:MsiPresent = $false; $script:UpdateRc = 1; $script:MsiMakesItWork = $false
    }
    default { throw "unknown scenario $Name" }
}
if ($Name -eq "odd-exit-code-but-wsl-works") {
    # msiexec reports failure, yet the machine ends up with working WSL.
    function Invoke-Native { param([string]$File, [string[]]$Arguments)
        [void]$script:NativeLog.Add("$File $($Arguments -join ' ')")
        if ($File -eq "msiexec.exe") { $script:WslReady = $true
            return [pscustomobject]@{ ExitCode = 1603; Output = "" } }
        return [pscustomobject]@{ ExitCode = 0; Output = "" } }
}

Install-Wsl
Add-Content -Path $env:POINTY_TEST_LOG -Value "MARKER: returned-normally"
Add-Content -Path $env:POINTY_TEST_LOG -Value "MARKER: msiexec-calls=$(msiexecCalls)"
exit 0
