#!/usr/bin/env bash
#
# Pointy on-prem update engine (Linux / macOS hosts) — shared by update.sh (a
# bundle you carry to the machine) and update-agent.sh (a bundle the relay
# assigns). Source it; it only defines functions.
#
#   LIVE updates (the default) apply a new release WITHOUT closing the tills.
#   The `edge` front door owns :8000, so the new backend can be started
#   alongside the one serving customers, run its migrations, prove itself
#   against /readyz, and only then take traffic — the flip is an nginx reload,
#   which finishes in-flight requests on the old container and refuses nothing.
#   Nothing the shop touches is stopped at any point.
#
#   RESTART updates are the old behaviour: stop everything, bring it back on the
#   new images. Still the right tool in a maintenance window, and the automatic
#   fallback when a live update is impossible (no front door yet) or when a
#   release declares it needs one (UPDATE_STRATEGY.txt).
#
# The invariants that make a live update safe:
#   * two app versions run against one database for ~a minute, so migrations
#     must be backward compatible (expand now, contract in a later release) —
#     a release that cannot honour that ships UPDATE_STRATEGY.txt = restart;
#   * the database, cache, pooler and front door are NEVER recreated live —
#     their new images stay staged for the next maintenance restart;
#   * traffic only ever moves to a container that has already answered /readyz;
#   * every failure path ends with the shop serving, from whichever version is
#     healthy, and says which one that is.

POINTY_STANDBY_NAME="pointy-backend-standby"
POINTY_LOCK_FILE=".update.lock"
POINTY_UPSTREAM_FILE="edge/active/upstream.conf"
POINTY_LOG_TAG="${POINTY_LOG_TAG:-pointy-update}"

pu_log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$POINTY_LOG_TAG" "$*"; }
pu_warn() { pu_log "WARN: $*"; }

pu_compose() { docker compose --env-file .env -f docker-compose.yml "$@"; }

# Read a single KEY=value out of .env (no shell evaluation, so a password with
# shell metacharacters can never be executed).
pu_env_value() {
  grep -E "^$1=" .env 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'" | tr -d '\r'
}

pu_backend_port() {
  local port
  port="$(pu_env_value POINTY_BACKEND_PORT)"
  printf '%s' "${port:-8000}"
}

# ---------------------------------------------------------------------------
# Mutual exclusion with the watchdog
#
# The watchdog reconciles the stack every few minutes. It must not run `compose
# up` in the middle of a flip (it would fight us over the backend container), so
# both sides respect this lock file. It carries a timestamp rather than only a
# PID because the holder can die with the host: watchdog.sh ignores a lock older
# than POINTY_UPDATE_LOCK_MAX_AGE so a crashed update cannot disable the
# watchdog forever.
# ---------------------------------------------------------------------------
pu_acquire_lock() {
  if [ -e "$POINTY_LOCK_FILE" ]; then
    local age holder
    age=$(( $(date +%s) - $(pu_file_mtime "$POINTY_LOCK_FILE") ))
    holder="$(cat "$POINTY_LOCK_FILE" 2>/dev/null || echo unknown)"
    if [ "$age" -lt "${POINTY_UPDATE_LOCK_MAX_AGE:-3600}" ]; then
      pu_log "another update is already running (${holder}, ${age}s ago); nothing to do"
      return 1
    fi
    pu_warn "clearing a stale update lock (${holder}, ${age}s old)"
  fi
  printf 'pid=%s started=%s\n' "$$" "$(date '+%Y-%m-%dT%H:%M:%S')" >"$POINTY_LOCK_FILE"
  return 0
}

pu_release_lock() { rm -f "$POINTY_LOCK_FILE"; }

pu_file_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

# ---------------------------------------------------------------------------
# Health
# ---------------------------------------------------------------------------

# The LAN front door answering /readyz — i.e. exactly what a till sees.
pu_healthy() {
  local tries="${1:-60}" port
  port="$(pu_backend_port)"
  for _ in $(seq 1 "$tries"); do
    if curl -fsS "http://127.0.0.1:${port}/readyz/" >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done
  return 1
}

