# Pointy On-Prem — Quick Install

This bundle is a **complete, offline on-prem installation**. It contains the
Pointy server images (backend, relay connector, PostgreSQL, Redis) saved as
Docker archives, the Compose file that wires them together, and an installer
script. The target host does **not** need the source code or a build toolchain —
only Docker.

> Detailed operations, hardening, backup, and failure-behavior notes live in
> `README.md` in this same folder.

## What's in here

```
docker-compose.yml      The on-prem stack (images only; no build step)
.env.example            Configuration template — copy to .env and edit
install.sh              Installer for Linux / macOS hosts
install.ps1             Installer for Windows hosts (Docker Desktop)
register-autostart.ps1  Registers the boot/crash watchdog (Windows)
register-autostart.sh   Registers the boot/crash watchdog (Linux / systemd)
watchdog.ps1            Keeps the stack up + heals it (Windows; run by the task)
watchdog.sh             Keeps the stack up + heals it (Linux; run by the timer)
README.md               Full operations / hardening / backup guide
VERSION.txt             The Pointy version this bundle was built from
images/                 Saved Docker images (loaded by the installer)
  pointy-backend-<ver>.tar
  pointy-relay-<ver>.tar
  pointy-web-<ver>.tar    Flutter web app + nginx (browser access)
  postgres.tar
  redis.tar
```

## Requirements

The installer sets up Docker for you — if Docker isn't already installed it
downloads and installs it automatically (run as **root** on Linux / **elevated**
PowerShell on Windows, with internet access). You only need:

- **Windows host (typical):** Docker Desktop runs the Linux-containers engine.
  Give the Docker VM at least 4 GB (tiny pilot) or 6 GB+ (recommended 8 GB host).
  A one-time sign-out/reboot may be needed right after a fresh Docker install.
