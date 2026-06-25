#!/usr/bin/env bash
# One-time local setup that makes the AI assistant usable end to end:
#   1. waits for the relay and backend to be healthy,
#   2. ensures a local manager account exists,
#   3. provisions the relay installation (stores the access token in Django),
#   4. enables the AI entitlement on the relay,
#   5. syncs the entitlement back into Django.
#
# Idempotent — safe to re-run. Run it on its own (once the stack is up) or let
# `make dev-ai` run it automatically alongside the services.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MANAGE=(backend/.venv/bin/python backend/manage.py)
RELAY_HEALTH_URL="${RELAY_HEALTH_URL:-http://127.0.0.1:8091/healthz}"
BACKEND_HEALTH_URL="${BACKEND_HEALTH_URL:-http://127.0.0.1:8000/healthz/}"
ADMIN_USERNAME="${POINTY_ADMIN_USERNAME:-admin}"
ADMIN_PASSWORD="${POINTY_ADMIN_PASSWORD:-admin12345}"

wait_for() {
  local label="$1" url="$2" tries=0
  printf 'Waiting for %s' "$label"
  until curl -fsS -o /dev/null "$url" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -gt 150 ]; then
      printf '\n  %s did not become healthy at %s after 150s.\n' "$label" "$url" >&2
      exit 1
    fi
    printf '.'
    sleep 1
  done
  printf ' ready.\n'
}

wait_for "relay" "$RELAY_HEALTH_URL"
wait_for "backend" "$BACKEND_HEALTH_URL"

echo "==> Ensuring a local manager exists ($ADMIN_USERNAME)…"
"${MANAGE[@]}" bootstrap_admin --username "$ADMIN_USERNAME" --password "$ADMIN_PASSWORD" || true

echo "==> Provisioning the relay installation…"
INSTALLATION_ID="$("${MANAGE[@]}" relay_provision | tail -n1)"
if [ -z "$INSTALLATION_ID" ]; then
  echo "Could not determine the relay installation id." >&2
  exit 1
fi

echo "==> Enabling the AI + remote-access entitlements on the relay…"
# relay-enabled is what gates relay-hosted product image search (it rides the
# remote-access entitlement), so enable it here too for an out-of-the-box dev run.
(
  cd relay &&
    GOCACHE="$ROOT/relay/.gocache" GOMODCACHE="$ROOT/relay/.gomodcache" \
      go run ./cmd/pointy-relay subscription update \
      --allow-insecure-control=true \
      --installation-id "$INSTALLATION_ID" \
      --actor "local-dev" \
      --reason "local AI + image search testing" \
      --ai-enabled=true \
      --relay-enabled=true \
      --subscription-active=true
)

echo "==> Syncing the entitlement into Django…"
"${MANAGE[@]}" relay_sync

cat <<DONE

✅ AI + product image search are enabled locally (installation $INSTALLATION_ID).
   1. Open   http://127.0.0.1:8080
   2. Sign in as   $ADMIN_USERNAME / $ADMIN_PASSWORD
   3. Open   "المساعد الذكي"   from the drawer and start chatting.

   (AI replies need an OpenRouter key, and product image search needs a
    Serper key — POINTY_RELAY_SERPER_API_KEY — both in relay/.env.)
DONE
