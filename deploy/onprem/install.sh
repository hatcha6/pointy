#!/usr/bin/env bash
#
# Pointy on-prem installer (Linux / macOS hosts).
#
# Run this from inside an extracted release bundle. If Docker isn't installed it
# installs it automatically (run as root on Linux), then loads the bundled Docker
# images (so the host never has to pull from a registry) and starts the stack.
# Re-run it any time — it is idempotent.
#
#   sudo bash install.sh
#
set -euo pipefail
cd "$(dirname "$0")"

err() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------------------
# WSL preflight.
#
# On Windows the stack runs inside a WSL2 distro (see wsl/bootstrap-wsl.ps1).
# Three WSL-specific mistakes destroy a shop's data quietly rather than loudly,
# so they are hard failures / loud warnings here rather than a line in a README
# nobody reads at 7am on install day.
# ---------------------------------------------------------------------------
running_under_wsl() {
  [ -n "${WSL_DISTRO_NAME:-}" ] && return 0
  grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null
}

wsl_preflight() {
  running_under_wsl || return 0
  echo "==> WSL detected (${WSL_DISTRO_NAME:-unknown}); running WSL preflight…"

  # 1. NEVER run from the Windows filesystem. /mnt/c is DrvFs (a 9p/plan9
  #    protocol bridge): roughly an order of magnitude slower, and — fatally —
  #    it does not honour POSIX locking or fsync ordering the way Postgres
  #    requires. A database on /mnt/c does not degrade, it corrupts.
  case "$PWD" in
    /mnt/*)
      err "this bundle is on the Windows filesystem (${PWD}).
       Postgres cannot run safely there: DrvFs does not give the file locking
       and fsync ordering the database needs, and the data WILL corrupt.
       Move the bundle onto the distro's own disk and re-run:
         cp -r \"${PWD}\" /opt/pointy && cd /opt/pointy && bash install.sh"
      ;;
  esac

  # 2. systemd must be PID 1, or register-autostart.sh has no supervisor to
  #    install the watchdog and update-agent timers into — the shop would come
  #    up once and never self-heal again.
  if [ "$(ps -p 1 -o comm= 2>/dev/null)" != "systemd" ]; then
    echo "WARN: systemd is not PID 1 in this distro." >&2
    echo "      The watchdog and update agent cannot be registered, so the stack" >&2
    echo "      will NOT come back on its own after a reboot or a crash." >&2
    echo "      Fix: put this in /etc/wsl.conf, then run 'wsl --shutdown' on Windows:" >&2
    echo "          [boot]" >&2
    echo "          systemd=true" >&2
  fi

  echo "    WSL preflight passed (running from ${PWD} on the distro's own disk)."
}

wsl_check_backup_drives() {
  running_under_wsl || return 0
  [ -f .env ] || return 0
  # External backup drives are bind-mounted from the Windows host. If the drive
  # is not attached, /mnt/<letter> does not exist — and Docker CREATES a missing
  # bind source as an empty directory inside the VM. Every backup then
  # "succeeds" into the very virtual disk it was meant to survive, and the shop
  # finds out on the one day it needs the backup.
  local key value letter
  for key in POINTY_BACKUP_DRIVE_1_SOURCE POINTY_BACKUP_DRIVE_2_SOURCE POINTY_BACKUP_DRIVE_3_SOURCE; do
    value="$(sed -n "s/^${key}=//p" .env | tail -1 | tr -d '\r')"
    case "$value" in
      /mnt/*)
        if [ ! -d "$value" ]; then
          letter="${value#/mnt/}"; letter="${letter%%/*}"
          echo "WARN: ${key}=${value} does not exist." >&2
          echo "      That drive is not attached (or Windows has not mounted it yet)." >&2
          echo "      Docker will silently create an empty folder INSIDE the virtual disk," >&2
          echo "      so your off-machine backups would go nowhere. Attach the drive, then:" >&2
          echo "          mkdir -p /mnt/${letter} && mount -t drvfs ${letter}: /mnt/${letter}" >&2
        fi
        ;;
      [A-Za-z]:*|*\\*)
        err "${key}=${value} is a Windows path. Inside WSL use the /mnt form instead
       (D:/PointyBackups becomes /mnt/d/PointyBackups)."
        ;;
    esac
  done
}

wsl_preflight

# Install Docker Engine + the Compose plugin (Linux, via Docker's official
# convenience script) or Docker Desktop (macOS, via Homebrew) when it is missing,
# so onboarding a fresh shop is just running this one script.
install_docker_linux() {
  if [ "$(id -u)" -ne 0 ]; then
    err "Docker isn't installed. Re-run as root so it can be installed automatically:  sudo bash install.sh"
  fi
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 \
    || err "Need curl or wget to download Docker. Install one and re-run."
  echo "    Fetching Docker's official install script…"
  script="$(mktemp)"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com -o "$script" || err "Could not download Docker (no internet?)."
  else
    wget -qO "$script" https://get.docker.com || err "Could not download Docker (no internet?)."
  fi
  sh "$script" || err "Docker installation failed."
  rm -f "$script"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now docker || true
  fi
}

install_docker_macos() {
  command -v brew >/dev/null 2>&1 \
    || err "On macOS, install Docker Desktop from https://www.docker.com/products/docker-desktop/ then re-run."
  echo "    Installing Docker Desktop via Homebrew…"
  brew install --cask docker || err "Homebrew could not install Docker Desktop."
  open -a Docker >/dev/null 2>&1 || true
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    return 0
  fi
  echo "==> Docker (with the Compose plugin) was not found; installing it now…"
  case "$(uname -s)" in
    Linux) install_docker_linux ;;
    Darwin) install_docker_macos ;;
    *) err "Automatic Docker install isn't supported on this OS; install Docker manually and re-run." ;;
  esac
  command -v docker >/dev/null 2>&1 || err "Docker still not found after install; install it manually and re-run."
}

ensure_docker

# If Docker is installed but the daemon isn't up, try to start it (best-effort).
if ! docker info >/dev/null 2>&1 && command -v systemctl >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
  systemctl start docker >/dev/null 2>&1 || true
fi

echo "==> Waiting for the Docker daemon…"
for _ in $(seq 1 60); do
  if docker info >/dev/null 2>&1; then break; fi
  sleep 5
done
docker info >/dev/null 2>&1 \
  || err "Docker daemon is not reachable. If Docker was just installed, a reboot/sign-out may be required — then re-run."
docker compose version >/dev/null 2>&1 \
  || err "Docker Compose v2 ('docker compose') is required but missing."

# ---------------------------------------------------------------------------
# Image archives are destroyed once Docker has taken them.
#
# ./images/pointy-*.tar is the softest target on the whole machine: two plain
# `tar xf` calls — no Docker, no root, no knowledge of anything — and the
# application's entire source tree is sitting in a directory. Docker's own image
# store is a materially harder target, and it is the one copy that has to exist
# for the stack to run, so the archives go as soon as `docker load` has them.
#
# What this costs, and it is not nothing: a shop can no longer re-install from
# its own deploy directory if Docker's image store is destroyed (Docker
# reinstalled, /var/lib/docker wiped). It needs the release bundle again for
# that. Set POINTY_KEEP_IMAGE_ARCHIVES=1 (env or .env) to keep them.
#
# Third-party archives (postgres/redis/pgbouncer) are deliberately left alone:
# they carry none of our code, they are freely downloadable anyway, and they are
# what a later maintenance restart loads.
# ---------------------------------------------------------------------------

# Read a single KEY=value out of .env without evaluating it as shell.
env_value() { grep -E "^$1=" .env 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'" | tr -d '\r'; }

keep_image_archives() {
  local flag="${POINTY_KEEP_IMAGE_ARCHIVES:-}"
  [ -n "$flag" ] || flag="$(env_value POINTY_KEEP_IMAGE_ARCHIVES)"
  case "$flag" in 1|true|TRUE|yes|YES) return 0 ;; *) return 1 ;; esac
}

# Overwrite once, then unlink. shred is not a guarantee on a journalling or
# copy-on-write filesystem, so this is defence in depth rather than a promise —
# the point is that the file is gone.
shred_archive() {
  if command -v shred >/dev/null 2>&1 && shred -n 1 -u "$1" 2>/dev/null; then
    return 0
  fi
  rm -f "$1"
}

# Are the application images already in Docker's store? This is what makes
# re-running the installer safe after a previous run shredded the archives.
app_images_loaded() {
  local key image
  for key in POINTY_BACKEND_IMAGE POINTY_RELAY_IMAGE POINTY_WEB_IMAGE; do
    image="$(env_value "$key")"
    [ -n "$image" ] || return 1
    docker image inspect "$image" >/dev/null 2>&1 || return 1
  done
  return 0
}

echo "==> Loading Pointy container images (this can take a minute)…"
shopt -s nullglob
images=(images/*.tar)
if [ ${#images[@]} -gt 0 ]; then
  for tar in "${images[@]}"; do
    echo "    - $tar"
    docker load -i "$tar"
    case "$(basename "$tar")" in
      pointy-*)
        if ! keep_image_archives; then
          shred_archive "$tar"
          echo "      archive removed (POINTY_KEEP_IMAGE_ARCHIVES=1 keeps it)"
        fi
        ;;
    esac
  done
elif [ -f .env ] && app_images_loaded; then
  # A re-run after a previous install shredded the archives. Every image is
  # already in Docker's store, which is all `compose up` needs.
  echo "    Already loaded (archives were removed after the last install)."
else
  err "No image archives under ./images, and the images they carry are not in
       Docker either. Archives are removed once they are loaded, so this is
       either an incomplete bundle or a machine whose Docker image store was
       wiped. Re-extract the release bundle and run install.sh from it."
fi

if [ ! -f .env ]; then
  # LICENSING TEMPORARILY OFF ("for now"): on-prem installs don't require a
  # license key, so a shop with no internet can run fully offline. The license
  # gate unlocks by redeeming the key with the relay *online* — which an offline
  # shop can never reach — so requiring it would brick the till. If a license.key
  # is present we still record it, so re-enabling licensing later (set
  # POINTY_REQUIRE_LICENSE=true once the shop has internet) enrolls without a
  # reinstall. To restore enforcement: make the file required again (err/exit) and
  # set POINTY_REQUIRE_LICENSE "true" below.
  LICENSE_FILE="${POINTY_LICENSE_FILE:-license.key}"
  LICENSE_KEY=""
  if [ -f "$LICENSE_FILE" ]; then
    LICENSE_KEY="$(tr -d '[:space:]' < "$LICENSE_FILE")"
  else
    echo "WARN: no license key at ./$LICENSE_FILE — installing without a license (offline mode)."
  fi
  command -v openssl >/dev/null 2>&1 || err "openssl is required to generate secrets. Install it and re-run."

  cp .env.example .env

  # Replace KEY=… in .env (or append). awk avoids GNU/BSD sed -i differences and
  # sed metacharacter escaping; our values are hex/URLs with no '=' so FS='=' is safe.
  set_env_var() {
    local key="$1" value="$2" tmp
    if grep -qE "^${key}=" .env; then
      tmp="$(mktemp)"
      awk -v k="$key" -v v="$value" 'BEGIN{FS=OFS="="} $1==k{print k FS v; next} {print}' .env >"$tmp"
      mv "$tmp" .env
    else
      printf '%s=%s\n' "$key" "$value" >>.env
    fi
  }

  pg_password="$(openssl rand -hex 24)"
  set_env_var POINTY_POSTGRES_PASSWORD "$pg_password"
  set_env_var POINTY_DATABASE_URL "postgres://pointy:${pg_password}@postgres:5432/pointy"
  set_env_var DJANGO_SECRET_KEY "$(openssl rand -hex 48)"
  set_env_var POINTY_RELAY_CONNECTOR_SETUP_TOKEN "$(openssl rand -hex 24)"
  set_env_var POINTY_RELAY_ENROLLMENT_TOKEN "$LICENSE_KEY"
  set_env_var POINTY_REQUIRE_LICENSE "false"

  echo "==> Created .env: generated local secrets (licensing off — offline install)."
fi

# The .env holds the Postgres password, DJANGO_SECRET_KEY (session forgery) and
# the relay tokens in clear text. Owner-only, every run — not just the run that
# created it, since an older install may predate this and a `cp` from a bundle
# lands with the umask default.
chmod 600 .env 2>/dev/null || true
if [ "$(id -u)" -eq 0 ]; then
  chown root:root .env 2>/dev/null || true
fi

# A full install/restart is the moment everything converges, so reset what a
# live update may have left pointing elsewhere: the LAN front door goes back to
# the managed backend, and any temporary container a previous update was serving
# from is removed. Both are safe no-ops on a fresh install.
echo "==> Resetting the LAN front door to the managed backend…"
mkdir -p edge/active
cat > edge/active/upstream.conf <<'UPSTREAM'
# GENERATED — the backend the LAN front door is currently sending traffic to.
# Rewritten by update.sh during a live update; reset here.
set $pointy_upstream      "http://backend:8000";
set $pointy_upstream_name "backend";
UPSTREAM
docker rm -f pointy-backend-standby >/dev/null 2>&1 || true

wsl_check_backup_drives

echo "==> Starting the Pointy stack…"
docker compose --env-file .env -f docker-compose.yml up -d

# Publish the bundled client installers (Android APK + Windows installer + Linux
# tar.gz) into the volume Django serves on the LAN, so on-site devices can
# download and self-update.
if [ -d ./clients ]; then
  echo "==> Publishing client installers for LAN download…"
  if docker compose --env-file .env -f docker-compose.yml cp clients/. backend:/var/lib/pointy/clients/; then
    docker compose --env-file .env -f docker-compose.yml exec -u 0 -T backend \
      chmod -R a+rX /var/lib/pointy/clients >/dev/null 2>&1 || true
  else
    echo "WARN: could not publish client installers; retry with ./install.sh once the backend is up."
  fi
fi

# Register the boot/crash watchdog so the till self-recovers with no operator.
# Best-effort: needs root + systemd. Falls back to a printed instruction.
if command -v systemctl >/dev/null 2>&1; then
  if [ "$(id -u)" -eq 0 ]; then
    echo "==> Registering reboot/crash watchdog (systemd)…"
    bash register-autostart.sh || echo "WARN: watchdog registration failed; run 'sudo bash register-autostart.sh' manually."
  else
    echo "==> To make the stack survive reboots/crashes, run once:"
    echo "      sudo bash register-autostart.sh"
  fi
fi

cat <<'MSG'

Done. Useful follow-ups:

  Status : docker compose --env-file .env -f docker-compose.yml ps
  Logs   : docker compose --env-file .env -f docker-compose.yml logs -f backend
  Health : curl http://127.0.0.1:8000/healthz/   (web alive)
           curl http://127.0.0.1:8000/readyz/    (web + database + Redis)

Resilience: every service uses `restart: always`, and the watchdog re-runs the
stack at boot + every 5 min (recreating destroyed containers, restarting wedged
ones, and starting the Docker daemon itself if it is down). Registering the
watchdog also enables Docker on boot; if you skipped registration, run:
sudo systemctl enable docker
MSG