# Containers are addressed two different ways here and they are NOT the same
# string: nginx reaches a backend by its DNS name on the Compose network (the
# service alias `backend`, or the standby's container name), while docker
# inspect/logs need the real container (`pointy-backend-1`). Resolve one to the
# other — a compose service maps to its container, anything else is already one.
pu_container_id() {
  local id
  id="$(pu_compose ps -aq "$1" 2>/dev/null | head -1)"
  [ -n "$id" ] || id="$1"
  printf '%s' "$id"
}

pu_container_running() {
  [ "$(docker inspect -f '{{.State.Running}}' "$(pu_container_id "$1")" 2>/dev/null)" = "true" ]
}

# Is the zero-downtime path available at all? It needs the front door to be up
# and holding the LAN port; a deployment installed before the front door existed
# updates the old way (once), and gets it from that update onwards.
pu_edge_available() {
  pu_compose ps --status running --format '{{.Service}}' 2>/dev/null | grep -qx edge
}

# Ask the front door itself whether a backend container is ready. This probes
# the exact path traffic will take after the flip — container DNS included — so
# a name that nginx cannot resolve fails here instead of after the switch.
pu_upstream_ready() {
  pu_compose exec -T edge wget -q -O /dev/null "http://$1:8000/readyz/" >/dev/null 2>&1
}

# Wait for a backend container to serve, giving up early if it dies.
pu_wait_upstream() {
  local name="$1" label="$2" tries="${3:-180}" i=0
  while [ "$i" -lt "$tries" ]; do
    if ! pu_container_running "$name"; then
      pu_warn "${label} exited during startup; last log lines:"
      pu_dump_logs "$name"
      return 1
    fi
    if pu_upstream_ready "$name"; then
      pu_log "${label} is ready"
      return 0
    fi
    i=$((i + 1))
    [ $((i % 12)) -eq 0 ] && pu_log "still waiting for ${label} (${i}0s)…"
    sleep 10
  done
  pu_warn "${label} never became ready; last log lines:"
  pu_dump_logs "$name"
  return 1
}

pu_dump_logs() {
  docker logs --tail 40 "$(pu_container_id "$1")" 2>&1 | sed 's/^/    /' || true
}

# ---------------------------------------------------------------------------
# The flip
# ---------------------------------------------------------------------------

# Point the LAN front door at a container and PROVE it took effect. nginx keeps
# serving its previous config if a reload fails, so "the command returned 0" is
# not evidence — the response header is.
pu_set_upstream() {
  local target="$1" port backup=""
  port="$(pu_backend_port)"

  # Keep the previous pointer so a rejected config never survives on disk: the
  # front door re-reads this file when it restarts, so leaving a broken one
  # behind would turn a failed flip into an nginx that cannot start at all.
  mkdir -p "$(dirname "$POINTY_UPSTREAM_FILE")"
  if [ -f "$POINTY_UPSTREAM_FILE" ]; then
    backup="$(mktemp)"
    cp -f "$POINTY_UPSTREAM_FILE" "$backup"
  fi
  cat >"$POINTY_UPSTREAM_FILE" <<EOF
# GENERATED — see update-lib.sh (pu_set_upstream). Reset by install.sh and by
# watchdog.sh whenever the container named here is not running.
set \$pointy_upstream      "http://${target}:8000";
set \$pointy_upstream_name "${target}";
EOF

  if ! pu_compose exec -T edge nginx -t >/dev/null 2>&1; then
    pu_warn "front-door config rejected by nginx -t; leaving traffic where it is"
    pu_compose exec -T edge nginx -t 2>&1 | sed 's/^/    /' || true
    if [ -n "$backup" ]; then
      cp -f "$backup" "$POINTY_UPSTREAM_FILE"
      rm -f "$backup"
    else
      rm -f "$POINTY_UPSTREAM_FILE"
    fi
    return 1
  fi
  rm -f "$backup" 2>/dev/null || true
  pu_compose exec -T edge nginx -s reload >/dev/null 2>&1 || true

  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if curl -fsS -I "http://127.0.0.1:${port}/healthz-edge" 2>/dev/null \
        | tr -d '\r' | grep -qi "^X-Pointy-Upstream: ${target}$"; then
      pu_log "traffic now served by ${target}"
      return 0
    fi
    sleep 1
  done
  pu_warn "front door did not report ${target} after reload"
  return 1
}

