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
install.sh              Installer (Linux, macOS, and Windows-inside-WSL)
register-autostart.sh   Registers the watchdog + update agent + discovery (systemd)
watchdog.sh             Keeps the stack up + heals it (run by the systemd timer)
discovery-responder.py  Answers POS clients' LAN discovery probes
update.sh               Applies a newer release bundle to this install (manual)
update-agent.sh         Applies relay-assigned updates automatically
update-lib.sh           Shared update engine used by both of the above
edge/                   The LAN front door's config (baked into its image)
migrate-fahd.sh         One-shot legacy-data import for shops coming from Fahd
change-license.sh       Moves this server onto a different license key
wsl/                    The Windows install path — see "Windows hosts" below
  bootstrap-wsl.ps1       The ONLY PowerShell we ship (installs WSL, hands off)
  pointy-wsl-rootfs.tar.gz  The Linux server image, Docker already inside
  wsl.<version>.x64.msi     WSL itself, so the install needs no internet
  timezone-map.txt          Windows time zone -> IANA zone
README.md               Full operations / hardening / backup guide
VERSION.txt             The Pointy version this bundle was built from
images/                 Saved Docker images (loaded, then destroyed, by the
                        installer — see "Image archives are not kept" below)
  pointy-backend-<ver>.tar
  pointy-relay-<ver>.tar
  pointy-web-<ver>.tar    Flutter web app + nginx (browser access)
  pointy-edge.tar         LAN front door (owns :8000; see "Updating" below)
  postgres.tar
  redis.tar
  pgbouncer.tar
clients/                Every till app this server hands out on the LAN. The
                        installer publishes them; staff install from
                        http://<server-ip>/clients/ and the apps then update
                        themselves from the same place. No second download.
  pointy-<ver>-android-universal.apk        Android tablets and phones
  pointy-<ver>-windows-x64-setup.exe        Windows 10/11 tills
  pointy-<ver>-compat-windows-x64-setup.exe Windows 7/8/8.1 tills (its own
                        version: this build ships from its own frozen release)
  pointy-<ver>-linux-x64.deb                Ubuntu/Mint tills (menu entry + icon)
  pointy-<ver>-linux-x64.tar.gz             Other Linux distros; also what the
                        Linux app's own self-update installs
  manifest.json         What the page offers and what the apps poll
