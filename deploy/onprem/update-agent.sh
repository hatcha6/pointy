#!/usr/bin/env bash
#
# Pointy on-prem remote update agent (Linux / macOS hosts).
#
# Polls the relay for the version this installation should run and, when a newer
# one is assigned, downloads the bundle FROM THE RELAY (shops never need GitHub or
# a registry), verifies it, backs up the database, applies it, health-checks the
# result, and rolls back automatically on failure — so we update a shop without
# visiting it.
#
# It applies updates LIVE by default (see update-lib.sh): the new backend is
# brought up beside the running one and only takes traffic once it has answered
# /readyz, so a shop can be updated in the middle of the trading day without a
# till noticing. That matters most here — this agent fires on a timer, and
# before it could do that safely the only responsible schedule was "after
# hours". Releases that cannot be applied that way say so in the bundle and get
# a full restart instead.
#
# It runs as a host timer next to watchdog.sh and is deliberately independent of
# the backend it updates: even an update that breaks the backend leaves this
# agent able to fetch a rollback target from the relay and re-apply.
#
# Run it manually with --check to see what it WOULD do without applying:
#     bash update-agent.sh --check
#
set -uo pipefail
# Everything below is relative to the deploy directory, including a few rm -rf.
cd "$(dirname "$0")" || exit 1

# Self-update first: older bundles staged the new agent as update-agent.sh.new
# (they rewrote scripts in place, so a running one could not be replaced
# safely). Promote it and re-exec. Current bundles install scripts by atomic
# rename instead, which leaves this running process on its own inode.
if [ -f update-agent.sh.new ] && [ "${POINTY_AGENT_PROMOTED:-}" != "1" ]; then
  mv -f update-agent.sh.new update-agent.sh
  chmod +x update-agent.sh 2>/dev/null || true
  export POINTY_AGENT_PROMOTED=1
  exec bash ./update-agent.sh "$@"
fi

POINTY_LOG_TAG="pointy-update-agent"
# shellcheck source=update-lib.sh
. ./update-lib.sh

AGENT_VERSION="pointy-update-agent/2"
DRY_RUN=0
MODE=auto
for arg in "$@"; do
  case "$arg" in
    --check) DRY_RUN=1 ;;
    --restart) MODE=restart ;;
    --live) MODE=live ;;
  esac
done

fail() { pu_log "ERROR: $*"; exit 1; }

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

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

RELAY_URL="$(pu_env_value POINTY_RELAY_PUBLIC_API_URL)"
RELAY_URL="${RELAY_URL%/}"
[ -n "$RELAY_URL" ] || fail "POINTY_RELAY_PUBLIC_API_URL is not set in .env"

CURRENT_VERSION="$(pu_current_version)"

# Read this installation's connector token from the connector container. `docker
# cp` reads the container filesystem directly, so it works even though the
# connector image is `scratch` (no shell to exec into).
STATE_FILE="$(mktemp)"
STAGING=""
cleanup() {
  rm -f "$STATE_FILE"
  [ -n "$STAGING" ] && rm -rf "$STAGING"
  [ -n "${POINTY_BUNDLE_STAGING:-}" ] && rm -rf "$POINTY_BUNDLE_STAGING"
  pu_release_lock
}
trap cleanup EXIT

if ! pu_compose cp connector:/var/lib/pointy/relay-connector.json "$STATE_FILE" >/dev/null 2>&1; then
  pu_log "connector state unavailable yet (still bootstrapping?); retrying next run"
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

# 1. Ask the relay what to run.
MANIFEST_FILE="$(mktemp)"
if ! curl -fsS -H "$auth_header" "${RELAY_URL}/v1/agent/manifest" -o "$MANIFEST_FILE"; then
  rm -f "$MANIFEST_FILE"
  pu_log "manifest fetch failed; retrying next run"
  exit 0
fi
DIRECTIVE="$(jget "$MANIFEST_FILE" .directive)"
ASSIGNED="$(jget "$MANIFEST_FILE" .assigned_version)"
BUNDLE_PATH="$(jget "$MANIFEST_FILE" .bundle.path)"
BUNDLE_SHA="$(jget "$MANIFEST_FILE" .bundle.sha256)"
rm -f "$MANIFEST_FILE"

if [ "$DIRECTIVE" != "apply" ] || [ -z "$ASSIGNED" ] || [ "$ASSIGNED" = "$CURRENT_VERSION" ]; then
  pu_log "up to date (current=${CURRENT_VERSION}, directive=${DIRECTIVE}, assigned=${ASSIGNED:-none})"
  report_status "$CURRENT_VERSION" "idle" ""
  exit 0
fi

pu_log "update available: ${CURRENT_VERSION} -> ${ASSIGNED}"
if [ "$DRY_RUN" = 1 ]; then
  pu_log "--check: would download ${RELAY_URL}${BUNDLE_PATH} (sha256=${BUNDLE_SHA}) and apply ${ASSIGNED}"
  exit 0
fi
[ -n "$BUNDLE_PATH" ] || fail "manifest is missing the bundle path"

# Take the update lock before downloading: it also tells the watchdog to keep
# its hands off the stack for the duration.
pu_acquire_lock || exit 0

report_status "$CURRENT_VERSION" "applying" ""

# 2. Download the bundle from the relay (resumable) and verify its integrity.
STAGING="$(mktemp -d)"
pu_log "downloading bundle…"
if ! curl -fSL -C - -H "$auth_header" -o "${STAGING}/bundle.zip" "${RELAY_URL}${BUNDLE_PATH}"; then
  report_status "$CURRENT_VERSION" "failed" "bundle download failed"
  fail "bundle download failed"
fi
ACTUAL_SHA="$(sha256_of "${STAGING}/bundle.zip")"
if [ -n "$BUNDLE_SHA" ] && [ "$ACTUAL_SHA" != "$BUNDLE_SHA" ]; then
  report_status "$CURRENT_VERSION" "failed" "sha256 mismatch"
  fail "sha256 mismatch (want ${BUNDLE_SHA}, got ${ACTUAL_SHA})"
fi

pu_stage_bundle "${STAGING}/bundle.zip" || {
  report_status "$CURRENT_VERSION" "failed" "bundle could not be staged"
  fail "bundle could not be staged"
}

# 3. Apply (backup, adopt, live flip or restart, rollback on failure).
if pu_apply_bundle "$POINTY_BUNDLE_DIR" "$CURRENT_VERSION" "$ASSIGNED" "$MODE"; then
  report_status "$ASSIGNED" "succeeded" ""
  exit 0
fi
report_status "$(pu_current_version)" "failed" "update to ${ASSIGNED} failed"
exit 1
