# The supervisor: what keeps a shop's server up with nobody logged in.
#
# WSL powers a distro off ~15 s after its last Windows-side client exits, and
# systemd inside does not count. The old -Boot started the distro and returned,
# which is to say it started it for 15 seconds. These tests pin the loop that
# replaced it: it attaches a keep-alive client, wakes the instant that client
# dies, restarts a distro that stops answering, re-proves the bridge on a
# schedule, and hands over to a newer bootstrap - all without ever exiting on
# a single failure. The loop's dependencies (processes, wsl.exe, the clock)
# are faked, so every cycle here is scripted and deterministic.
. "$PSScriptRoot/lib.ps1"
$pass = 0; $fail = 0
function check([string]$what, [scriptblock]$body) {
    try { $r = & $body; if ($r) { $script:pass++; Write-Host "ok   $what" -ForegroundColor Green }
          else { $script:fail++; Write-Host "FAIL $what" -ForegroundColor Red } }
    catch { $script:fail++; Write-Host "FAIL $what -- $($_.Exception.Message)" -ForegroundColor Red }
}

Write-Host "# bootstrap-wsl.ps1 : supervisor"

# --- the fakes -------------------------------------------------------------
function newProc([int]$Id) { return [pscustomobject]@{ Id = $Id; HasExited = $false } }
$script:Existing = $null                                 # what Get-AnchorProcess finds
$script:NextPid  = 100
$script:Started  = [System.Collections.ArrayList]::new()  # anchors this run started
$script:Killed   = [System.Collections.ArrayList]::new()
$script:DistroVisible = $true
$script:AnswerQueue = [System.Collections.Queue]::new()  # scripted Test-DistroAnswers results
$script:Reconciles = 0
$script:ReconcileThrows = 0
$script:WaitQueue = [System.Collections.Queue]::new()    # scripted waits
$script:Waits = [System.Collections.ArrayList]::new()    # seconds each wait was asked for
$script:Promote = $false
$script:HandedOver = $false
$script:LockReleased = $false
$script:States = [System.Collections.ArrayList]::new()

function Get-AnchorProcess { return $script:Existing }
function Start-AnchorProcess { $p = newProc ($script:NextPid++); [void]$script:Started.Add($p); return $p }
function Stop-ProcessQuietly { param($Process)
    if ($Process) { $Process.HasExited = $true; [void]$script:Killed.Add($Process.Id) } }
function Test-DistroExists { return $script:DistroVisible }
function Test-DistroAnswers { param([int]$TimeoutSec = 60)
    if ($script:AnswerQueue.Count) { return $script:AnswerQueue.Dequeue() }
    return $true }
function Invoke-BootReconcile {
    $script:Reconciles++
    if ($script:ReconcileThrows -gt 0) { $script:ReconcileThrows--; throw "netsh exploded" }
    return $true }
function Wait-AnchorOrInterval { param($Anchor, [int]$Seconds)
    [void]$script:Waits.Add($Seconds)
    if ($script:WaitQueue.Count) {
        $w = $script:WaitQueue.Dequeue()
        if ($w.AnchorExited -and $Anchor) { $Anchor.HasExited = $true }
        return $w
    }
    return [pscustomobject]@{ AnchorExited = $false; Seconds = $Seconds } }
function Update-BootstrapFromGuest { return $script:Promote }
function Start-SupervisorProcess { $script:HandedOver = $true }
function Exit-SupervisorLock { $script:LockReleased = $true }
function Write-SupervisorState { param($Anchor, [bool]$Answering, [int]$Restarts, [datetime]$StartedAt)
    $anchorPid = 0
    if (Test-ProcessAlive $Anchor) { $anchorPid = $Anchor.Id }
    [void]$script:States.Add([pscustomobject]@{ AnchorPid = $anchorPid; Answering = $Answering; Restarts = $Restarts }) }

