#!/usr/bin/env bash
#
# Pointy uptime watchdog (Linux / macOS).
#
# Keeps the till online with zero manual intervention. It is idempotent and
# meant to run at boot and on a short timer (see register-autostart.sh). Every
# run it:
#   0. starts the Docker daemon if it is installed but not running,
#   1. waits for the Docker daemon (it may still be coming up after a reboot),
#   2. runs `docker compose up -d --no-recreate` — which (re)creates any
#      container that crashed into a stopped state OR was destroyed/removed
#      entirely, without ever REPLACING a container that is running happily,
#   3. puts the LAN front door back on the managed backend if a live update was
#      interrupted and left it pointing at a container that no longer exists, and
#   4. restarts any container that is running but stuck "unhealthy" (Docker's
#      own restart policy does NOT act on failed health checks).
#
# It is availability, not convergence: `--no-recreate` is deliberate. Without it
# the watchdog would silently apply any pending configuration or image change
# at whatever minute its timer next fired — restarting the database under a
# trading shop to "fix" a drift nobody asked it to fix. Applying changes is
# install.sh's and update.sh's job, at a moment somebody chose.
#
# Layer this on top of `restart: always` in the compose file: the restart
# policy gives instant in-place crash recovery, and the watchdog catches
# everything the restart policy cannot (host reboot, removed containers, wedged
# processes, the daemon not being up yet or stopped).
#
set -uo pipefail
# Everything below is relative to the deploy directory.
cd "$(dirname "$0")" || exit 1

PROJECT="${COMPOSE_PROJECT_NAME:-pointy}"
COMPOSE=(docker compose --env-file .env -f docker-compose.yml)

# Heal debounce: a container must stay "unhealthy" for the WHOLE re-verify window
# below before we restart it. A single failed health check (a brief DB/Redis
# hiccup or a load spike that makes /readyz/ slow) must never cost a SIGTERM —
# `restart: always` already recovers real crashes. Tune via env if needed.
HEAL_GRACE_TRIES="${POINTY_WATCHDOG_HEAL_TRIES:-6}"    # re-checks per container
HEAL_GRACE_SLEEP="${POINTY_WATCHDOG_HEAL_SLEEP:-10}"   # seconds between re-checks
# Space-separated container-name substrings the watchdog must NEVER restart on an
# unhealthy status (empty = heal everything after the grace window).
HEAL_SKIP="${POINTY_WATCHDOG_HEAL_SKIP:-}"

log() { printf '%s [pointy-watchdog] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*"; }

# An update in flight owns the stack. Reconciling underneath it would fight it
# for the backend container mid-flip, so stand down — but only while the lock is
# fresh, so an update killed by a power cut cannot disable the watchdog for good.
UPDATE_LOCK=".update.lock"
UPDATE_LOCK_MAX_AGE="${POINTY_UPDATE_LOCK_MAX_AGE:-3600}"
update_in_progress() {
  [ -f "$UPDATE_LOCK" ] || return 1
  local mtime age
  mtime="$(stat -c %Y "$UPDATE_LOCK" 2>/dev/null || stat -f %m "$UPDATE_LOCK" 2>/dev/null || echo 0)"
  age=$(( $(date +%s) - mtime ))
  if [ "$age" -lt "$UPDATE_LOCK_MAX_AGE" ]; then
    return 0
  fi
  log "ignoring a stale update lock (${age}s old)"
  return 1
}

# A live update points the LAN front door at a temporary container while it
# swaps the backend. That container is not managed by compose and does not come
# back after a reboot, so if the update died in the middle, the front door would
# keep proxying to something that no longer exists — the shop's tills would see
# 502s with a perfectly healthy backend sitting right there. Put it back.
heal_front_door() {
  local pointer="edge/active/upstream.conf" target
  [ -f "$pointer" ] || return 0
  target="$(sed -n 's/^set \$pointy_upstream_name *"\([^"]*\)".*/\1/p' "$pointer" | head -1)"
  [ -n "$target" ] || return 0
  [ "$target" = "backend" ] && return 0
  if [ "$(docker inspect -f '{{.State.Running}}' "$target" 2>/dev/null)" = "true" ]; then
    return 0
  fi
  log "front door points at ${target}, which is not running; restoring the managed backend"
  cat >"$pointer" <<'UPSTREAM'
# GENERATED — restored by watchdog.sh after an interrupted live update.
set $pointy_upstream      "http://backend:8000";
set $pointy_upstream_name "backend";
UPSTREAM
  "${COMPOSE[@]}" exec -T edge nginx -s reload >/dev/null 2>&1 \
    || log "could not reload the front door; it will pick this up when it restarts"
}

# Current health of a container: "healthy" / "unhealthy" / "starting" / "none".
container_health() {
  docker inspect \
    --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
    "$1" 2>/dev/null || echo missing
}

# 0. Start the daemon if it is down: systemd hosts (Linux, and the WSL distro
#    on Windows) get `systemctl start docker` — the timer runs this script as
#    root — and macOS hosts get Docker Desktop (best-effort).
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

if update_in_progress; then
  log "an update is in progress; standing down until it finishes."
  exit 0
fi

# 2. Reconcile: start anything missing, stopped, or destroyed — but never
#    replace a running container (see the header).
log "reconciling stack (compose up -d --no-recreate)…"
"${COMPOSE[@]}" up -d --no-recreate --remove-orphans

# 2b. Undo a half-finished live update, if one died leaving traffic pointed at a
#     container that is gone.
heal_front_door

# 3. Heal: restart project containers that are running but unhealthy — but only
#    after the unhealthy state PERSISTS through a re-verify window. Docker marks a
#    container unhealthy after one failed check; that alone must not trigger a
#    restart, or a transient /readyz/ blip (DB/Redis momentarily busy, a load
#    spike) SIGTERMs the backend. We re-poll each candidate for
#    HEAL_GRACE_TRIES × HEAL_GRACE_SLEEP seconds and skip the restart the instant
#    it recovers. Containers matching HEAL_SKIP are never restarted this way.
#    The oneoff filter excludes the temporary container a live update runs the
#    new backend in: it belongs to the updater, which is watching it far more
#    closely than this loop can.
mapfile -t unhealthy < <(
  docker ps \
    --filter "label=com.docker.compose.project=${PROJECT}" \
    --filter "label=com.docker.compose.oneoff=False" \
    --filter "health=unhealthy" \
    --format '{{.ID}} {{.Names}}'
)
if [ "${#unhealthy[@]}" -gt 0 ]; then
  for row in "${unhealthy[@]}"; do
    id="${row%% *}"; name="${row#* }"

    skip=false
    for token in ${HEAL_SKIP}; do
      case "${name}" in *"${token}"*) skip=true ;; esac
    done
    if [ "${skip}" = true ]; then
      log "container ${name} unhealthy but in HEAL_SKIP; leaving it alone"
      continue
    fi

    recovered=false
    for _ in $(seq 1 "${HEAL_GRACE_TRIES}"); do
      sleep "${HEAL_GRACE_SLEEP}"
      status="$(container_health "${id}")"
      if [ "${status}" != "unhealthy" ]; then
        log "container ${name} recovered (health=${status}); not restarting"
        recovered=true
        break
      fi
    done

    if [ "${recovered}" = false ]; then
      log "container ${name} stayed unhealthy ~$((HEAL_GRACE_TRIES * HEAL_GRACE_SLEEP))s; restarting"
      docker restart "${id}" >/dev/null || log "failed to restart ${name}"
    fi
  done
fi

log "run complete."