```

## Requirements

The installer sets up Docker for you — if Docker isn't already installed it
downloads and installs it automatically (run as **root** on Linux / **elevated**
PowerShell on Windows, with internet access). You only need:

- **Windows host (typical):** 64-bit Windows 10 build 19041 (2004) or newer,
  with hardware virtualization enabled in the BIOS/UEFI. Everything runs inside
  a WSL2 distro that this bundle ships pre-built, so nothing is downloaded
  during the install. 8 GB of RAM recommended (the installer gives the VM half
  the host's RAM, capped at 8 GB); 20 GB free on `C:`.
- **Linux host:** Docker Engine + the Compose v2 plugin (the installer uses
  Docker's official install script).

## Install

1. **Extract** this bundle anywhere on the server (e.g. `C:\pointy` or
   `/opt/pointy`).

2. **Drop in your license key (optional — off for now).** Licensing is currently
   disabled so shops with no internet can run offline, so the installer no longer
   requires a `license.key`. If your provider gave you one, put it **in this bundle
   folder** next to `install.sh` and the installer records it for
   later; if not, the installer proceeds without it.

3. **Run the installer.** It loads the bundled images (and then destroys the
   archives — see below), generates the local secrets, records your license key
   if present, and starts the stack — no `.env` editing:

   - Windows (**elevated** PowerShell):
     ```powershell
     powershell -ExecutionPolicy Bypass -File .\wsl\bootstrap-wsl.ps1
     ```
     This enables the Windows virtualization features, installs WSL, imports the
     bundled Linux distro, and then runs `install.sh` **inside it**. If Windows
     asks for a reboot to finish enabling the features, reboot and run the exact
     same command again — it picks up where it left off.
   - Linux / macOS:
     ```sh
     bash install.sh
     ```

   With licensing off (the current default) the stack comes straight up and runs
   fully offline — no relay round-trip needed. (When licensing is later enabled,
   the backend redeems the license with the relay on first boot, which needs
   internet once, then runs offline.) You do **not** edit `.env` for secrets — the
   installer fills them. (You may still point the backup-drive
   paths in `.env` at real folders. On Windows use the WSL form — `D:/` is
   `/mnt/d` — and see the warning in `.env.example`.)

   You also do **not** need the server's LAN IP — tills find the backend by UDP
   discovery. A static IP (DHCP reservation) is recommended for stability but not
   required.

4. **Open the firewall** for inbound **TCP 8000** (API) and **TCP 80** (browser
   access) so cashier devices can reach the server. On Windows,
   `bootstrap-wsl.ps1` adds both rules for you. **UDP 47777** (LAN discovery)
   is worth opening on Linux hosts; on Windows it cannot help, because
   broadcasts do not cross the WSL VM's NAT — the tills fall back to an HTTP
   subnet sweep instead and find the server anyway.

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

### Changing the license key (the wrong one was redeemed)

Re-running the installer with a different `license.key` changes nothing:
`install.sh` only reads that file on the run that creates `.env`, and the key it
recorded was spent the moment the backend redeemed it. To move a shop onto the
right key, run this from the deploy directory while the shop is online:

```sh
sudo bash change-license.sh <new-license-key>   # or put the key in license.key and omit it
```

On Windows, inside the distro:

```powershell
wsl -d Pointy -u root --cd /opt/pointy -- bash change-license.sh <new-license-key>
```

It names the installation it is about to replace and asks before spending the
key (`--yes` skips the question), then:

1. redeems the new key with the relay and switches the backend to the
   installation it creates. A key the relay refuses (mistyped, already used,
   expired) changes nothing, and the script stops there;
2. writes the key into `.env` as `POINTY_RELAY_ENROLLMENT_TOKEN`;
3. resets the relay connector, which would otherwise go on connecting as the old
   installation.

The tills keep working throughout: the backend is not restarted. Step 1 on its
own is `docker compose --env-file .env -f docker-compose.yml exec backend python
manage.py relay_change_license <new-license-key>`, which leaves steps 2 and 3 to you.

Then, on the operator machine:

- The new installation has only what its key carried. A subscription you turned
  on by hand for the old one, or a fleet pin or channel, has to be applied to the
  new installation id.
- Retire the old installation. The script prints the exact command:
  `pointy-relay subscription disable <old-id> --reason "wrong license key; replaced by <new-id>"`.
- The wrongly used key stays spent. Mint the shop it was meant for a fresh one.

## Verify

```sh
docker compose --env-file .env -f docker-compose.yml ps
curl http://127.0.0.1:8000/healthz/    # web process alive
curl http://127.0.0.1:8000/readyz/     # web + PostgreSQL + Redis ready
```

Connect from any device:

- **Native tills** (Android / Windows / Linux apps) auto-discover the backend,
  or point them at `http://<server-LAN-IP>:8000`.
- **A browser** — open `http://<server-LAN-IP>/` on any device on the LAN to use
  the Flutter web app directly, no install. It serves from the same server and
  talks to the API on the same origin, so there is nothing to configure.

> Browser note: the web app covers day-to-day POS, management and reporting, but
> hardware that needs the OS (USB/serial receipt printers, USB barcode scanners)
> works only in the native apps. Use the web build for quick access and
> back-office, the native apps at the counter.

## Resilience (no-outage operation)

The till must come back on its own after a crash, a container being removed, or
a power cut — without anyone logging in to "start" anything. Three layers make
that happen:

1. **`restart: always`** on every service — Docker restarts a crashed container
   in place, instantly, and brings the whole stack back when the Docker engine
   starts.
2. **A watchdog** (`watchdog.sh`) that runs at boot and every 5 minutes. It
   waits for Docker, runs `docker compose up -d` (which **recreates any
   container that was destroyed/removed or left stopped**), and **restarts any
   container that is running but stuck "unhealthy"** — something Docker's
   restart policy does not do on its own.
3. **Auto-start registration** so the watchdog itself runs unattended — a
   systemd timer, on Linux hosts and inside the Windows distro alike.

`install.sh` registers the watchdog automatically **when run as root**. If it
could not, register it once yourself:

```sh
sudo bash register-autostart.sh
```

### Windows hosts

