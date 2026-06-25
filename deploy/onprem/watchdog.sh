#!/usr/bin/env bash
#
# Pointy uptime watchdog (Linux / macOS).
#
# Keeps the till online with zero manual intervention. It is idempotent and
# meant to run at boot and on a short timer (see register-autostart.sh). Every
# run it:
#   1. waits for the Docker daemon (it may still be coming up after a reboot),
#   2. runs `docker compose up -d` — which (re)creates any container that
#      crashed into a stopped state OR was destroyed/removed entirely, and
#   3. restarts any container that is running but stuck "unhealthy" (Docker's
#      own restart policy does NOT act on failed health checks).
#
# Layer this on top of `restart: always` in the compose file: the restart
# policy gives instant in-place crash recovery, and the watchdog catches
# everything the restart policy cannot (host reboot, removed containers, wedged
# processes, the daemon not being up yet).
#
set -uo pipefail
cd "$(dirname "$0")"

PROJECT="${COMPOSE_PROJECT_NAME:-pointy}"
COMPOSE=(docker compose --env-file .env -f docker-compose.yml)

log() { printf '%s [pointy-watchdog] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*"; }

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
