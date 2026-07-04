#!/usr/bin/env bash
#
# Pointy on-prem manual updater (Linux / macOS hosts).
#
# Applies a newer release bundle to THIS deployment — same safety rails as the
# remote update agent (database backup, config snapshot, health check,
# automatic rollback), but fed from a bundle you carry to the machine instead
# of one assigned by the relay. Use it for shops without internet/relay, or to
# update on your own schedule:
#
#     bash update.sh /path/to/pointy-onprem-1.5.0.zip
#     bash update.sh /path/to/extracted/pointy-onprem-1.5.0/
#
# Run it from the CURRENT deploy directory (next to docker-compose.yml + .env).
# Data (.env, volumes, backups) is preserved; only images + scripts change.
# Re-applying the already-installed version needs --force.
set -uo pipefail
cd "$(dirname "$0")"

COMPOSE=(docker compose --env-file .env -f docker-compose.yml)

log() { printf '%s [pointy-update] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*"; }
fail() {
  log "ERROR: $*"
  exit 1
}

SOURCE="${1:-}"
FORCE=0
[ "${2:-}" = "--force" ] && FORCE=1
[ -n "$SOURCE" ] || fail "usage: bash update.sh <pointy-onprem-bundle.zip | bundle-dir> [--force]"
[ -e "$SOURCE" ] || fail "bundle not found: $SOURCE"
command -v docker >/dev/null 2>&1 || fail "docker not found on PATH"
[ -f .env ] || fail ".env not found next to this script — run from the deploy directory"

CURRENT_VERSION="unknown"
[ -f VERSION.txt ] && CURRENT_VERSION="$(tr -d '[:space:]' <VERSION.txt)"

healthy() {
  for _ in $(seq 1 60); do
    if curl -fsS http://127.0.0.1:8000/readyz/ >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done
  return 1
}

# Re-register autostart after every update so services the new bundle ships
# (watchdog, update agent, LAN discovery responder) are installed without
# anyone having to remember it. Idempotent; needs root + systemd.
register_autostart() {
  command -v systemctl >/dev/null 2>&1 || return 0
  if [ "$(id -u)" -eq 0 ]; then
    log "re-registering autostart services…"
    bash ./register-autostart.sh \
      || log "WARN: autostart registration failed; run 'sudo bash register-autostart.sh' manually"
  else
    log "NOTE: not running as root — run 'sudo bash register-autostart.sh' once so"
    log "      services added by this update (e.g. the LAN discovery responder) are registered."
  fi
}

# 1. Stage the bundle (accept a zip or an already-extracted directory).
STAGING=""
cleanup() { [ -n "$STAGING" ] && rm -rf "$STAGING"; }
trap cleanup EXIT
if [ -d "$SOURCE" ]; then
  BUNDLE_DIR="$SOURCE"
else
  command -v unzip >/dev/null 2>&1 || fail "unzip not found on PATH"
  STAGING="$(mktemp -d)"
  log "extracting $(basename "$SOURCE")…"
  unzip -q -o "$SOURCE" -d "$STAGING" || fail "could not unzip bundle"
  BUNDLE_DIR="$(find "$STAGING" -maxdepth 1 -type d -name 'pointy-onprem-*' | head -1)"
  [ -n "$BUNDLE_DIR" ] || BUNDLE_DIR="$STAGING"
fi
[ -d "${BUNDLE_DIR}/images" ] || fail "not a Pointy bundle: no images/ directory in ${BUNDLE_DIR}"
ASSIGNED="unknown"
[ -f "${BUNDLE_DIR}/VERSION.txt" ] && ASSIGNED="$(tr -d '[:space:]' <"${BUNDLE_DIR}/VERSION.txt")"
if [ "$ASSIGNED" = "$CURRENT_VERSION" ] && [ "$FORCE" != 1 ]; then
  fail "already on ${CURRENT_VERSION}; pass --force to re-apply"
fi
log "updating ${CURRENT_VERSION} -> ${ASSIGNED}"

# 2. Back up the database before any migration runs (best-effort; a forward
# migration is the one thing rollback can't fully auto-heal).
mkdir -p backups
backup="backups/pre-update-${CURRENT_VERSION}-to-${ASSIGNED}.sql"
if "${COMPOSE[@]}" exec -T postgres sh -c 'pg_dump -U "${POSTGRES_USER:-pointy}" "${POSTGRES_DB:-pointy}"' >"$backup" 2>/dev/null; then
  log "database backed up to ${backup}"
else
  rm -f "$backup"
  log "WARN: database backup failed (stack down?); continuing — rollback restores images, not data"
fi

# 3. Snapshot the current config for rollback (old images stay loaded in Docker).
SNAPSHOT="$(mktemp -d)"
cp .env "${SNAPSHOT}/.env"
[ -f docker-compose.yml ] && cp docker-compose.yml "${SNAPSHOT}/docker-compose.yml"

# 4. Apply: adopt the new bundle's files (keeping .env + volumes), pin the new
# image tags, then run the bundle's own installer (docker load + compose up).
for file in docker-compose.yml install.sh install.ps1 watchdog.sh watchdog.ps1 \
            register-autostart.sh register-autostart.ps1 \
            update.ps1 update-agent.sh update-agent.ps1 \
            discovery-responder.py discovery-responder.ps1 \
            migrate-fahd.sh migrate-fahd.ps1 \
            .env.example VERSION.txt INSTALL.md README.md; do
  [ -f "${BUNDLE_DIR}/${file}" ] && cp -f "${BUNDLE_DIR}/${file}" "./${file}"
done
# This script itself is running: stage its next version, promoted on next run.
[ -f "${BUNDLE_DIR}/update.sh" ] && cp -f "${BUNDLE_DIR}/update.sh" ./update.sh.next && mv -f ./update.sh.next ./update.sh
rm -rf ./images
cp -R "${BUNDLE_DIR}/images" ./images
if [ -d "${BUNDLE_DIR}/clients" ]; then
  rm -rf ./clients
  cp -R "${BUNDLE_DIR}/clients" ./clients
fi

sed -i.bak -E \
  -e "s|^POINTY_BACKEND_IMAGE=.*|POINTY_BACKEND_IMAGE=pointy-backend:${ASSIGNED}|" \
  -e "s|^POINTY_RELAY_IMAGE=.*|POINTY_RELAY_IMAGE=pointy-relay:${ASSIGNED}|" \
  -e "s|^POINTY_WEB_IMAGE=.*|POINTY_WEB_IMAGE=pointy-web:${ASSIGNED}|" \
  .env
rm -f .env.bak

log "applying ${ASSIGNED}…"
if bash ./install.sh && healthy; then
  echo "${ASSIGNED}" >VERSION.txt
  register_autostart
  log "updated to ${ASSIGNED}"
  exit 0
fi

# 5. Roll back: restore the previous config and bring the old images back up.
log "update to ${ASSIGNED} failed health check; rolling back to ${CURRENT_VERSION}"
cp -f "${SNAPSHOT}/.env" .env
[ -f "${SNAPSHOT}/docker-compose.yml" ] && cp -f "${SNAPSHOT}/docker-compose.yml" docker-compose.yml
"${COMPOSE[@]}" up -d --remove-orphans || true
if healthy; then
  fail "update to ${ASSIGNED} failed; rolled back to ${CURRENT_VERSION}"
fi
fail "update to ${ASSIGNED} failed and rollback is unhealthy — manual intervention needed"