# ---------------------------------------------------------------------------
# Bundle handling
# ---------------------------------------------------------------------------

# Replace a file by atomic rename, never in place: update.sh / update-agent.sh
# are themselves being replaced while they run, and overwriting the inode a
# running bash script is still reading corrupts it mid-execution. A rename
# leaves the running process on the old inode and the next run picks up the new
# one.
pu_install_file() {
  local src="$1" dest="$2"
  cp -f "$src" "${dest}.pointy-new" || return 1
  mv -f "${dest}.pointy-new" "$dest"
}

POINTY_ADOPT_FILES="docker-compose.yml install.sh install.ps1 watchdog.sh watchdog.ps1
register-autostart.sh register-autostart.ps1 update.sh update.ps1
update-agent.sh update-agent.ps1 update-lib.sh update-lib.ps1
discovery-responder.py discovery-responder.ps1 migrate-fahd.sh migrate-fahd.ps1
disable-watchdog.sh disable-watchdog.ps1 fix-backend-outages.sh fix-backend-outages.ps1
.env.example VERSION.txt INSTALL.md README.md"

# Which strategy the release itself asks for. A release whose migrations cannot
# be applied while the previous version is still running ships
# UPDATE_STRATEGY.txt containing "restart", and gets a maintenance-style update
# even when the operator did not ask for one.
pu_bundle_strategy() {
  local file="$1/UPDATE_STRATEGY.txt"
  [ -f "$file" ] || { printf 'live'; return; }
  local value
  value="$(tr -d '[:space:]' <"$file" | tr '[:upper:]' '[:lower:]')"
  case "$value" in
    restart|downtime|offline) printf 'restart' ;;
    *) printf 'live' ;;
  esac
}

