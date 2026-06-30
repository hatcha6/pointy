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

2. **Run the installer.** It loads the bundled images and, on first run, creates
   a `.env` for you to edit.

   - Windows (PowerShell):
     ```powershell
     powershell -ExecutionPolicy Bypass -File .\install.ps1
     ```
   - Linux / macOS:
     ```sh
     bash install.sh
     ```

3. **Edit `.env`.** Replace every `replace-with-…` placeholder: the database and
   Redis passwords, the Django secret key, and the relay settings. On Windows,
   point the backup drive paths at real connected folders (e.g. `D:/`,
   `E:/PointyBackups`).

   You do **not** need to enter the server's LAN IP. Cashier tills find the
   backend by UDP discovery, and the backend accepts connections on whatever
   private LAN IP each till reaches it on. A **static IP (DHCP reservation) is
   still recommended** for stability — if the IP changes, tills re-discover
   automatically but drop briefly — but it is no longer required configuration.

4. **Open the firewall** for inbound **TCP 8000** (API), **UDP 47777**
   (LAN discovery), and **TCP 80** (browser access) so cashier devices can reach
   the server.

5. **Re-run the installer.** With `.env` in place it starts the stack:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\install.ps1   # Windows
   bash install.sh                                          # Linux / macOS
   ```

The backend runs database migrations on startup, then serves the API on
port 8000. Celery and the relay connector start once the backend is healthy.

### Relay enrollment (operator hand-off)

The relay credentials in `.env` are **issued by us (the operator), not generated
on this server.** An on-prem backend only ever holds its *own* per-installation,
scoped credentials — never the company-wide relay admin token (which controls the
whole hosted fleet).

Before install, the operator provisions this shop's installation against the
hosted relay (with the admin token, on a company-controlled host) and hands the
shop four values to paste into `.env`:

- `POINTY_RELAY_INSTALLATION_ID` — this shop's installation id
- `POINTY_RELAY_ACCESS_TOKEN` — scoped token for relay calls (AI, tickets, status,
  and connector-certificate issuance)
- `POINTY_RELAY_CONNECTOR_TOKEN` — secret the local connector presents to the relay
- `POINTY_RELAY_CONNECTOR_SETUP_TOKEN` — one-time token the connector uses to
  bootstrap against this backend over the LAN

The relay URLs (`POINTY_RELAY_CONTROL_URL`, `POINTY_RELAY_PUBLIC_API_URL`,
`POINTY_RELAY_CONNECTOR_ADDR`, `POINTY_RELAY_CONNECTOR_TLS_SERVER_NAME`) are the
same for every shop and come pre-filled in the template. With these set, the
backend enrolls the connector and renews its certificate using only the scoped
access token — no admin token ever lands on the shop's server.

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
