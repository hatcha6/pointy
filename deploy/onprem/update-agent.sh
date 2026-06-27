#!/usr/bin/env bash
#
# Pointy on-prem remote update agent (Linux / macOS hosts).
#
# Polls the relay for the version this installation should run and, when a newer
# one is assigned, downloads the bundle FROM THE RELAY (shops never need GitHub or
# a registry), verifies it, backs up the database, applies it (docker load +
# compose up), health-checks the result, and rolls back automatically on failure
# — so we update a shop without visiting it. It runs as a host timer next to
# watchdog.sh and is deliberately independent of the backend it updates: even an
# update that breaks the backend leaves this agent able to fetch a rollback
# target from the relay and re-apply.
#
# Run it manually with --check to see what it WOULD do without applying:
#     bash update-agent.sh --check
#
set -uo pipefail
cd "$(dirname "$0")"

AGENT_VERSION="pointy-update-agent/1"
COMPOSE=(docker compose --env-file .env -f docker-compose.yml)
DRY_RUN=0
[ "${1:-}" = "--check" ] && DRY_RUN=1

log() { printf '%s [pointy-update-agent] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*"; }
fail() {
  log "ERROR: $*"
  exit 1
}

# Self-update first: an update bundle stages the new agent as update-agent.sh.new
# (we never rewrite a running bash script in place). Promote it and re-exec.
if [ -f update-agent.sh.new ] && [ "${POINTY_AGENT_PROMOTED:-}" != "1" ]; then
  mv -f update-agent.sh.new update-agent.sh
  chmod +x update-agent.sh 2>/dev/null || true
  export POINTY_AGENT_PROMOTED=1
  exec bash ./update-agent.sh "$@"
fi

command -v docker >/dev/null 2>&1 || fail "docker not found on PATH"
[ -f .env ] || fail ".env not found next to this script"
if ! command -v jq >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
  fail "need jq or python3 to parse relay responses"
fi

# jget <json-file> <dotted.path> — extract a field with jq, else python3.
jget() {
  local file="$1" path="$2"
  if command -v jq >/dev/null 2>&1; then
    jq -r "${path} // empty" "$file" 2>/dev/null
    return
  fi
  python3 - "$file" "$path" <<'PY'
import sys, json
path = sys.argv[2].lstrip('.').split('.')
try:
    with open(sys.argv[1]) as handle:
        value = json.load(handle)
    for key in path:
        value = value[key]
    print('' if value is None else value)
except Exception:
    print('')
PY
}

env_value() {
  grep -E "^$1=" .env | head -1 | cut -d= -f2- | tr -d '"' | tr -d '\r'
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

RELAY_URL="$(env_value POINTY_RELAY_PUBLIC_API_URL)"
RELAY_URL="${RELAY_URL%/}"
[ -n "$RELAY_URL" ] || fail "POINTY_RELAY_PUBLIC_API_URL is not set in .env"

CURRENT_VERSION="unknown"
[ -f VERSION.txt ] && CURRENT_VERSION="$(tr -d '[:space:]' <VERSION.txt)"

# Read this installation's connector token from the connector container. `docker
# cp` reads the container filesystem directly, so it works even though the
# connector image is `scratch` (no shell to exec into).
STATE_FILE="$(mktemp)"
cleanup() { rm -f "$STATE_FILE"; }
trap cleanup EXIT
if ! "${COMPOSE[@]}" cp connector:/var/lib/pointy/relay-connector.json "$STATE_FILE" >/dev/null 2>&1; then
  log "connector state unavailable yet (still bootstrapping?); retrying next run"
  exit 0
fi
CONNECTOR_TOKEN="$(jget "$STATE_FILE" .connector_token)"
[ -n "$CONNECTOR_TOKEN" ] || fail "connector token not found in connector state"

auth_header="X-Pointy-Connector-Token: ${CONNECTOR_TOKEN}"

report_status() { # report_status <current_version> <status> <error>
  curl -fsS -X POST \
    -H "$auth_header" \
    -H "Content-Type: application/json" \
    -d "{\"current_version\":\"$1\",\"agent_version\":\"${AGENT_VERSION}\",\"update_status\":\"$2\",\"update_error\":\"$3\"}" \
    "${RELAY_URL}/v1/agent/status" >/dev/null 2>&1 || true
}

healthy() {
  for _ in $(seq 1 60); do
    if curl -fsS http://127.0.0.1:8000/readyz/ >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done
  return 1
}

# 1. Ask the relay what to run.
MANIFEST_FILE="$(mktemp)"
if ! curl -fsS -H "$auth_header" "${RELAY_URL}/v1/agent/manifest" -o "$MANIFEST_FILE"; then
  rm -f "$MANIFEST_FILE"
  log "manifest fetch failed; retrying next run"
  exit 0
fi
DIRECTIVE="$(jget "$MANIFEST_FILE" .directive)"
ASSIGNED="$(jget "$MANIFEST_FILE" .assigned_version)"
BUNDLE_PATH="$(jget "$MANIFEST_FILE" .bundle.path)"
BUNDLE_SHA="$(jget "$MANIFEST_FILE" .bundle.sha256)"
rm -f "$MANIFEST_FILE"

if [ "$DIRECTIVE" != "apply" ] || [ -z "$ASSIGNED" ] || [ "$ASSIGNED" = "$CURRENT_VERSION" ]; then
  log "up to date (current=${CURRENT_VERSION}, directive=${DIRECTIVE}, assigned=${ASSIGNED:-none})"
  report_status "$CURRENT_VERSION" "idle" ""
  exit 0
fi

log "update available: ${CURRENT_VERSION} -> ${ASSIGNED}"
if [ "$DRY_RUN" = 1 ]; then
  log "--check: would download ${RELAY_URL}${BUNDLE_PATH} (sha256=${BUNDLE_SHA}) and apply ${ASSIGNED}"
  exit 0
fi
[ -n "$BUNDLE_PATH" ] || fail "manifest is missing the bundle path"

report_status "$CURRENT_VERSION" "applying" ""

STAGING="$(mktemp -d)"
cleanup() {
  rm -f "$STATE_FILE"
  rm -rf "$STAGING"
}
trap cleanup EXIT

# 2. Download the bundle from the relay (resumable) and verify its integrity.
log "downloading bundle…"
if ! curl -fSL -C - -H "$auth_header" -o "${STAGING}/bundle.zip" "${RELAY_URL}${BUNDLE_PATH}"; then
  report_status "$CURRENT_VERSION" "failed" "bundle download failed"
  fail "bundle download failed"
fi
ACTUAL_SHA="$(sha256_of "${STAGING}/bundle.zip")"
if [ -n "$BUNDLE_SHA" ] && [ "$ACTUAL_SHA" != "$BUNDLE_SHA" ]; then
  report_status "$CURRENT_VERSION" "failed" "sha256 mismatch"
  fail "sha256 mismatch (want ${BUNDLE_SHA}, got ${ACTUAL_SHA})"
fi
command -v unzip >/dev/null 2>&1 || fail "unzip not found on PATH"
unzip -q -o "${STAGING}/bundle.zip" -d "${STAGING}/bundle" || fail "could not unzip bundle"
BUNDLE_DIR="$(find "${STAGING}/bundle" -maxdepth 1 -type d -name 'pointy-onprem-*' | head -1)"
[ -n "$BUNDLE_DIR" ] || BUNDLE_DIR="${STAGING}/bundle"
[ -d "${BUNDLE_DIR}/images" ] || fail "bundle has no images/ directory"

# 3. Back up the database before any migration runs (best-effort; a forward
# migration is the one thing rollback can't fully auto-heal).
mkdir -p backups
backup="backups/pre-update-${CURRENT_VERSION}-to-${ASSIGNED}.sql"
if "${COMPOSE[@]}" exec -T postgres sh -c 'pg_dump -U "${POSTGRES_USER:-pointy}" "${POSTGRES_DB:-pointy}"' >"$backup" 2>/dev/null; then
  log "database backed up to ${backup}"
else
  rm -f "$backup"
  log "WARN: database backup failed; continuing (rollback restores images, not data)"
fi

# 4. Snapshot the current config for rollback (old images stay loaded in Docker).
SNAPSHOT="$(mktemp -d)"
cp .env "${SNAPSHOT}/.env"
[ -f docker-compose.yml ] && cp docker-compose.yml "${SNAPSHOT}/docker-compose.yml"

# 5. Apply: adopt the new bundle's files (keeping .env + volumes), pin the new
# image tags, then run the bundle's own installer (docker load + compose up).
for file in docker-compose.yml install.sh watchdog.sh register-autostart.sh .env.example VERSION.txt INSTALL.md README.md; do
  [ -f "${BUNDLE_DIR}/${file}" ] && cp -f "${BUNDLE_DIR}/${file}" "./${file}"
done
rm -rf ./images
cp -R "${BUNDLE_DIR}/images" ./images
# Refresh the bundled client installers so a backend update also updates the
# Android/Windows clients the shop serves on its LAN (install.sh publishes them).
if [ -d "${BUNDLE_DIR}/clients" ]; then
  rm -rf ./clients
  cp -R "${BUNDLE_DIR}/clients" ./clients
fi
# Stage the agent's own next version without overwriting this running script.
[ -f "${BUNDLE_DIR}/update-agent.sh" ] && cp -f "${BUNDLE_DIR}/update-agent.sh" ./update-agent.sh.new
[ -f "${BUNDLE_DIR}/update-agent.ps1" ] && cp -f "${BUNDLE_DIR}/update-agent.ps1" ./update-agent.ps1

sed -i.bak -E \
  -e "s|^POINTY_BACKEND_IMAGE=.*|POINTY_BACKEND_IMAGE=pointy-backend:${ASSIGNED}|" \
  -e "s|^POINTY_RELAY_IMAGE=.*|POINTY_RELAY_IMAGE=pointy-relay:${ASSIGNED}|" \
  -e "s|^POINTY_WEB_IMAGE=.*|POINTY_WEB_IMAGE=pointy-web:${ASSIGNED}|" \
  .env
rm -f .env.bak

log "applying ${ASSIGNED}…"
if bash ./install.sh && healthy; then
  echo "${ASSIGNED}" >VERSION.txt
  report_status "$ASSIGNED" "succeeded" ""
  log "updated to ${ASSIGNED}"
  exit 0
fi

# 6. Roll back: restore the previous config and bring the old images back up.
log "update to ${ASSIGNED} failed health check; rolling back to ${CURRENT_VERSION}"
cp -f "${SNAPSHOT}/.env" .env
[ -f "${SNAPSHOT}/docker-compose.yml" ] && cp -f "${SNAPSHOT}/docker-compose.yml" docker-compose.yml
"${COMPOSE[@]}" up -d --remove-orphans || true
if healthy; then
  report_status "$CURRENT_VERSION" "failed" "update to ${ASSIGNED} failed; rolled back"
  fail "update to ${ASSIGNED} failed; rolled back to ${CURRENT_VERSION}"
fi
report_status "$CURRENT_VERSION" "failed" "update to ${ASSIGNED} failed AND rollback unhealthy"
fail "update to ${ASSIGNED} failed and rollback is unhealthy — manual intervention needed"