The whole stack runs inside a WSL2 distro named `Pointy`. The Linux scripts
above are the real ones; there is no parallel set of Windows scripts to keep in
step. Only two jobs cannot be done from Linux, and both live in the single
`wsl/bootstrap-wsl.ps1`:

- the **first install** (enable the Windows features, install WSL, import the
  distro, register the boot task), and
- a **boot-time reconcile** (`-Boot`), which starts the distro and re-points the
  LAN bridge at it.

One Windows scheduled task, `PointyWSL`, runs the reconcile at startup and every
5 minutes. Everything else — the watchdog, the update agent, the discovery
responder — is a systemd unit inside the distro.

**No automatic logon is needed.** This is the main operational gain over the old
Docker Desktop install: Docker Desktop only ran inside a logged-in Windows
session, which forced every shop to enable Windows auto-logon and store the POS
user's password in clear text under `Winlogon`. The `PointyWSL` task runs
without an interactive session, so a machine can reboot after a power cut,
reach the logon screen with nobody there, and still bring the tills back.

> If the task fails to register with `LogonType=S4U`, the bootstrap retries with
> a stored password and tells you. If both fail, create the task by hand with
> *Run whether user is logged on or not* + *Run with highest privileges*, as the
> **same Windows user that ran the bootstrap** — WSL distros are registered per
> user and `SYSTEM` cannot see them.

#### Windows: how the tills reach the stack

A WSL2 VM sits behind a NAT with a **new IP every time it starts**, and WSL's
`localhostForwarding` only covers the Windows loopback — not the LAN. So
`bootstrap-wsl.ps1 -Boot` forwards TCP 8000 and 80 from the host into the VM
with `netsh interface portproxy`, and re-points them whenever the VM's IP
changes. That is why the task repeats every 5 minutes.

Two consequences worth knowing:

- **UDP broadcast discovery does not work** on Windows: broadcasts do not cross
  the NAT. The tills race three discovery paths — the stored IP, UDP, and an
  HTTP `/24` subnet sweep — and the sweep finds the server at the Windows host's
  LAN address. First pairing takes a couple of seconds longer; nothing else
  changes.
- **The backend sees the Windows host, not the till, as the client IP**, because
  a portproxy hop does not preserve the source address. Per-user limits are
  unaffected, but the per-IP login throttle (`DJANGO_THROTTLE_LOGIN`, default
  `30/min`) becomes a *shop-wide* ceiling instead of a per-device one. Raise it
  in `.env` for a busy shop with many tills.

#### Windows: useful commands

```powershell
wsl -d Pointy -u root --cd /opt/pointy                       # shell into the server
wsl -d Pointy -u root --cd /opt/pointy -- docker compose ps  # stack status
wsl -d Pointy -u root -- journalctl -u pointy-watchdog -f    # watchdog log
netsh interface portproxy show v4tov4                        # the LAN bridge
Get-Content $env:ProgramData\Pointy\logs\bootstrap.log -Tail 50
```

### Linux

Nothing manual: `register-autostart.sh` enables Docker on boot
(`systemctl enable docker`) alongside the timers, and the watchdog starts the
Docker daemon itself if it is ever down. The systemd timer
(`pointy-watchdog.timer`) reconciles the stack ~30s after boot and every
5 minutes. (On a setup without a `docker.service` unit — e.g. rootless Docker —
arrange for the daemon to start on boot yourself.)

### Doing maintenance

Because everything self-heals, a manual `docker compose stop`/`down` will be
undone within ~5 minutes. To stop the stack on purpose, first pause the
watchdog:

```sh
sudo systemctl stop pointy-watchdog.timer
```

Re-enable it with `systemctl start pointy-watchdog.timer` when you are done. On
Windows run that inside the distro (`wsl -d Pointy -u root -- systemctl stop
pointy-watchdog.timer`); you do **not** need to touch the `PointyWSL` scheduled
task, which only manages the distro and the LAN bridge, never the containers.

## Updating to a newer bundle

Updates are applied **live** — you do not have to close the shop, and you do not
have to wait for closing time.

```sh
# Linux / macOS, from the deploy directory:
bash update.sh /path/to/pointy-onprem-1.5.0.zip
```

```powershell
# Windows: the same script, run inside the distro. Copy the bundle in first —
# updating from /mnt/c works, but is far slower than the distro's own disk.
wsl -d Pointy -u root -- cp /mnt/c/Users/POS/Downloads/pointy-onprem-1.5.0.zip /tmp/
wsl -d Pointy -u root --cd /opt/pointy -- bash update.sh /tmp/pointy-onprem-1.5.0.zip
```

