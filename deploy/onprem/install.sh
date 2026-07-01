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

echo "==> Loading Pointy container images (this can take a minute)…"
shopt -s nullglob
images=(images/*.tar)
[ ${#images[@]} -gt 0 ] || err "No image archives found under ./images. Is this a complete bundle?"
for tar in "${images[@]}"; do
  echo "    - $tar"
  docker load -i "$tar"
done

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

echo "==> Starting the Pointy stack…"
docker compose --env-file .env -f docker-compose.yml up -d

# Publish the bundled client installers (Android APK + Windows installer) into the
# volume Django serves on the LAN, so on-site devices can download and self-update.
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
stack at boot + every 5 min (recreating destroyed containers and restarting
wedged ones). On Linux also ensure Docker starts on boot: sudo systemctl enable docker
MSG