# Copy the bundle over this deployment, keeping everything stateful: .env,
# volumes, backups, and the front door's current upstream pointer.
pu_adopt_bundle() {
  local dir="$1" assigned="$2" file
  for file in $POINTY_ADOPT_FILES; do
    [ -f "${dir}/${file}" ] && pu_install_file "${dir}/${file}" "./${file}"
  done
  # The front door's own config travels inside its image; only the "which
  # backend is live" pointer lives here, and it is state — it must survive the
  # update untouched.
  [ -f "$POINTY_UPSTREAM_FILE" ] || pu_write_default_upstream
  rm -rf ./images
  cp -R "${dir}/images" ./images
  if [ -d "${dir}/clients" ]; then
    rm -rf ./clients
    cp -R "${dir}/clients" ./clients
  fi
  chmod +x ./*.sh 2>/dev/null || true

  # Pin the app images. Infrastructure images (postgres, redis, pgbouncer, the
  # front door) are deliberately left alone — see pu_load_images.
  sed -i.bak -E \
    -e "s|^POINTY_BACKEND_IMAGE=.*|POINTY_BACKEND_IMAGE=pointy-backend:${assigned}|" \
    -e "s|^POINTY_RELAY_IMAGE=.*|POINTY_RELAY_IMAGE=pointy-relay:${assigned}|" \
    -e "s|^POINTY_WEB_IMAGE=.*|POINTY_WEB_IMAGE=pointy-web:${assigned}|" \
    .env
  rm -f .env.bak
}

pu_write_default_upstream() {
  mkdir -p "$(dirname "$POINTY_UPSTREAM_FILE")"
  cat >"$POINTY_UPSTREAM_FILE" <<'EOF'
# GENERATED — the backend the LAN front door is currently sending traffic to.
set $pointy_upstream      "http://backend:8000";
set $pointy_upstream_name "backend";
EOF
}

# Load images from ./images. A live update loads ONLY the application images:
# loading a new postgres/redis/pgbouncer/nginx tar would change what the compose
# file resolves to and hand the next `compose up` a reason to recreate the
# database or the LAN front door — precisely the outage we are avoiding. Those
# tars stay staged in ./images and install at the next full restart.
pu_load_images() {
  local mode="$1" tar found=0
  shopt -s nullglob
  local tars=(images/*.tar)
  shopt -u nullglob
  [ ${#tars[@]} -gt 0 ] || { pu_warn "no image archives under ./images"; return 1; }
  for tar in "${tars[@]}"; do
    case "$mode:$(basename "$tar")" in
      # The LAN front door counts as infrastructure, not application: loading a
      # new one would give the next `compose up` a reason to recreate the
      # container that is holding the port open for the shop.
      live:pointy-edge*) continue ;;
      live:pointy-*) ;;
      live:*) continue ;;
    esac
    pu_log "loading $(basename "$tar")…"
    docker load -i "$tar" >/dev/null || return 1
    found=1
  done
  [ "$found" = 1 ] || { pu_warn "no application images found in ./images"; return 1; }
  return 0
}

# Infrastructure images the bundle carries but a live update did not apply.
pu_report_staged_infra() {
  local names="" tar base
  shopt -s nullglob
  for tar in images/*.tar; do
    base="$(basename "$tar")"
    case "$base" in pointy-edge*) ;; pointy-*) continue ;; esac
    names="${names} ${base%.tar}"
  done
  shopt -u nullglob
  [ -n "$names" ] || return 0
  pu_log "staged for the next maintenance restart (not applied live):${names}"
}

# ---------------------------------------------------------------------------
# Applying
# ---------------------------------------------------------------------------

pu_remove_standby() {
  docker rm -f "$POINTY_STANDBY_NAME" >/dev/null 2>&1 || true
}

# Start the new backend beside the running one. `compose run` builds it from the
# very same service definition (env, volumes, limits) but publishes no port and
# carries the one-off label, so it cannot collide with the live container and
# `compose up --remove-orphans` will not sweep it away. Its boot runs the new
# release's migrations against the live database — the expand/contract window.
pu_start_standby() {
  pu_remove_standby
  pu_log "starting the new backend alongside the live one (migrations run here)…"
  pu_compose run -d --no-deps --name "$POINTY_STANDBY_NAME" backend >/dev/null
}

# Recreate one service on the new image without touching its dependencies.
pu_recreate() {
  pu_compose up -d --no-deps --force-recreate "$@"
}

# The zero-downtime path. Returns 0 on success, 1 if it aborted before moving
# any traffic (the shop never noticed), 2 if it failed after the flip and the
# caller must roll the backend back.
pu_apply_live() {
  local assigned="$1"

  pu_load_images live || return 1
  pu_start_standby || { pu_warn "could not start the new backend"; return 1; }

  if ! pu_wait_upstream "$POINTY_STANDBY_NAME" "the new backend" \
      "${POINTY_STANDBY_READY_TRIES:-180}"; then
    pu_remove_standby
    pu_warn "the new backend never became ready — nothing was switched over"
    return 1
  fi

  # From here traffic moves. Every step below keeps one healthy backend serving.
  pu_set_upstream "$POINTY_STANDBY_NAME" || { pu_remove_standby; return 1; }

  # Promote: rebuild the long-lived `backend` container on the new image while
  # the standby serves, then hand the traffic back to it. The standby is a
  # one-off container with no restart policy, so it must never be the thing the
  # shop depends on overnight.
  pu_log "rebuilding the managed backend on ${assigned}…"
  if ! pu_recreate backend >/dev/null 2>&1; then
    pu_warn "could not recreate the backend service"
    return 2
  fi
  if ! pu_wait_upstream backend "the rebuilt backend" 120; then
    return 2
  fi
  pu_set_upstream backend || return 2
  pu_remove_standby

  # Everything else can be replaced normally now: none of it holds the LAN port,
  # and the tills are already being served by the new backend.
  pu_log "updating background workers, relay connector and web app…"
  pu_recreate celery-worker celery-beat >/dev/null 2>&1 \
    || pu_warn "background workers did not restart cleanly; check 'compose ps'"
  pu_recreate connector >/dev/null 2>&1 \
    || pu_warn "relay connector did not restart cleanly; check 'compose ps'"
  pu_recreate web >/dev/null 2>&1 \
    || pu_warn "web app did not restart cleanly; check 'compose ps'"

  pu_publish_clients
  pu_report_staged_infra
  return 0
}

# The maintenance path: the pre-existing behaviour, unchanged in spirit — run
# the bundle's own installer, which loads every image and brings the whole stack
# up on it. The tills are offline for the length of a full restart.
pu_apply_restart() {
  pu_log "applying with a full restart (the stack will be briefly offline)…"
  bash ./install.sh
}

# Publish the bundled client installers into the volume Django serves on the
# LAN, so tills self-update too. install.sh does this on the restart path.
pu_publish_clients() {
  [ -d ./clients ] || return 0
  pu_log "publishing client installers for LAN download…"
  if pu_compose cp clients/. backend:/var/lib/pointy/clients/ >/dev/null 2>&1; then
    pu_compose exec -u 0 -T backend chmod -R a+rX /var/lib/pointy/clients >/dev/null 2>&1 || true
  else
    pu_warn "could not publish client installers; re-run install.sh once the backend is up"
  fi
}

# Re-register autostart after every update so services a new bundle ships
# (watchdog, update agent, LAN discovery responder) are installed without anyone
# having to remember it. Idempotent; needs root + systemd.
pu_register_autostart() {
  command -v systemctl >/dev/null 2>&1 || return 0
  if [ "$(id -u)" -eq 0 ]; then
    pu_log "re-registering autostart services…"
    bash ./register-autostart.sh >/dev/null 2>&1 \
      || pu_warn "autostart registration failed; run 'sudo bash register-autostart.sh' manually"
  else
    pu_log "NOTE: not running as root — run 'sudo bash register-autostart.sh' once so"
    pu_log "      services added by this update are registered."
  fi
}

# ---------------------------------------------------------------------------
# Orchestration: the whole update, including rollback. Front-ends call this.
#
#   pu_apply_bundle <bundle-dir> <current-version> <assigned-version> <mode>
#
# mode: auto | live | restart. Prints what it did; returns 0 on success.
# ---------------------------------------------------------------------------
pu_apply_bundle() {
  local dir="$1" current="$2" assigned="$3" mode="${4:-auto}"
  local strategy snapshot rc

  strategy="$mode"
  if [ "$mode" = auto ]; then
    strategy="$(pu_bundle_strategy "$dir")"
    if [ "$strategy" = live ] && ! pu_edge_available; then
      pu_log "no LAN front door in this deployment yet — this one update needs a restart;"
      pu_log "it installs the front door, and updates after it are applied live."
      strategy=restart
    fi
  elif [ "$mode" = live ] && ! pu_edge_available; then
    pu_warn "a live update needs the LAN front door, which is not running; falling back to a restart"
    strategy=restart
  fi
  if [ "$mode" = live ] && [ "$(pu_bundle_strategy "$dir")" = restart ]; then
    pu_warn "release ${assigned} declares it cannot be applied live (UPDATE_STRATEGY.txt); restarting"
    strategy=restart
  fi

  if [ "$strategy" = live ]; then
    pu_log "updating ${current} -> ${assigned} live (the shop keeps trading)"
  else
    pu_log "updating ${current} -> ${assigned} with a full restart"
  fi

  pu_backup_database "$current" "$assigned"

  snapshot="$(mktemp -d)"
  cp .env "${snapshot}/.env"
  [ -f docker-compose.yml ] && cp docker-compose.yml "${snapshot}/docker-compose.yml"

  pu_adopt_bundle "$dir" "$assigned"

  if [ "$strategy" = live ]; then
    pu_apply_live "$assigned"
    rc=$?
    if [ "$rc" -eq 0 ] && pu_healthy 24; then
      echo "${assigned}" >VERSION.txt
      pu_register_autostart
      rm -rf "$snapshot"
      pu_log "updated to ${assigned} — no downtime"
      return 0
    fi
    if [ "$rc" -eq 1 ]; then
      # Nothing was ever switched over: the old backend is still the one serving.
      # Put the configuration back so the watchdog cannot apply the half-staged
      # release behind our back.
      pu_restore_snapshot "$snapshot"
      pu_warn "update to ${assigned} aborted before any traffic moved; still on ${current}"
      return 1
    fi
    pu_rollback_live "$snapshot" "$current" "$assigned"
    return 1
  fi

  if pu_apply_restart && pu_healthy; then
    echo "${assigned}" >VERSION.txt
    pu_register_autostart
    rm -rf "$snapshot"
    pu_log "updated to ${assigned}"
    return 0
  fi

  pu_warn "update to ${assigned} failed health check; rolling back to ${current}"
  pu_restore_snapshot "$snapshot"
  pu_compose up -d --remove-orphans >/dev/null 2>&1 || true
  if pu_healthy; then
    pu_warn "update to ${assigned} failed; rolled back to ${current}"
    return 1
  fi
  pu_warn "update to ${assigned} failed AND the rollback is unhealthy — manual intervention needed"
  return 1
}

pu_restore_snapshot() {
  cp -f "$1/.env" .env
  [ -f "$1/docker-compose.yml" ] && cp -f "$1/docker-compose.yml" docker-compose.yml
  rm -rf "$1"
}

# Traffic had already moved to the new version when something downstream failed.
# Bring the previous release's backend back and hand the front door to it.
pu_rollback_live() {
  local snapshot="$1" current="$2" assigned="$3"
  pu_warn "update to ${assigned} failed after the switchover; rolling back to ${current}"
  pu_restore_snapshot "$snapshot"
  if pu_recreate backend >/dev/null 2>&1 && pu_wait_upstream backend "the restored backend" 120; then
    pu_set_upstream backend || true
    pu_remove_standby
    pu_warn "rolled back to ${current}; the shop stayed open throughout"
    return 0
  fi
  # The old release will not come back. The new one is running and serving, so
  # leave it serving — but give it a restart policy first, because it was
  # created as a temporary container and would not survive a crash or a reboot.
  if pu_container_running "$POINTY_STANDBY_NAME"; then
    docker update --restart=unless-stopped "$POINTY_STANDBY_NAME" >/dev/null 2>&1 || true
    # It answers to its own name on the network, so the front door can keep
    # using it exactly as it has been.
    pu_set_upstream "$POINTY_STANDBY_NAME" || true
    pu_warn "could not restore ${current}; the shop is being served by ${assigned} from a"
    pu_warn "temporary container. Run 'bash install.sh' at the next opportunity to make it permanent."
    return 1
  fi
  pu_warn "no healthy backend left — run 'bash install.sh' now"
  return 1
}

# Back up before any migration runs: a forward migration is the one thing a
# rollback cannot fully undo on its own. Best-effort, as before.
pu_backup_database() {
  mkdir -p backups
  local backup="backups/pre-update-${1}-to-${2}.sql"
  if pu_compose exec -T postgres sh -c 'pg_dump -U "${POSTGRES_USER:-pointy}" "${POSTGRES_DB:-pointy}"' >"$backup" 2>/dev/null; then
    pu_log "database backed up to ${backup}"
  else
    rm -f "$backup"
    pu_warn "database backup failed (stack down?); continuing — rollback restores images, not data"
  fi
}

# ---------------------------------------------------------------------------
# Staging a bundle from a zip or a directory. Sets POINTY_BUNDLE_DIR.
# ---------------------------------------------------------------------------
pu_stage_bundle() {
  local source="$1" staging
  if [ -d "$source" ]; then
    POINTY_BUNDLE_DIR="$source"
  else
    command -v unzip >/dev/null 2>&1 || { pu_warn "unzip not found on PATH"; return 1; }
    staging="$(mktemp -d)"
    POINTY_BUNDLE_STAGING="$staging"
    pu_log "extracting $(basename "$source")…"
    unzip -q -o "$source" -d "$staging" || { pu_warn "could not unzip bundle"; return 1; }
    POINTY_BUNDLE_DIR="$(find "$staging" -maxdepth 1 -type d -name 'pointy-onprem-*' | head -1)"
    [ -n "$POINTY_BUNDLE_DIR" ] || POINTY_BUNDLE_DIR="$staging"
  fi
  [ -d "${POINTY_BUNDLE_DIR}/images" ] \
    || { pu_warn "not a Pointy bundle: no images/ directory in ${POINTY_BUNDLE_DIR}"; return 1; }
  POINTY_BUNDLE_VERSION="unknown"
  [ -f "${POINTY_BUNDLE_DIR}/VERSION.txt" ] \
    && POINTY_BUNDLE_VERSION="$(tr -d '[:space:]' <"${POINTY_BUNDLE_DIR}/VERSION.txt")"
  return 0
}

pu_current_version() {
  local version="unknown"
  [ -f VERSION.txt ] && version="$(tr -d '[:space:]' <VERSION.txt)"
  printf '%s' "$version"
}
