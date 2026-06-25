#!/usr/bin/env bash
#
# Pointy on-prem installer (Linux / macOS hosts).
#
# Run this from inside an extracted release bundle. It loads the bundled Docker
# images (so the host never has to pull from a registry) and starts the stack.
# Re-run it any time — it is idempotent.
#
#   ./install.sh
#
set -euo pipefail
cd "$(dirname "$0")"

err() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || err "Docker is not installed or not on PATH."
docker compose version >/dev/null 2>&1 || err "Docker Compose v2 ('docker compose') is required."
docker info >/dev/null 2>&1 || err "Docker daemon is not reachable. Start Docker and try again."

echo "==> Loading Pointy container images (this can take a minute)…"
shopt -s nullglob
images=(images/*.tar)
[ ${#images[@]} -gt 0 ] || err "No image archives found under ./images. Is this a complete bundle?"
for tar in "${images[@]}"; do
  echo "    - $tar"
  docker load -i "$tar"
done

if [ ! -f .env ]; then
  cp .env.example .env
  cat <<'MSG'

A fresh .env was created from .env.example.

  >> Edit .env now: set the LAN IP, database/Redis passwords, Django secret,
     and relay settings. Replace every "replace-with-…" placeholder. <<

Then re-run ./install.sh to start the stack.
MSG
  exit 0
fi

echo "==> Starting the Pointy stack…"
docker compose --env-file .env -f docker-compose.yml up -d

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