function reset {
    $script:Existing = $null; $script:NextPid = 100
    $script:Started.Clear(); $script:Killed.Clear(); $script:States.Clear(); $script:Waits.Clear()
    $script:AnswerQueue.Clear(); $script:WaitQueue.Clear()
    $script:DistroVisible = $true; $script:Reconciles = 0; $script:ReconcileThrows = 0
    $script:Promote = $false; $script:HandedOver = $false; $script:LockReleased = $false
    $script:Log.Clear(); $script:NativeLog.Clear(); $script:Slept = 0
}
function wait([bool]$AnchorExited, [int]$Seconds) {
    $script:WaitQueue.Enqueue([pscustomobject]@{ AnchorExited = $AnchorExited; Seconds = $Seconds }) }
function loggedCount([string]$needle) { return @($script:Log | Where-Object { $_ -like "*$needle*" }).Count }

# --- the loop --------------------------------------------------------------

check "at boot: attaches the keep-alive client, proves the bridge, records a heartbeat" {
    reset
    Invoke-Supervise -MaxCycles 1
    ($script:Started.Count -eq 1) -and ($script:Reconciles -eq 1) -and
        ($script:States.Count -eq 1) -and ($script:States[0].AnchorPid -eq 100) -and $script:States[0].Answering -and
        (logged "attached the keep-alive client") -and (logged "supervisor started")
}
check "adopts a client that is already attached rather than starting a second one" {
    reset
    $script:Existing = newProc 55
    Invoke-Supervise -MaxCycles 2
    ($script:Started.Count -eq 0) -and ($script:States[0].AnchorPid -eq 55) -and -not (logged "attached the keep-alive")
}
check "a quiet supervisor re-proves the bridge only when it is due, and sleeps until then" {
    # The clock is the sum of the waits: three 100 s naps make the second
    # reconcile due on the fourth cycle, not before.
    reset
    wait $false 100; wait $false 100; wait $false 100
    Invoke-Supervise -MaxCycles 4
    ($script:Reconciles -eq 2) -and (($script:Waits -join ",") -eq "300,200,100,300")
}
check "THE BUG: the client exiting is noticed at once - the distro is started again and the bridge re-pointed" {
    # wsl --shutdown, a Windows Update servicing WSL, a logoff: the anchor
    # dies, and with it - 15 s later - the distro, unless someone re-attaches.
    reset
    wait $true 40
    Invoke-Supervise -MaxCycles 2
    ($script:Started.Count -eq 2) -and ($script:Reconciles -eq 2) -and
        (logged "keep-alive client exited") -and ($script:States[1].Restarts -eq 1) -and ($script:States[1].AnchorPid -eq 101)
}
check "a distro that stops answering is terminated after three strikes and started fresh, backing off in between" {
    reset
    foreach ($a in @($true, $false, $false, $false, $true)) { $script:AnswerQueue.Enqueue($a) }
    Invoke-Supervise -MaxCycles 5
    (called "wsl.exe --terminate Pointy") -and ($script:Killed.Count -eq 1) -and ($script:Started.Count -eq 2) -and
        ($script:Reconciles -eq 2) -and (($script:Waits -join ",") -eq "300,5,10,20,300") -and
        (logged "3 of 3 before it is restarted") -and ($script:States[3].AnchorPid -eq 0) -and
        ($script:States[4].Restarts -eq 1) -and ($script:States[4].AnchorPid -eq 101)
}
check "one bad answer is a warning, not a restart" {
    reset
    foreach ($a in @($true, $false, $true)) { $script:AnswerQueue.Enqueue($a) }
    Invoke-Supervise -MaxCycles 3
    (-not (called "--terminate")) -and ($script:Killed.Count -eq 0) -and ($script:Started.Count -eq 1) -and
        (logged "1 of 3 before") -and (logged "answers again") -and (($script:Waits -join ",") -eq "300,5,300")
}
check "an unregistered distro is reported once, not every cycle, and nothing is terminated" {
    # The S4U task cannot see a distro that belongs to another user, or one
    # nobody installed. Say so once; keep trying, because a later logon or
    # install changes the answer.
    reset
    $script:DistroVisible = $false
    Invoke-Supervise -MaxCycles 3
    ($script:Started.Count -eq 0) -and ((loggedCount "is not registered") -eq 1) -and
        -not (called "--terminate") -and ($script:Reconciles -eq 0) -and -not $script:States[2].Answering
}
check "a WSL service that is mid-update is outwaited, not reported as a missing distro" {
    reset
    $script:DistroVisible = $false
    $script:WslListError = "wsl --list failed (exit 1): The service cannot be started"
    Invoke-Supervise -MaxCycles 3
    $script:WslListError = ""
    ((loggedCount "WSL is not answering") -eq 1) -and -not (logged "is not registered") -and ($script:Started.Count -eq 0)
}
check "'wsl --list' failing is remembered as WSL's fault, a clean empty list is not" {
    function Invoke-Wsl { param([string[]]$Arguments, [int]$TimeoutSec = 120)
        return [pscustomobject]@{ ExitCode = 1; Output = "The service cannot be started, either because it is disabled`nor because it has no enabled devices." } }
    $failed = @(Get-RegisteredDistros)
    $failedError = $script:WslListError
    function Invoke-Wsl { param([string[]]$Arguments, [int]$TimeoutSec = 120)
        return [pscustomobject]@{ ExitCode = 0; Output = "" } }
    $empty = @(Get-RegisteredDistros)
    $emptyError = $script:WslListError
    ($failed.Count -eq 0) -and ($failedError -like "wsl --list failed (exit 1): The service cannot be started*") -and
        ($empty.Count -eq 0) -and ($emptyError -eq "")
}
check "a newer bootstrap takes over: the lock is released, the new one started, this loop ends" {
    reset
    $script:Promote = $true
    Invoke-Supervise -MaxCycles 5
    $script:HandedOver -and $script:LockReleased -and ($script:Reconciles -eq 1) -and (logged "handing over")
}
check "a handover is only attempted while the distro answers (the check needs a file inside it)" {
    reset
    $script:Promote = $true
    $script:AnswerQueue.Enqueue($false)
    Invoke-Supervise -MaxCycles 1
    -not $script:HandedOver
}
check "a cycle that throws is logged and the next cycle still runs" {
    reset
    $script:ReconcileThrows = 1
    Invoke-Supervise -MaxCycles 2
    (logged "supervisor cycle failed: netsh exploded") -and ($script:Reconciles -eq 2)
}