Run it from the current deploy directory (next to `docker-compose.yml` and
`.env`). Your `.env`, the named Docker volumes (database, media, backups) and
the shop's data are all preserved; only images and scripts change.

### How it stays online

A container cannot change its image without being destroyed, and only one
container can hold a host port — so for as long as the backend itself owned
`:8000`, every update locked the tills out for the length of a Django boot. The
`edge` service now owns that port and proxies it to whichever backend is live,
which lets the updater work like this:

1. Load the new application images (nothing running is touched).
2. Start the **new** backend beside the one serving customers. It runs the new
   release's migrations here, against the live database.
3. Wait for it to answer `/readyz/` — through the front door, over the real
   network path traffic will take.
4. Flip: `nginx -s reload`. In-flight requests finish on the old container, new
   ones land on the new one, and nothing is refused. The updater verifies the
   flip landed (`X-Pointy-Upstream`) instead of assuming it did.
5. Rebuild the managed `backend` container on the new image while the new one
   serves, hand traffic back to it, then remove the temporary container.
6. Replace the background workers, relay connector and web app — none of which
   hold the LAN port.

If the new version never becomes healthy, **no traffic ever moves**: the update
aborts, restores the previous configuration, and the shop keeps trading on the
old release. If something fails after the flip, the previous release is brought
back and traffic returns to it.

### What a live update deliberately does not touch

The database, Redis, PgBouncer and the front door itself. Replacing any of them
means recreating them, which is the one thing that cannot be done under a
trading shop. Their new images ship in the bundle and stay staged in `./images`;
the updater says so when it finishes. Apply them in a maintenance window with:

```sh
bash update.sh /path/to/bundle.zip --restart   # or: sudo bash install.sh
```

### One-time exception

A deployment installed before the front door existed does not have it yet, so
the first update that introduces it is applied the old way — a full restart, as
before. Every update after that one is live. The updater tells you when this is
what it is doing.

### Rolling back

Point the updater at the previous release and force it:

```sh
bash update.sh /path/to/pointy-onprem-<older>.zip --force
```

Keep the previous bundle: the deployment does not hold a copy of it. Installing
and updating both destroy the image archives once Docker has loaded them, and a
committed update drops the superseded application images (see below), so there
is nothing on the machine to roll back *to* once an update has been committed.

### Image archives are not kept

`images/pointy-*.tar` is the easiest way there is to read our source: two plain
`tar xf` calls, no Docker and no root involved. Docker's own image store is a
much harder target and it is the only copy the stack needs to run, so:

* every `pointy-*.tar` is shredded as soon as `docker load` has taken it, on
  both install and update;
* a bundle the updater downloaded or unzipped itself is shredded with it;
* once an update is committed and healthy, the previous release's
  `pointy-backend` / `pointy-relay` / `pointy-web` images are removed — never
  forced, so an image a container still holds is left alone.

Third-party archives (`postgres.tar`, `redis.tar`, `pgbouncer.tar`) are kept:
they hold none of our code and they are what the next maintenance restart loads.
The `pointy-edge` archive is kept through a live update for the same reason, and
is destroyed at the restart that loads it.

Two consequences worth knowing before you rely on them:

* **The machine cannot re-install itself from its own deploy directory** if
  Docker's image store is destroyed (Docker reinstalled, `/var/lib/docker`
  wiped). Re-running `install.sh` is still fine as long as the image store is
  intact — it detects the loaded images and skips the load step. Anything worse
  needs the release bundle again.
* **Keep every bundle you ship**, because rollback needs it.

Set `POINTY_KEEP_IMAGE_ARCHIVES=1` (in the environment or in `.env`) to turn all
of this off for a machine where offline re-installability matters more.

Note what this does *not* claim: anyone with root on the host still has the
running container, and `docker cp` / `docker export` reads its filesystem
directly. Deleting the loaded backend image itself would not change that — and
it would leave `compose up` with nothing to recreate the container from and no
registry to pull from, which is a shop that never comes back after a crash. The
bar this raises is the offline one: a copied deploy directory, a stolen disk, a
bundle left in Downloads.
