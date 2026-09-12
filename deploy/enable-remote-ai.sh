#!/usr/bin/env bash
# Grant THIS dev installation its entitlements on the REMOTE (company) relay.
#
# `make dev-remote` runs the backend against the real company relay, where it
# self-enrols with a license key. That enrolment deliberately grants nothing:
# a shop that has not paid gets no AI and no remote-access features, and the
# relay answers 402 "relay subscription inactive" to both. A developer running
# the stack is not that shop, so this asks the relay's admin API to turn the
# entitlements on for this one installation and syncs the answer into Django.
#
# What it unlocks, both gated by the same entitlement pair:
#   * the AI assistant (ai_enabled)
#   * relay-hosted product image search (rides remote access: relay_enabled +
#     subscription_active)
#
# Needs RELAY_REMOTE_ADMIN_TOKEN — the company relay's admin bearer token, which
# is not in the repo. Without it this prints how to get going and exits 0, so
# `make dev-remote` still brings the stack up; you just get the locked build.
#
# Idempotent. Safe to re-run, and safe to leave wired into `make dev-remote`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MANAGE=(backend/.venv/bin/python backend/manage.py)
BACKEND_HEALTH_URL="${BACKEND_HEALTH_URL:-http://127.0.0.1:8000/healthz/}"
RELAY_REMOTE_HOST="${RELAY_REMOTE_HOST:-env-9493505.tip2.libyanspider.cloud}"
ADMIN_TOKEN="${RELAY_REMOTE_ADMIN_TOKEN:-}"
CONTROL_URL="${RELAY_REMOTE_CONTROL_URL:-https://$RELAY_REMOTE_HOST}"

if [ -z "$ADMIN_TOKEN" ]; then
  cat <<MSG

ℹ️  Skipping the remote entitlement step: RELAY_REMOTE_ADMIN_TOKEN is not set.

   The stack still runs, but the relay will answer 402 to anything that needs a
   subscription — the AI assistant stays locked and product image search returns
   503 ("unavailable right now").

   To unlock, re-run with the company relay's admin token:
       make dev-remote RELAY_REMOTE_ADMIN_TOKEN=…
   or, against an already-running stack:
       make ai-enable-remote RELAY_REMOTE_ADMIN_TOKEN=…

MSG
  exit 0
fi

printf 'Waiting for the backend'
tries=0
until curl -fsS -o /dev/null "$BACKEND_HEALTH_URL" 2>/dev/null; do
  tries=$((tries + 1))
  if [ "$tries" -gt 150 ]; then
    printf '\n  backend did not become healthy at %s after 150s.\n' "$BACKEND_HEALTH_URL" >&2
    exit 1
  fi
  printf '.'
  sleep 1
done
printf ' ready.\n'

# Reuses the installation the backend already self-enrolled; this never calls
# the admin API and never creates a second one.
echo "==> Reading this installation's id…"
INSTALLATION_ID="$("${MANAGE[@]}" relay_provision | tail -n1)"
if [ -z "$INSTALLATION_ID" ]; then
  echo "Could not determine the relay installation id — is the backend enrolled?" >&2
  exit 1
fi
echo "    $INSTALLATION_ID"

echo "==> Enabling AI + remote access on $RELAY_REMOTE_HOST…"
(
  cd relay &&
    GOCACHE="$ROOT/relay/.gocache" GOMODCACHE="$ROOT/relay/.gomodcache" \
      go run ./cmd/pointy-relay subscription update \
      --control-url "$CONTROL_URL" \
      --admin-token "$ADMIN_TOKEN" \
      --installation-id "$INSTALLATION_ID" \
      --actor "dev-remote" \
      --reason "local development against the remote relay" \
      --ai-enabled=true \
      --relay-enabled=true \
      --subscription-active=true
)

echo "==> Syncing the entitlement into Django…"
"${MANAGE[@]}" relay_sync

cat <<DONE

✅ AI + product image search are unlocked for installation $INSTALLATION_ID.
   The running app picks this up on its next settings refresh (or reload it).

DONE