# --- the pieces the loop stands on -------------------------------------------

check "arguments survive the trip through a rebuilt command line" {
    ((ConvertTo-NativeArgument "plain") -eq "plain") -and
    ((ConvertTo-NativeArgument "has space") -eq '"has space"') -and
    ((ConvertTo-NativeArgument "") -eq '""') -and
    ((ConvertTo-NativeArgument 'say "hi"') -eq '"say \"hi\""') -and
    ((ConvertTo-NativeArgument 'C:\dir\') -eq 'C:\dir\') -and
    ((ConvertTo-NativeArgument 'C:\my dir\') -eq '"C:\my dir\\"') -and
    ((ConvertTo-NativeArgument "cd '/opt/pointy' && test -f x") -eq '"cd ' + "'/opt/pointy'" + ' && test -f x"')
}
$sh = Get-Command sh -ErrorAction SilentlyContinue
if ($sh) {
    check "a bounded native call returns its output" {
        $r = Invoke-NativeTimeout -File $sh.Source -Arguments @("-c", "echo hi there; echo oops >&2; exit 3") -TimeoutSec 20
        ($r.ExitCode -eq 3) -and (-not $r.TimedOut) -and ($r.Output -like "*hi there*") -and ($r.Output -like "*oops*")
    }
    check "a bounded native call that hangs is killed and says so" {
        $r = Invoke-NativeTimeout -File $sh.Source -Arguments @("-c", "sleep 30") -TimeoutSec 1
        $r.TimedOut -and ($r.ExitCode -eq -1) -and ($r.Output -like "timed out after 1s:*")
    }
} else { Write-Host "skip bounded native calls (needs sh)" -ForegroundColor Yellow }

check "the distro is judged alive by what it prints, never by an exit code" {
    # Windows PowerShell 5.1 handed this script a null exit code for every
    # call once; an exit-code check here would then have restarted a healthy
    # distro every three cycles, on every shop.
    . (Get-RealFunction "Test-DistroAnswers")
    function Invoke-Guest { param([string]$Command, [int]$TimeoutSec = 120)
        return [pscustomobject]@{ ExitCode = $script:GuestExit; Output = $script:GuestSays } }
    $script:GuestExit = $null; $script:GuestSays = "pointy-alive"
    $nullCodeButAlive = Test-DistroAnswers
    $script:GuestExit = 0; $script:GuestSays = "p`0o`0i`0n`0t`0y`0-`0a`0l`0i`0v`0e`0"
    $utf16Alive = Test-DistroAnswers
    $script:GuestExit = 0; $script:GuestSays = ""
    $zeroButSilent = Test-DistroAnswers
    $script:GuestExit = 1; $script:GuestSays = "The Windows Subsystem for Linux instance has terminated."
    $dead = Test-DistroAnswers
    $nullCodeButAlive -and $utf16Alive -and (-not $zeroButSilent) -and (-not $dead)
}
check "the heartbeat file carries what the collector reads" {
    $script:SupervisorStateFile = Join-Path ([IO.Path]::GetTempPath()) ("pointy-supervisor-" + [guid]::NewGuid().ToString("N") + ".json")
    # The real writer, not the fake above.
    . (Get-RealFunction "Write-SupervisorState")
    Write-SupervisorState -Anchor (newProc 77) -Answering $true -Restarts 2 -StartedAt (Get-Date).AddHours(-1)
    $state = Get-Content -Raw $script:SupervisorStateFile | ConvertFrom-Json
    Remove-Item $script:SupervisorStateFile -ErrorAction SilentlyContinue
    ($state.supervisor_pid -eq $PID) -and ($state.anchor_pid -eq 77) -and $state.distro_answering -and
        ($state.distro_restarts -eq 2) -and ([datetime]$state.heartbeat_at -gt (Get-Date).AddMinutes(-1))
}

# --- the boot task ----------------------------------------------------------
# Task Scheduler's cmdlets do not exist off Windows; what is pinned here is
# what the bootstrap ASKS of them, which is where the field bugs were.
$script:Registered = $null
$script:TaskState  = $null
$script:TaskStopped = $false
$script:TaskStarted = $false
function New-ScheduledTaskAction { param($Execute, $Argument)
    return [pscustomobject]@{ Execute = $Execute; Argument = $Argument } }
function New-ScheduledTaskTrigger { param([switch]$AtStartup, [switch]$Once, $At, $RepetitionInterval, $RepetitionDuration)
    $kind = "clock"; if ($AtStartup) { $kind = "startup" }
    return [pscustomobject]@{ Kind = $kind; Delay = ""; RepetitionInterval = $RepetitionInterval; RepetitionDuration = $RepetitionDuration } }
function New-ScheduledTaskSettingsSet { param([switch]$AllowStartIfOnBatteries, [switch]$DontStopIfGoingOnBatteries,
        [switch]$StartWhenAvailable, $RestartCount, $RestartInterval, $ExecutionTimeLimit, $MultipleInstances)
    return [pscustomobject]@{ ExecutionTimeLimit = $ExecutionTimeLimit; MultipleInstances = $MultipleInstances
                              StartWhenAvailable = [bool]$StartWhenAvailable; RestartCount = $RestartCount } }
function New-ScheduledTaskPrincipal { param($UserId, $LogonType, $RunLevel)
    return [pscustomobject]@{ UserId = $UserId; LogonType = $LogonType; RunLevel = $RunLevel } }
function Register-ScheduledTask { param($TaskName, $Action, $Trigger, $Principal, $Settings, [switch]$Force, $ErrorAction)
    $script:Registered = [pscustomobject]@{ TaskName = $TaskName; Action = $Action; Triggers = @($Trigger)
                                            Principal = $Principal; Settings = $Settings } }
function Get-ScheduledTask { param($TaskName, $ErrorAction)
    if ($null -eq $script:TaskState) { throw "No MSFT_ScheduledTask objects found with property 'TaskName' equal to '$TaskName'." }
    return [pscustomobject]@{ TaskName = $TaskName; State = $script:TaskState } }
function Stop-ScheduledTask  { param($TaskName, $ErrorAction) $script:TaskStopped = $true }
function Start-ScheduledTask { param($TaskName, $ErrorAction) $script:TaskStarted = $true }

check "the task fires at startup AND on the clock, runs the supervisor, and is never time-limited" {
    $script:Log.Clear()
    Register-BootTask
    $t = $script:Registered
    $kinds = @($t.Triggers | ForEach-Object { $_.Kind }) -join ","
    $clock = @($t.Triggers | Where-Object { $_.Kind -eq "clock" })[0]
    $startup = @($t.Triggers | Where-Object { $_.Kind -eq "startup" })[0]
    ($t.TaskName -eq "PointyWSL") -and ($kinds -eq "startup,clock") -and ($startup.Delay -eq "PT30S") -and
        ($clock.RepetitionInterval -eq (New-TimeSpan -Minutes 5)) -and
        ($t.Action.Argument -like "*-Boot *") -and ($t.Action.Argument -notlike "*-Once*") -and
        ($t.Action.Argument -like '*-File "C:\ProgramData\Pointy\bootstrap-wsl.ps1"*' -or $t.Action.Argument -like "*bootstrap-wsl.ps1*") -and
        ($t.Principal.LogonType -eq "S4U") -and ($t.Principal.RunLevel -eq "Highest") -and
        ($t.Settings.ExecutionTimeLimit -eq [TimeSpan]::Zero) -and ($t.Settings.MultipleInstances -eq "IgnoreNew") -and
        $t.Settings.StartWhenAvailable -and (logged "at startup, and every 5 minutes")
}
check "a running supervisor is stopped before the install, and only then" {
    $script:TaskStopped = $false; $script:TaskState = "Running"
    Stop-BootTask
    $stoppedWhenRunning = $script:TaskStopped
    $script:TaskStopped = $false; $script:TaskState = "Ready"
    Stop-BootTask
    $stoppedWhenReady = $script:TaskStopped
    $script:TaskStopped = $false; $script:TaskState = $null
    Stop-BootTask
    $stoppedWhenAbsent = $script:TaskStopped
    $stoppedWhenRunning -and -not $stoppedWhenReady -and -not $stoppedWhenAbsent
}
check "the supervisor task is started when idle and left alone when running" {
    $script:TaskStarted = $false; $script:TaskState = "Ready"
    $a = Start-SupervisorTask
    $startedWhenReady = $script:TaskStarted
    $script:TaskStarted = $false; $script:TaskState = "Running"
    $b = Start-SupervisorTask
    $startedWhenRunning = $script:TaskStarted
    $script:Log.Clear(); $script:TaskState = $null
    $c = Start-SupervisorTask
    $a -and $b -and (-not $c) -and $startedWhenReady -and -not $startedWhenRunning -and (logged "could not start the 'PointyWSL' task")
}

# --- power ------------------------------------------------------------------
$script:Hiberboot = 1
$script:HiberbootSet = $null
function Get-ItemProperty { param($Path, $Name, $ErrorAction) return [pscustomobject]@{ HiberbootEnabled = $script:Hiberboot } }
function Set-ItemProperty { param($Path, $Name, $Value, $Type, $ErrorAction) $script:HiberbootSet = $Value }

check "the install makes the PC behave like a server: never sleep, never Fast Start" {
    $script:Log.Clear(); $script:NativeLog.Clear(); $script:HiberbootSet = $null; $script:Hiberboot = 1
    Set-ServerPowerSettings
    (called "powercfg.exe /change standby-timeout-ac 0") -and (called "powercfg.exe /change hibernate-timeout-ac 0") -and
        ($script:HiberbootSet -eq 0) -and (logged "Fast Startup off")
}
check "Fast Startup already off is left alone" {
    $script:Log.Clear(); $script:HiberbootSet = $null; $script:Hiberboot = 0
    Set-ServerPowerSettings
    ($null -eq $script:HiberbootSet) -and -not (logged "Fast Startup off")
}

Write-Host ""
if ($fail -gt 0) { Write-Host "# supervisor: $pass passed, $fail failed" -ForegroundColor Red; exit 1 }
Write-Host "# supervisor: $pass passed, 0 failed" -ForegroundColor Green
