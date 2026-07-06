#!/usr/bin/env bash
#
# Fixes the "backend goes down every N minutes" outages on an existing
# Pointy on-prem install (Linux). Mirrors fix-backend-outages.ps1.
#
# ROOT CAUSE — not the watchdog. The backend's ASGI workers were configured
# to self-terminate after 1000 requests (POINTY_ASGI_MAX_REQUESTS=1000).
# Steady polling from the tills drives all workers to that limit at nearly the
# same moment, so the whole API dies together and stays down for the length of
# a Django cold start — at fixed wall-clock intervals. When the gap dragged
# on, the container was also flagged unhealthy and restarted (by design).
# The watchdog is what BRINGS THE STACK BACK after reboots/power cuts — keep
# it; to disable it anyway, use disable-watchdog.sh.
#
# This script:
#   1. sets POINTY_ASGI_MAX_REQUESTS=0 (and its jitter) in .env — recycling off,
#   2. recreates the backend container so the change takes effect,
#   3. shows how to confirm the diagnosis from the old logs.
#
# Run from the bundle directory (next to docker-compose.yml):
#     bash fix-backend-outages.sh
set -euo pipefail
cd "$(dirname "$0")"

log() { printf '%s [pointy-fix] %s\n' "$(date -Is)" "$1"; }
err() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

[ -f ".env" ] || err ".env not found next to this script."
[ -f "docker-compose.yml" ] || err "docker-compose.yml not found — run this from the Pointy deploy directory."
command -v docker >/dev/null 2>&1 || err "Docker is not installed."

# --- 1. Pin recycling off in .env (add the keys if they are missing). -------
set_env_key() {
  local key="$1" value="$2"
  if grep -q "^${key}=" .env; then
    # BSD/GNU sed portability: write via a temp file.
    sed "s/^${key}=.*/${key}=${value}/" .env > .env.tmp && mv .env.tmp .env
    log "set ${key}=${value}"
  else
    printf '%s=%s\n' "${key}" "${value}" >> .env
    log "added ${key}=${value}"
  fi
}
set_env_key "POINTY_ASGI_MAX_REQUESTS" "0"
set_env_key "POINTY_ASGI_MAX_REQUESTS_JITTER" "0"

# --- 2. Show the proof in the CURRENT logs before restarting. ---------------
log "checking the old logs for the worker-recycle signature..."
signature_count="$(docker compose --env-file .env -f docker-compose.yml logs backend --tail 2000 2>/dev/null | grep -c "Maximum request limit" || true)"
if [ "${signature_count:-0}" -gt 0 ]; then
  log "CONFIRMED: found ${signature_count} worker-recycle event(s) in the recent backend logs."
else
  log "no recycle lines in the recent log window (they may have rotated out) — the fix applies either way."
fi

# --- 3. Recreate the backend with the new setting. ---------------------------
log "recreating the backend container..."
docker compose --env-file .env -f docker-compose.yml up -d backend

log "waiting for the backend to come back..."
healthy=0
for _ in $(seq 1 36); do
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 5 "http://127.0.0.1:8000/readyz/" >/dev/null 2>&1 && { healthy=1; break; }
  else
    docker compose --env-file .env -f docker-compose.yml exec -T backend \
      python /app/backend/docker/healthcheck.py "http://127.0.0.1:8000/readyz/" >/dev/null 2>&1 && { healthy=1; break; }
  fi
  sleep 5
done
[ "$healthy" -eq 1 ] || err "backend did not become ready within 3 minutes — check 'docker compose logs backend'."

log "done. Workers no longer self-terminate; the interval outages stop here."
log "The watchdog timer stays enabled (it is the reboot/power-cut recovery)."
