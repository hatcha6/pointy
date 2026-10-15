# Exit codes under Windows PowerShell 5.1, the shell every Pointy task runs.
#
# The rest of this suite runs under pwsh on Linux, where Start-Process keeps a
# child's exit code. Windows PowerShell 5.1 does not unless the handle was
# opened before the child exited, so a shop's supervisor read `$null` from every
# successful `wsl --list` and logged "WSL is not answering" on every boot for
# weeks. This file runs on a Windows runner under powershell.exe.
#
#   powershell -NoProfile -File deploy/onprem/wsl/tests/native-exitcode.ps1
$ErrorActionPreference = "Stop"
$fail = 0

foreach ($name in @("bootstrap-wsl.ps1", "keep-pointy-running.ps1")) {
    $path = Join-Path (Split-Path $PSScriptRoot -Parent) $name
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
    $wanted = @("ConvertTo-NativeArgument", "Invoke-NativeTimeout")
    $defs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                           $wanted -contains $n.Name }, $false)
    if (@($defs).Count -ne $wanted.Count) { throw "${name}: expected $($wanted -join ', ')" }
    foreach ($d in $defs) { . ([scriptblock]::Create($d.Extent.Text)) }

    $cases = @(
        @{ Args = @("/d", "/c", "echo Pointy"); Code = 0; Output = "*Pointy*" },
        @{ Args = @("/d", "/c", "exit 3");      Code = 3; Output = "*" }
    )
    foreach ($c in $cases) {
        $r = Invoke-NativeTimeout -File "cmd.exe" -Arguments $c.Args -TimeoutSec 30
        $label = "{0}: cmd {1}" -f $name, ($c.Args -join " ")
        if ($r.ExitCode -eq $c.Code -and $r.Output -like $c.Output) {
            Write-Host "ok   $label -> exit $($r.ExitCode)" -ForegroundColor Green
        } else {
            $fail++
            Write-Host "FAIL $label -> exit '$($r.ExitCode)', expected $($c.Code); output: $($r.Output)" -ForegroundColor Red
        }
    }
}

Write-Host ("PowerShell {0}" -f $PSVersionTable.PSVersion)
if ($fail) { exit 1 }