- **Linux host:** Docker Engine + the Compose v2 plugin (the installer uses
  Docker's official install script).

## Install

1. **Extract** this bundle anywhere on the server (e.g. `C:\pointy` or
   `/opt/pointy`).

2. **Drop in your license key (optional — off for now).** Licensing is currently
   disabled so shops with no internet can run offline, so the installer no longer
   requires a `license.key`. If your provider gave you one, put it **in this bundle
   folder** next to `install.sh` / `install.ps1` and the installer records it for
   later; if not, the installer proceeds without it.

3. **Run the installer.** It loads the bundled images, generates the local
   secrets, records your license key if present, and starts the stack — no `.env`
   editing:

   - Windows (PowerShell):
     ```powershell
     powershell -ExecutionPolicy Bypass -File .\install.ps1
     ```
   - Linux / macOS:
     ```sh
     bash install.sh
     ```

   With licensing off (the current default) the stack comes straight up and runs
   fully offline — no relay round-trip needed. (When licensing is later enabled,
   the backend redeems the license with the relay on first boot, which needs
   internet once, then runs offline.) You do **not** edit `.env` for secrets — the
   installer fills them. (On Windows you may still point the backup-drive paths in
   `.env` at real folders, e.g. `D:/`, `E:/PointyBackups`.)

   You also do **not** need the server's LAN IP — tills find the backend by UDP
   discovery. A static IP (DHCP reservation) is recommended for stability but not
   required.

4. **Open the firewall** for inbound **TCP 8000** (API), **UDP 47777**
   (LAN discovery), and **TCP 80** (browser access) so cashier devices can reach
   the server.

The backend runs migrations on startup, then serves the API on port 8000 (and
redeems the license first when licensing is enabled). Celery and the relay
connector start once the backend is healthy.

### Licensing (how enrollment works)

Each installation is licensed with a **single-use license key**. You (the
operator) mint keys ahead of time and ship one with each shop's install — the
shop's server never holds the company-wide relay admin token.

- **Mint keys** (operator, once, in bulk) on a machine with the relay admin token:
  ```sh
  pointy-relay enrollment mint --count 50
  ```
  The raw keys are printed only once — save each shop's key as its `license.key`.

- **Ship + install:** put one `license.key` in the shop's bundle and run the
  installer. On first boot the backend redeems the key at the relay, receives its
  own scoped `access`/`connector` tokens (persisted locally), and the key is
  **spent** — it can never enroll a second install.

- **Activate:** a plain key enrolls an **inert** install — turn the subscription
  on per installation when you're ready, with the operator CLI:
  ```sh
  pointy-relay subscription enable <installation-id>
  ```

- **Or bake the subscription into the key.** Mint keys that activate the shop the
  moment it redeems them — no separate `subscription enable` step. The
  subscription clock starts at redemption, so keys can sit in inventory:
  ```sh
  # 50 keys, each granting remote access + AI for 1 year from activation:
  pointy-relay enrollment mint --count 50 --relay --ai --subscription 1y
  ```
  `--subscription` accepts `30d`, `6mo`, `1y`, a Go duration like `720h`, or
  `perpetual` (no expiry); `--relay` / `--ai` choose which entitlements to bake.

- **Expiry is automatic.** A fixed-term subscription stops granting access the
  moment its end date passes, and the relay also flips the stored
  `subscription_active` flag off on a periodic sweep (hourly by default; tune with
  `POINTY_RELAY_SUBSCRIPTION_SWEEP_INTERVAL`, or `0` to disable) so the fleet view
  shows lapsed shops as inactive. Renew with `subscription extend <id> --days N`.

- **History per shop.** Every subscription change is recorded — operator toggles,
  license-baked activations, and automatic expiries alike — and is viewable with:
  ```sh
  pointy-relay installations audit <installation-id>
  ```

When `POINTY_REQUIRE_LICENSE=true`, a backend serves nothing but health checks and
the enrollment path until it is licensed, so an unlicensed copy won't run.
**Licensing is currently OFF by default** (`POINTY_REQUIRE_LICENSE=false`) so shops
with no internet can run fully offline — the gate can only unlock by redeeming the
license key with the relay online, which an offline install can never reach. Flip
it back to `true` (and re-run `docker compose up -d`) once a shop has internet and
you want to enforce licensing. The relay URLs are the same for every shop and come
pre-filled in the template.

## Verify

```sh
docker compose --env-file .env -f docker-compose.yml ps
curl http://127.0.0.1:8000/healthz/    # web process alive
curl http://127.0.0.1:8000/readyz/     # web + PostgreSQL + Redis ready
```

Connect from any device:

- **Native tills** (Android / Windows apps) auto-discover the backend, or point
  them at `http://<server-LAN-IP>:8000`.
- **A browser** — open `http://<server-LAN-IP>/` on any device on the LAN to use
  the Flutter web app directly, no install. It serves from the same server and
  talks to the API on the same origin, so there is nothing to configure.

> Browser note: the web app covers day-to-day POS, management and reporting, but
> hardware that needs the OS (USB/serial receipt printers, USB barcode scanners)
> works only in the native Android/Windows apps. Use the web build for quick
> access and back-office, the native apps at the counter.

## Resilience (no-outage operation)

The till must come back on its own after a crash, a container being removed, or
a power cut — without anyone logging in to "start" anything. Three layers make
that happen:

1. **`restart: always`** on every service — Docker restarts a crashed container
   in place, instantly, and brings the whole stack back when the Docker engine
   starts.
2. **A watchdog** (`watchdog.ps1` / `watchdog.sh`) that runs at boot and every
   5 minutes. It waits for Docker, runs `docker compose up -d` (which
   **recreates any container that was destroyed/removed or left stopped**), and
   **restarts any container that is running but stuck "unhealthy"** — something
   Docker's restart policy does not do on its own.
3. **Auto-start registration** so the watchdog itself runs unattended — a
   Windows Scheduled Task or a Linux systemd timer.

`install.ps1` / `install.sh` register the watchdog automatically **when run with
admin/root rights**. If they could not, register it once yourself:

- Windows (elevated PowerShell):
  ```powershell
  powershell -ExecutionPolicy Bypass -File .\register-autostart.ps1
  ```
- Linux:
  ```sh
  sudo bash register-autostart.sh
  ```

### Windows: the one manual step that matters most

Docker Desktop **only runs inside a logged-in Windows session**. If the server
reboots after a power cut and no one signs in, Docker never starts and the till
stays down — no restart policy can help, because the engine isn't running. So on
a Windows server you must:

1. **Enable automatic logon** for the dedicated POS user. Run `netplwiz`, untick
   *"Users must enter a user name and password to use this computer"*, and enter
   the password. (Equivalent registry keys: `AutoAdminLogon`, `DefaultUserName`,
   `DefaultPassword` under
   `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon`.)
2. **Set Docker Desktop to start at login** — Docker Desktop → Settings →
   General → *Start Docker Desktop when you sign in*. `register-autostart.ps1`
   also tries to set this for you.

With auto-logon on, a reboot logs the POS user in, Docker Desktop starts, the
scheduled task fires, and the stack is back — hands-off.

### Linux

Also make sure Docker starts on boot: `sudo systemctl enable docker`. The
systemd timer (`pointy-watchdog.timer`) then reconciles the stack ~30s after
boot and every 5 minutes.

### Doing maintenance

Because everything self-heals, a manual `docker compose stop`/`down` will be
undone within ~5 minutes. To stop the stack on purpose, first pause the
watchdog:

- Windows: `Disable-ScheduledTask -TaskName PointyAutostart`
- Linux: `sudo systemctl stop pointy-watchdog.timer`

Re-enable it (`Enable-ScheduledTask` / `systemctl start pointy-watchdog.timer`)
when you are done.

## Updating to a newer bundle

1. Extract the new bundle into a fresh folder.
2. Copy your existing `.env` into it.
3. Run the installer — `docker load` brings in the new image tags and
   `docker compose up -d` performs a rolling restart. The named Docker volumes
   (database, media, backups) are preserved across updates.

To roll back, re-run the installer from the previous bundle folder (it still has
its own images and `.env`).
