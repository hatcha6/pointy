# Dry run: proving a Windows install before you drive to the shop

The automated tests cover the logic (`tests/run-tests.ps1`) and everything that
happens inside the distro (`../tests/run-tests.sh`). They fake `wsl.exe`,
`msiexec` and `netsh`, so they prove the decisions are right — not that Windows
does what it says.

These nine steps are the part only a real machine can answer. Each one ends in a
command that proves it, because several of these fail *silently*: `netsh` reports
success for a forward that never binds, and Docker creates a missing bind mount
as an empty directory rather than refusing.

Budget ~45 minutes on any spare Windows 10/11 box. Do it the night before.

---

**0. Start from nothing.** If the box has a previous attempt on it:

    wsl --unregister Pointy
    schtasks /delete /tn PointyWSL /f
    netsh interface portproxy reset

**1. Run the installer** from the extracted bundle, in an ELEVATED PowerShell:

    powershell -ExecutionPolicy Bypass -File .\wsl\bootstrap-wsl.ps1

Expect either a clean run or `exit 2` asking for a reboot. Both are correct.
*Reboot and run the exact same command again* — that second run is itself a test:
the script is meant to be idempotent, and this is the path a real shop takes.

**2. The features are on.** `dism /online /get-featureinfo /featurename:VirtualMachinePlatform`
must say `State : Enabled`.

**3. WSL actually works** — this is what used to fail on the first run:

    wsl --version

If the log shows `Windows Installer is busy`, the retry did its job. Keep the
log; it is the evidence the fix works in the field.

**4. The distro imported and systemd is PID 1:**

    wsl -d Pointy -u root -- ps -p 1 -o comm=

Must print `systemd`. Anything else and the watchdog cannot be registered, so
the shop will not come back after a power cut — the single most important line
in this list.

**5. The stack is up:**

    wsl -d Pointy -u root --cd /opt/pointy -- docker compose ps

Every service `running`; `backend` and `postgres` `healthy`.

**6. `.env` is complete** (it should say so itself, but confirm):

    wsl -d Pointy -u root --cd /opt/pointy -- bash install.sh --env-only

Re-running is safe and must not rotate a secret. Then confirm the app is on the
pooler and migrations are not:

    wsl -d Pointy -u root --cd /opt/pointy -- grep -E '^POINTY_DATABASE(_DIRECT)?_URL=' .env

**7. The LAN bridge BINDS.** `netsh` lying about this is the classic silent
failure, so check the listener, not the rule. The bootstrap checks it too: its
last line in the log must say the bridge is *answering*, and anything else names
the hop that failed.

    netsh interface portproxy show v4tov4
    Get-NetTCPConnection -LocalPort 8000 -State Listen
    Get-Content $env:ProgramData\Pointy\logs\bootstrap.log -Tail 20

`wslrelay` must NOT appear as a listener on 8000 or 80. If it does, WSL's
localhost forwarding still holds the port, so restart Windows once.

**8. A till can actually reach it.** From a DIFFERENT machine on the same LAN —
not the server, whose loopback would pass regardless:

    curl http://<server-lan-ip>:8000/readyz/

This is the only step that proves the whole chain. If 1-7 pass and this fails,
it is the bridge or the firewall, not the stack.

**9. It survives a reboot.** Reboot the box, log in to nothing, wait ~2 minutes,
and run step 8 again from the other machine. This proves the scheduled task and
the watchdog — the difference between an install and a demo.

---

## If something bites anyway

| symptom | first thing to try |
|---|---|
| PowerShell will not parse the script | confirm it still has a BOM: `Format-Hex .\wsl\bootstrap-wsl.ps1 \| Select -First 1` — first bytes `EF BB BF` |
| WSL install "fails" instantly | re-run it; if it now passes, the retry window was too short — raise `$attempts` |
| stack up, till cannot connect | read `bootstrap.log`: it names the failed hop and who holds the port. Then step 7, the firewall rule, then `-Boot` to re-point the bridge |
| the server's own till works, no other device finds the server | WSL's localhost forwarding took the ports before the LAN forward. Restart Windows once (or re-run the installer), then check step 7 again |
| the companion QR points at `127.0.0.1` | the till predates the fix that swaps loopback for the PC's LAN address; update the till app |
| backend cannot reach the database | put it back on direct Postgres: `sed -i 's\|@pgbouncer:5432\|@postgres:5432\|' .env && docker compose --env-file .env -f docker-compose.yml up -d backend` |
| backend dies at a fixed interval | already fixed at install; confirm with `grep ASGI_MAX_REQUESTS .env` (must be 0) |
