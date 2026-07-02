#!/usr/bin/env bash
#
# Pointy uptime watchdog (Linux / macOS).
#
# Keeps the till online with zero manual intervention. It is idempotent and
# meant to run at boot and on a short timer (see register-autostart.sh). Every
# run it:
#   0. starts the Docker daemon if it is installed but not running,
#   1. waits for the Docker daemon (it may still be coming up after a reboot),
#   2. runs `docker compose up -d` — which (re)creates any container that
#      crashed into a stopped state OR was destroyed/removed entirely, and
#   3. restarts any container that is running but stuck "unhealthy" (Docker's
#      own restart policy does NOT act on failed health checks).
#
# Layer this on top of `restart: always` in the compose file: the restart
# policy gives instant in-place crash recovery, and the watchdog catches
# everything the restart policy cannot (host reboot, removed containers, wedged
# processes, the daemon not being up yet or stopped).
#
set -uo pipefail
cd "$(dirname "$0")"

PROJECT="${COMPOSE_PROJECT_NAME:-pointy}"
COMPOSE=(docker compose --env-file .env -f docker-compose.yml)

log() { printf '%s [pointy-watchdog] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*"; }

# 0. Start the daemon if it is down (mirrors watchdog.ps1 starting Docker
#    Desktop): systemd Linux hosts get `systemctl start docker` (the timer runs
#    this script as root), macOS hosts get Docker Desktop (best-effort).
if ! docker info >/dev/null 2>&1; then
  if command -v systemctl >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
    log "Docker daemon is down; starting docker.service…"
    systemctl start docker >/dev/null 2>&1 || true
  elif [ "$(uname -s)" = "Darwin" ] && [ -d "/Applications/Docker.app" ]; then
    log "Docker daemon is down; starting Docker Desktop…"
    open -a Docker >/dev/null 2>&1 || true
  fi
fi

# 1. Wait for the Docker daemon (up to ~5 minutes).
for i in $(seq 1 60); do
  if docker info >/dev/null 2>&1; then break; fi
  log "waiting for Docker daemon ($i/60)…"
  sleep 5
done
if ! docker info >/dev/null 2>&1; then
  log "Docker daemon not reachable; will retry on the next run."
  exit 1
fi

if [ ! -f .env ]; then
  log ".env not found next to this script; cannot manage the stack."
  exit 1
fi

# 2. Reconcile: start/recreate anything missing, stopped, or destroyed.
log "reconciling stack (compose up -d)…"
"${COMPOSE[@]}" up -d --remove-orphans

# 3. Heal: restart project containers that are running but unhealthy.
mapfile -t unhealthy < <(
  docker ps \
    --filter "label=com.docker.compose.project=${PROJECT}" \
    --filter "health=unhealthy" \
    --format '{{.ID}} {{.Names}}'
)
if [ "${#unhealthy[@]}" -gt 0 ]; then
  for row in "${unhealthy[@]}"; do
    id="${row%% *}"; name="${row#* }"
    log "restarting unhealthy container: ${name}"
    docker restart "${id}" >/dev/null || log "failed to restart ${name}"
  done
fi

log "run complete."
