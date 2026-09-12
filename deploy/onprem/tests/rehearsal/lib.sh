#!/usr/bin/env bash
#
# The on-prem update rehearsal rig.
#
# Tier 1 (../) proves each step of the update engine does what it claims when
# its collaborators behave as scripted. That is worth having and it is not the
# same as knowing the thing works. This rig runs the REAL update scripts against
# REAL Docker, using the REAL deploy/onprem/docker-compose.yml, on a shop
# installed from a REAL release bundle by the REAL install.sh — and asks the one
# question no unit test can: does a till notice?
#
# What is stood in for, and why it is honest:
#
#   * the application containers are a small static binary instead of Django.
#     The engine never looks inside an image; it starts containers, waits for
#     /readyz through the front door, flips nginx and rolls back. What it DOES
#     need is a release that can be made to fail on demand — a real backend
#     cannot be asked to "never become ready" — and a release that can be told
#     apart from its predecessor in a response header, which is how we prove the
#     new version is actually the one serving.
#   * postgres, redis, pgbouncer and the LAN front door are the REAL images,
#     because "infrastructure is never recreated live" is one of the claims
#     under test.
#
# Everything else — install.sh, update.sh, update-agent.sh, update-lib.sh, the
# compose file, the bundle layout, the relay and its CLI — is the shipped code.
set -uo pipefail

RIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RIG_ONPREM_DIR="$(cd "${RIG_DIR}/../.." && pwd)"
RIG_REPO_DIR="$(cd "${RIG_ONPREM_DIR}/../.." && pwd)"

# Built artefacts are expensive and version-stable, so they are cached for the
# whole run (and, if you keep it, between runs).
RIG_CACHE="${RIG_CACHE:-${TMPDIR:-/tmp}/pointy-rehearsal-cache}"
RIG_BUNDLES="${RIG_CACHE}/bundles"
RIG_BIN="${RIG_CACHE}/bin"
RIG_INFRA_TARS="${RIG_CACHE}/infra"

RIG_EDGE_IMAGE="${RIG_EDGE_IMAGE:-pointy-edge:1}"
RIG_POSTGRES_IMAGE="${RIG_POSTGRES_IMAGE:-postgres:17-alpine}"
RIG_REDIS_IMAGE="${RIG_REDIS_IMAGE:-redis:7-alpine}"
RIG_PGBOUNCER_IMAGE="${RIG_PGBOUNCER_IMAGE:-edoburu/pgbouncer:v1.23.1-p2}"

RIG_FAILURES=0
RIG_ASSERTIONS=0

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

rig_log()  { printf '    %s\n' "$*"; }
rig_step() { printf '\n>>> %s\n' "$*"; }
rig_warn() { printf '    WARN: %s\n' "$*" >&2; }

rig_fail() {
  RIG_FAILURES=$((RIG_FAILURES + 1))
  printf '    ASSERTION FAILED: %s\n' "$1" >&2
  shift
  local line
  for line in "$@"; do printf '        %s\n' "$line" >&2; done
  return 1
}

rig_pass() { RIG_ASSERTIONS=$((RIG_ASSERTIONS + 1)); printf '    ok  %s\n' "$1"; }

# ---------------------------------------------------------------------------
# Assertions. They do NOT abort — an integration scenario should report every
# problem it can see in one run, because setting the scenario up again costs
# thirty seconds, not thirty milliseconds.
# ---------------------------------------------------------------------------

rig_assert_eq() { # <expected> <actual> <what>
  if [ "$1" = "$2" ]; then rig_pass "$3"; return 0; fi
  rig_fail "$3" "expected: [$1]" "actual:   [$2]"
}

rig_assert_ne() {
  if [ "$1" != "$2" ]; then rig_pass "$3"; return 0; fi
  rig_fail "$3" "both were: [$1]"
}

rig_assert_contains() { # <haystack> <needle> <what>
  case "$1" in *"$2"*) rig_pass "$3"; return 0 ;; esac
  rig_fail "$3" "looking for: [$2]" "in: [$(printf '%s' "$1" | head -c 400)]"
}

rig_assert_not_contains() {
  case "$1" in *"$2"*) rig_fail "$3" "unexpectedly found: [$2]"; return 1 ;; esac
  rig_pass "$3"
}

rig_assert_file() { [ -f "$1" ] && rig_pass "$2" || rig_fail "$2" "missing file: $1"; }
rig_assert_no_file() { [ -e "$1" ] && rig_fail "$2" "unexpected path: $1" || rig_pass "$2"; }

rig_assert_le() { # <actual> <ceiling> <what>
  if [ "$1" -le "$2" ]; then rig_pass "$3"; return 0; fi
  rig_fail "$3" "expected at most $2, got $1"
}

rig_assert_ge() {
  if [ "$1" -ge "$2" ]; then rig_pass "$3"; return 0; fi
  rig_fail "$3" "expected at least $2, got $1"
}

# ---------------------------------------------------------------------------
# Building the stand-in releases
# ---------------------------------------------------------------------------

# Nothing may be rehearsed against a stale artefact.
#
# This matters more than it looks. A bundle carries its own copy of
# update-lib.sh, update.sh and update-agent.sh, and install.sh puts those in the
# deploy directory — so the shop runs the BUNDLE's engine, not the repo's. Fix a
# bug in update-lib.sh, re-run against a cached bundle, and the rehearsal
# faithfully exercises the version with the bug still in it. It does not error;
# it just quietly answers a question about last week's code. A rig that fails
# that way is worse than no rig.
#
# Two stamps, because they invalidate different things: a changed stand-in makes
# the built images wrong, a changed deploy script only makes the bundles wrong.
rig_invalidate_stale_artifacts() {
  local repo tag
  local stub_now stub_was deploy_now deploy_was
  stub_now="$(shasum -a 256 "${RIG_DIR}/root/pointy-stub" 2>/dev/null | awk '{print $1}')"
  stub_was="$(cat "${RIG_CACHE}/stub.sha256" 2>/dev/null)"
  # Everything a bundle carries out of deploy/onprem.
  deploy_now="$(cat "${RIG_ONPREM_DIR}"/*.sh "${RIG_ONPREM_DIR}/discovery-responder.py" \
      "${RIG_ONPREM_DIR}/docker-compose.yml" "${RIG_ONPREM_DIR}/.env.example" 2>/dev/null \
      | shasum -a 256 | awk '{print $1}')"
  deploy_was="$(cat "${RIG_CACHE}/deploy.sha256" 2>/dev/null)"

  if [ -n "$stub_now" ] && [ -n "$stub_was" ] && [ "$stub_now" != "$stub_was" ]; then
    rig_log "the stand-in changed — discarding the images built from the old one"
    for repo in pointy-backend pointy-relay pointy-web; do
      docker images "$repo" --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | while read -r tag; do
        docker image rm -f "$tag" >/dev/null 2>&1
      done
    done
    rm -f "${RIG_BUNDLES}"/*.zip
  fi
  if [ -n "$deploy_was" ] && [ "$deploy_now" != "$deploy_was" ]; then
    rig_log "the deploy scripts changed — rebuilding every bundle so the shop runs the current engine"
    rm -f "${RIG_BUNDLES}"/*.zip
  fi
  [ -n "$stub_now" ] && printf '%s' "$stub_now" >"${RIG_CACHE}/stub.sha256"
  [ -n "$deploy_now" ] && printf '%s' "$deploy_now" >"${RIG_CACHE}/deploy.sha256"
}

rig_build_binaries() {
  mkdir -p "$RIG_BIN" "${RIG_DIR}/root/usr/local/bin"
  if [ ! -x "${RIG_DIR}/root/pointy-stub" ] || \
     [ "${RIG_DIR}/stub/main.go" -nt "${RIG_DIR}/root/pointy-stub" ] || \
     [ "${RIG_DIR}/stub/loadgen.go" -nt "${RIG_DIR}/root/pointy-stub" ]; then
    rig_log "building the container stand-in (linux/${RIG_ARCH})…"
    ( cd "${RIG_DIR}/stub" && CGO_ENABLED=0 GOOS=linux GOARCH="$RIG_ARCH" \
        go build -trimpath -ldflags='-s -w' -o "${RIG_DIR}/root/pointy-stub" . ) || return 1
    # The same binary answers to the two commands the compose healthchecks run,
    # so the shipped compose file needs no rehearsal-specific edits.
    cp "${RIG_DIR}/root/pointy-stub" "${RIG_DIR}/root/usr/local/bin/python"
    cp "${RIG_DIR}/root/pointy-stub" "${RIG_DIR}/root/usr/local/bin/celery"
  fi
  if [ ! -x "${RIG_BIN}/loadgen" ] || [ "${RIG_DIR}/stub/loadgen.go" -nt "${RIG_BIN}/loadgen" ]; then
    rig_log "building the host load generator…"
    ( cd "${RIG_DIR}/stub" && go build -trimpath -o "${RIG_BIN}/loadgen" . ) || return 1
  fi
}

# rig_build_release <version> [fail-mode] [boot-delay] [crash-after]
#
# Builds the three application images a release ships. The failure mode is baked
# into the image, never passed through compose — a broken release has to be a
# property of the release.
rig_build_release() {
  local version="$1" fail="${2:-}" delay="${3:-0}" crash="${4:-5}" repo
  for repo in pointy-backend pointy-relay pointy-web; do
    docker image inspect "${repo}:${version}" >/dev/null 2>&1 && continue
    docker build -q \
      --build-arg "STUB_VERSION=${version}" \
      --build-arg "STUB_FAIL=${fail}" \
      --build-arg "STUB_BOOT_DELAY=${delay}" \
      --build-arg "STUB_CRASH_AFTER=${crash}" \
      -t "${repo}:${version}" -f "${RIG_DIR}/Dockerfile.stub" "$RIG_DIR" >/dev/null || return 1
  done
}

# The third-party archives a real bundle carries. Saved once and cloned into each
# bundle. postgres is deliberately left out: its archive is 415MB, it would
# dominate every install, and nothing under test distinguishes it from the other
# infrastructure tars — redis, pgbouncer and the front door make the same point.
rig_build_infra_tars() {
  mkdir -p "$RIG_INFRA_TARS"
  [ -f "${RIG_INFRA_TARS}/redis.tar" ]       || docker save "$RIG_REDIS_IMAGE"     -o "${RIG_INFRA_TARS}/redis.tar" || return 1
  [ -f "${RIG_INFRA_TARS}/pgbouncer.tar" ]   || docker save "$RIG_PGBOUNCER_IMAGE" -o "${RIG_INFRA_TARS}/pgbouncer.tar" || return 1
  # Named pointy-edge*.tar exactly as release.yml names it, so the live updater
  # recognises the front door as infrastructure and does NOT load it.
  [ -f "${RIG_INFRA_TARS}/pointy-edge.tar" ] || docker save "$RIG_EDGE_IMAGE"      -o "${RIG_INFRA_TARS}/pointy-edge.tar" || return 1
}

# rig_build_bundle <version> [update-strategy]
#
# Assembles a release bundle the way .github/workflows/release.yml does: offline
# compose (no build: sections), image tars named per release, the deploy scripts,
# a pinned .env.example, VERSION.txt, and a zip. A rehearsal that built bundles
# its own way would be testing its own layout rather than the shipped one.
rig_build_bundle() {
  local version="$1" strategy="${2:-}"
  local zip="${RIG_BUNDLES}/pointy-onprem-${version}.zip"
  [ -f "$zip" ] && { printf '%s' "$zip"; return 0; }

  local work bundle
  work="$(mktemp -d "${RIG_CACHE}/build-XXXXXX")"
  bundle="${work}/pointy-onprem-${version}"
  mkdir -p "${bundle}/images" "${bundle}/wsl" "${bundle}/clients" "$RIG_BUNDLES"

  docker save "pointy-backend:${version}" -o "${bundle}/images/pointy-backend-${version}.tar" || return 1
  docker save "pointy-relay:${version}"   -o "${bundle}/images/pointy-relay-${version}.tar"   || return 1
  docker save "pointy-web:${version}"     -o "${bundle}/images/pointy-web-${version}.tar"     || return 1
  cp "${RIG_INFRA_TARS}/redis.tar" "${RIG_INFRA_TARS}/pgbouncer.tar" \
     "${RIG_INFRA_TARS}/pointy-edge.tar" "${bundle}/images/" || return 1

  python3 "${RIG_DIR}/compose-offline.py" \
    "${RIG_ONPREM_DIR}/docker-compose.yml" "${bundle}/docker-compose.yml" || return 1

  sed -e "s|^POINTY_BACKEND_IMAGE=.*|POINTY_BACKEND_IMAGE=pointy-backend:${version}|" \
      -e "s|^POINTY_RELAY_IMAGE=.*|POINTY_RELAY_IMAGE=pointy-relay:${version}|" \
      -e "s|^POINTY_WEB_IMAGE=.*|POINTY_WEB_IMAGE=pointy-web:${version}|" \
      -e "s|^POINTY_EDGE_IMAGE=.*|POINTY_EDGE_IMAGE=${RIG_EDGE_IMAGE}|" \
      "${RIG_ONPREM_DIR}/.env.example" >"${bundle}/.env.example" || return 1

  cp "${RIG_ONPREM_DIR}/install.sh" "${RIG_ONPREM_DIR}/watchdog.sh" \
     "${RIG_ONPREM_DIR}/register-autostart.sh" "${RIG_ONPREM_DIR}/update-agent.sh" \
     "${RIG_ONPREM_DIR}/update.sh" "${RIG_ONPREM_DIR}/update-lib.sh" \
     "${RIG_ONPREM_DIR}/disable-watchdog.sh" \
     "${RIG_ONPREM_DIR}/discovery-responder.py" "${RIG_ONPREM_DIR}/migrate-fahd.sh" \
     "${RIG_ONPREM_DIR}/INSTALL.md" "${RIG_ONPREM_DIR}/README.md" "${bundle}/" || return 1
  cp "${RIG_ONPREM_DIR}/wsl/bootstrap-wsl.ps1" "${RIG_ONPREM_DIR}/wsl/timezone-map.txt" \
     "${bundle}/wsl/" || return 1

  printf '{"version":"%s","android":null,"windows":null,"linux":null}\n' "$version" \
    >"${bundle}/clients/manifest.json"
  printf 'stand-in installer for %s\n' "$version" >"${bundle}/clients/pointy-windows-x64-setup.exe"

  chmod +x "${bundle}"/*.sh "${bundle}/discovery-responder.py"
  printf '%s\n' "$version" >"${bundle}/VERSION.txt"
  [ -n "$strategy" ] && printf '%s\n' "$strategy" >"${bundle}/UPDATE_STRATEGY.txt"

  ( cd "$work" && zip -r -q "$zip" "pointy-onprem-${version}" ) || return 1
  rm -rf "$work"
  printf '%s' "$zip"
}

# The releases every scenario draws from. Built once per run and cached, because
# a bundle costs a couple of seconds and the scenarios share them.
#
# The version STRING encodes the behaviour on purpose: when a scenario fails you
# read "2.0.0-never-ready" in the log and know immediately what was being asked
# of the engine, without cross-referencing a table.
rig_build_catalog() {
  rig_log "building the release catalog…"
  # Healthy releases, for the paths that are supposed to work.
  rig_build_release 1.0.0 || return 1
  rig_build_release 1.1.0 || return 1
  rig_build_release 1.2.0 || return 1
  # A release that boots, listens, and never passes its readiness gate. The
  # commonest real failure — a migration that does not finish — and the one a
  # TCP-level check would wave straight through.
  rig_build_release 2.0.0-never-ready never_ready || return 1
  # A release that dies on startup, as a failed migration does.
  rig_build_release 2.1.0-crash-on-boot crash_on_boot || return 1
  # A release that passes the readiness gate and then goes sick. Traffic has
  # already moved when it fails, so only the engine's own final health check can
  # catch it.
  rig_build_release 2.2.0-sick-after-flip ready_then_sick 0 6 || return 1
  # A release that takes a long time to boot: not broken, just slow. The engine
  # must wait rather than give up on it.
  rig_build_release 2.3.0-slow-boot "" 12 || return 1
  # A release that comes up fine as the standby and then fails when the managed
  # backend is rebuilt on it — i.e. AFTER traffic has already moved. The only
  # path that reaches pu_rollback_live.
  rig_build_release 2.4.0-fails-after-flip never_ready_at_start || return 1

  rig_build_bundle 1.0.0 >/dev/null || return 1
  rig_build_bundle 1.1.0 >/dev/null || return 1
  # 1.2.0 exists twice: once as a normal live release, and once declaring it
  # cannot be applied live.
  rig_build_bundle 1.2.0 >/dev/null || return 1
  rig_build_bundle 2.0.0-never-ready >/dev/null || return 1
  rig_build_bundle 2.1.0-crash-on-boot >/dev/null || return 1
  rig_build_bundle 2.2.0-sick-after-flip >/dev/null || return 1
  rig_build_bundle 2.3.0-slow-boot >/dev/null || return 1
  rig_build_bundle 2.4.0-fails-after-flip >/dev/null || return 1
}

# A bundle of an already-built release that declares a restart-only update.
rig_build_restart_bundle() {
  local version="$1"
  local zip="${RIG_BUNDLES}/pointy-onprem-${version}.zip"
  [ -f "$zip" ] && { printf '%s' "$zip"; return 0; }
  rig_build_release "$version" || return 1
  rig_build_bundle "$version" restart
}

rig_bundle_path() { printf '%s/pointy-onprem-%s.zip' "$RIG_BUNDLES" "$1"; }

# ---------------------------------------------------------------------------
# Installing a shop
# ---------------------------------------------------------------------------

rig_free_port() {
  python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

# rig_install_shop <version> — a fresh shop, installed from its release bundle by
# the shipped install.sh, exactly as an engineer would install it on site.
rig_install_shop() {
  local version="$1"
  local zip; zip="${RIG_BUNDLES}/pointy-onprem-${version}.zip"
  [ -f "$zip" ] || { rig_fail "no bundle built for ${version}"; return 1; }

  RIG_SHOP_ROOT="${RIG_RUN_DIR}/shop"
  rm -rf "$RIG_SHOP_ROOT"; mkdir -p "$RIG_SHOP_ROOT"
  ( cd "$RIG_SHOP_ROOT" && unzip -q "$zip" ) || return 1
  RIG_SHOP="${RIG_SHOP_ROOT}/pointy-onprem-${version}"

  RIG_PORT="$(rig_free_port)"
  RIG_WEB_PORT="$(rig_free_port)"
  RIG_PROJECT="rehearsal-$$-$(printf '%s' "$version" | tr -c 'a-z0-9' '-')"

  local password secret token
  password="$(openssl rand -hex 24)"
  secret="$(openssl rand -hex 48)"
  token="${RIG_CONNECTOR_TOKEN:-$(openssl rand -hex 24)}"

  # Pre-seed .env so the rig owns the ports and the project name. install.sh only
  # generates one when it is missing, so everything else about the install is the
  # real path — including loading and shredding the image archives.
  {
    sed -e "s|^POINTY_POSTGRES_PASSWORD=.*|POINTY_POSTGRES_PASSWORD=${password}|" \
        -e "s|^POINTY_DATABASE_URL=.*|POINTY_DATABASE_URL=postgres://pointy:${password}@pgbouncer:5432/pointy|" \
        -e "s|^POINTY_DATABASE_DIRECT_URL=.*|POINTY_DATABASE_DIRECT_URL=postgres://pointy:${password}@postgres:5432/pointy|" \
        -e "s|^DJANGO_SECRET_KEY=.*|DJANGO_SECRET_KEY=${secret}|" \
        -e "s|^POINTY_RELAY_CONNECTOR_SETUP_TOKEN=.*|POINTY_RELAY_CONNECTOR_SETUP_TOKEN=${token}|" \
        -e "s|^POINTY_BACKEND_PORT=.*|POINTY_BACKEND_PORT=${RIG_PORT}|" \
        -e "s|^POINTY_WEB_PORT=.*|POINTY_WEB_PORT=${RIG_WEB_PORT}|" \
        -e "s|^POINTY_BACKEND_BIND=.*|POINTY_BACKEND_BIND=127.0.0.1|" \
        -e "s|^POINTY_WEB_BIND=.*|POINTY_WEB_BIND=127.0.0.1|" \
        "${RIG_SHOP}/.env.example"
    printf 'COMPOSE_PROJECT_NAME=%s\n' "$RIG_PROJECT"
  } >"${RIG_SHOP}/.env"

  # Rewrite the relay URL in place rather than appending one. Appending would
  # leave the key twice, and the two readers disagree about which wins:
  # `docker compose --env-file` takes the LAST, while the update agent's own
  # grep|head -1 takes the FIRST. The rig would then point the containers at one
  # relay and the agent at another — and it would be the rig's bug, dressed up as
  # a mysterious agent failure. (The divergence itself is real and pinned in the
  # unit tests; this is just not the place to exercise it.)
  if [ -n "${RIG_RELAY_URL:-}" ]; then
    sed -i.bak -e "s|^POINTY_RELAY_PUBLIC_API_URL=.*|POINTY_RELAY_PUBLIC_API_URL=${RIG_RELAY_URL}|" \
      "${RIG_SHOP}/.env"
    rm -f "${RIG_SHOP}/.env.bak"
  fi

  rig_log "installing ${version} into ${RIG_SHOP} (front door on :${RIG_PORT})…"
  ( cd "$RIG_SHOP" && bash install.sh ) >"${RIG_RUN_DIR}/install-${version}.log" 2>&1 || {
    rig_fail "install.sh failed for ${version}" "see ${RIG_RUN_DIR}/install-${version}.log" \
      "$(tail -20 "${RIG_RUN_DIR}/install-${version}.log")"
    return 1
  }
  rig_wait_serving 90 || { rig_fail "the shop never served after install"; return 1; }
  rig_log "shop is up on ${version}"
}

rig_compose() { ( cd "$RIG_SHOP" && docker compose --env-file .env -f docker-compose.yml "$@" ); }

# Any shop left behind by an interrupted run holds the old release's images and
# containers, which silently changes what a LATER run observes — a stale project
# is why `docker image rm` refuses to prune, and a rig that lies in that
# direction (passing when it should not) is worse than no rig. Swept at both
# ends of every run.
rig_sweep_leaked_shops() {
  local project
  docker rm -f pointy-backend-standby >/dev/null 2>&1
  for project in $(docker compose ls --all --format json 2>/dev/null \
      | python3 -c "import json,sys
try:
    print('\n'.join(x['Name'] for x in json.load(sys.stdin)))
except Exception:
    pass" | grep '^rehearsal-'); do
    [ "$project" = "${RIG_PROJECT:-}" ] && continue
    rig_log "sweeping a leaked rehearsal shop: ${project}"
    docker compose -p "$project" down -v --remove-orphans --timeout 3 >/dev/null 2>&1
  done
}

# Kill a process and everything below it, WITHOUT touching the process group.
# A background job started from a non-interactive shell shares its parent's
# group, so `kill -- -$pgid` would take the rehearsal down with the updater —
# which is a spectacular way to make a power-cut scenario produce no output at
# all rather than a result.
rig_kill_tree() {
  local pid="$1" child
  for child in $(pgrep -P "$pid" 2>/dev/null); do
    rig_kill_tree "$child"
  done
  kill -9 "$pid" 2>/dev/null
}

rig_teardown_shop() {
  [ -n "${RIG_SHOP:-}" ] || return 0
  [ -d "$RIG_SHOP" ] || return 0
  docker rm -f pointy-backend-standby >/dev/null 2>&1
  rig_compose down -v --remove-orphans --timeout 5 >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Looking at the shop from where a till stands
# ---------------------------------------------------------------------------

rig_url() { printf 'http://127.0.0.1:%s%s' "$RIG_PORT" "${1:-/}"; }

rig_curl() { curl -sS --max-time 10 "$(rig_url "${1:-/}")" 2>&1; }

rig_headers() { curl -sS -D- -o /dev/null --max-time 10 "$(rig_url "${1:-/}")" 2>/dev/null | tr -d '\r'; }

# Which container the front door is sending traffic to, as the front door itself
# reports it — not as a file on disk claims.
rig_upstream() {
  rig_headers /healthz/ | sed -n 's/^[Xx]-[Pp]ointy-[Uu]pstream: //p' | head -1
}

# Which RELEASE actually answered. The header comes from the application
# container, so this is the only honest answer to "did the update take effect?".
rig_served_version() {
  rig_headers /healthz/ | sed -n 's/^[Xx]-[Pp]ointy-[Ss]tub-[Vv]ersion: //p' | head -1
}

rig_installed_version() { cat "${RIG_SHOP}/VERSION.txt" 2>/dev/null | tr -d '[:space:]'; }

rig_serving() { curl -fsS --max-time 5 "$(rig_url /readyz/)" >/dev/null 2>&1; }

rig_wait_serving() {
  local tries="${1:-60}" i=0
  while [ "$i" -lt "$tries" ]; do
    rig_serving && return 0
    i=$((i + 1)); sleep 1
  done
  return 1
}

rig_container_id() { rig_compose ps -aq "$1" 2>/dev/null | head -1; }

rig_container_running() {
  [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]
}

rig_env_value() { grep -E "^$1=" "${RIG_SHOP}/.env" 2>/dev/null | head -1 | cut -d= -f2-; }

# ---------------------------------------------------------------------------
# Traffic through the front door for the whole update
# ---------------------------------------------------------------------------

rig_load_start() {
  RIG_LOAD_OUT="${RIG_RUN_DIR}/load-$(date +%s%N).json"
  "${RIG_BIN}/loadgen" loadgen \
    -url "$(rig_url "${1:-/api/ping}")" \
    -workers "${RIG_LOAD_WORKERS:-6}" \
    -interval "${RIG_LOAD_INTERVAL:-15ms}" \
    -timeout 5s \
    -out "$RIG_LOAD_OUT" &
  RIG_LOAD_PID=$!
  # Let it establish its keep-alive connections before anything moves, so the
  # flip happens on warm connections — the case that actually risks a drop.
  sleep 1
}

rig_load_stop() {
  [ -n "${RIG_LOAD_PID:-}" ] || return 0
  kill -TERM "$RIG_LOAD_PID" 2>/dev/null
  wait "$RIG_LOAD_PID" 2>/dev/null
  RIG_LOAD_PID=""
  [ -f "$RIG_LOAD_OUT" ] || { rig_fail "the load generator wrote no summary"; return 1; }
}

rig_load_field() { python3 -c "
import json,sys
print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$RIG_LOAD_OUT" "$1" 2>/dev/null; }

rig_load_json() { cat "$RIG_LOAD_OUT" 2>/dev/null; }

# What KIND of failures, not just how many. A refused connection, a timeout and
# a 502 mean three different things: nothing listening, something too slow, and
# the front door pointing at a backend that is not there.
rig_load_breakdown() {
  python3 -c "
import json,sys
d = json.load(open(sys.argv[1]))
print('refused=%s timeout=%s http_error=%s other=%s statuses=%s' % (
    d['connection_refused'], d['timeout'], d['http_error'], d['other_error'], d['statuses']))
errs = d.get('first_errors') or []
if errs:
    print('    first errors: ' + '; '.join(errs[:3]))
offsets = d.get('failure_offsets_ms') or []
if offsets:
    print('    failures fell between %sms and %sms into the run (a %sms window)' % (
        offsets[0], offsets[-1], offsets[-1] - offsets[0]))
" "$RIG_LOAD_OUT" 2>/dev/null
}

# The claim a live update makes is that the SHOP never goes down. Two numbers
# decide that, and they are not the same as "zero failures":
#
#   longest_failure_streak  consecutive failures. 0 means that at every instant
#                           SOME request was being served — the shop was up.
#   max_gap_ms              the longest a till went without a good response.
#
# A handful of isolated failures interleaved with thousands of successes is a
# different animal from a two-second hole, and only one of them is an outage.
# See the note on stale nginx workers in README.md for what the isolated ones
# turn out to be.
rig_assert_shop_never_went_down() { # <label>
  local streak gap total failed rate
  streak="$(rig_load_field longest_failure_streak)"
  gap="$(rig_load_field max_gap_ms)"
  total="$(rig_load_field total)"
  failed="$(rig_load_field failed)"
  rig_assert_eq "0" "${streak:-1}" "${1}: there was never an instant with no healthy backend"
  rig_assert_le "${gap:-99999}" "${RIG_MAX_GAP_MS:-3000}" "${1}: no gap a cashier could see"
  # Isolated failures are bounded, reported, and never allowed to grow quietly.
  rate="$(python3 -c "print(int(round(${failed:-0} * 10000.0 / max(1, ${total:-1}))))" 2>/dev/null)"
  rig_log "isolated failures: ${failed:-0}/${total:-0} ($(python3 -c "print('%.3f' % (${rate:-0}/100.0))" 2>/dev/null)%)"
  rig_assert_le "${rate:-9999}" "${RIG_MAX_FAILURE_RATE_BP:-20}" \
    "${1}: isolated failures stayed under 0.2% of requests"
}

rig_load_versions_seen() { python3 -c "
import json,sys
print(' '.join(json.load(open(sys.argv[1]))['version_order'] or []))" "$RIG_LOAD_OUT" 2>/dev/null; }

rig_load_upstreams_seen() { python3 -c "
import json,sys
print(' '.join(json.load(open(sys.argv[1]))['upstream_order'] or []))" "$RIG_LOAD_OUT" 2>/dev/null; }

# The (container, release) hand-over sequence. With several keep-alive workers
# this legitimately interleaves during a reload — old nginx workers keep serving
# the old upstream until their connections retire — so it is for reading, not
# for asserting. Assert on the final state and the overlap window instead.
rig_load_transitions() { python3 -c "
import json,sys
print(' -> '.join(json.load(open(sys.argv[1]))['transitions'] or []))" "$RIG_LOAD_OUT" 2>/dev/null; }

rig_load_final_version()  { rig_load_field final_version; }
rig_load_final_upstream() { rig_load_field final_upstream; }

# How long two releases were answering at once: from the first response served by
# the new one to the last served by the old. This IS the expand/contract window —
# the minute the whole "migrations must be backward compatible" rule exists for —
# so the rehearsal reports it as a number rather than assuming it is short.
rig_load_overlap_ms() { # <old-version> <new-version>
  python3 -c "
import json,sys
d = json.load(open(sys.argv[1]))
last_old = d['last_seen_ms'].get('version:' + sys.argv[2])
first_new = d['first_seen_ms'].get('version:' + sys.argv[3])
print(-1 if last_old is None or first_new is None else max(0, last_old - first_new))
" "$RIG_LOAD_OUT" "$1" "$2" 2>/dev/null
}

# ---------------------------------------------------------------------------
# A real relay, for the half of remote update that lives off-site
#
# Everything above rehearses the shop's own engine. This part rehearses the
# thing an operator actually touches: the relay's control plane, its CLI, and
# the agent that talks to it. It is the REAL relay binary against a REAL
# Postgres and Redis, driven by the REAL CLI — because the questions worth
# asking here ("does pausing a rollout actually stop shops taking it?", "does
# `fleet status` tell the truth?") are questions about that code, not about a
# mock of it.
# ---------------------------------------------------------------------------

rig_relay_build() {
  [ -x "${RIG_BIN}/pointy-relay" ] && return 0
  rig_log "building the relay + operator CLI…"
  ( cd "${RIG_REPO_DIR}/relay" \
      && GOCACHE="${RIG_CACHE}/gocache" GOMODCACHE="${RIG_REPO_DIR}/relay/.gomodcache" \
         go build -o "${RIG_BIN}/pointy-relay" ./cmd/pointy-relay )
}

rig_relay_start() {
  rig_relay_build || return 1
  RIG_RELAY_PROJECT="rehearsal-relay-$$"
  RIG_RELAY_PG_PORT="$(rig_free_port)"
  RIG_RELAY_REDIS_PORT="$(rig_free_port)"
  RIG_RELAY_HTTP_PORT="$(rig_free_port)"
  RIG_RELAY_ADMIN_PORT="$(rig_free_port)"
  RIG_RELAY_CONNECTOR_PORT="$(rig_free_port)"
  RIG_RELAY_ADMIN_TOKEN="rehearsal-admin-$(openssl rand -hex 12)"
  RIG_RELAY_ARTIFACTS="${RIG_RUN_DIR}/relay-artifacts"
  RIG_RELAY_URL="http://127.0.0.1:${RIG_RELAY_HTTP_PORT}"
  RIG_RELAY_CONTROL_URL="http://127.0.0.1:${RIG_RELAY_ADMIN_PORT}"
  mkdir -p "$RIG_RELAY_ARTIFACTS"

  docker rm -f "${RIG_RELAY_PROJECT}-pg" "${RIG_RELAY_PROJECT}-redis" >/dev/null 2>&1
  docker run -d --name "${RIG_RELAY_PROJECT}-pg" \
    -e POSTGRES_PASSWORD=postgres -e POSTGRES_USER=postgres -e POSTGRES_DB=pointy \
    -p "127.0.0.1:${RIG_RELAY_PG_PORT}:5432" "$RIG_POSTGRES_IMAGE" >/dev/null || return 1
  docker run -d --name "${RIG_RELAY_PROJECT}-redis" \
    -p "127.0.0.1:${RIG_RELAY_REDIS_PORT}:6379" "$RIG_REDIS_IMAGE" >/dev/null || return 1

  RIG_RELAY_DB="postgres://postgres:postgres@127.0.0.1:${RIG_RELAY_PG_PORT}/pointy?sslmode=disable"
  RIG_RELAY_REDIS="redis://127.0.0.1:${RIG_RELAY_REDIS_PORT}/0"

  local i=0
  while [ "$i" -lt 60 ]; do
    docker exec "${RIG_RELAY_PROJECT}-pg" pg_isready -U postgres >/dev/null 2>&1 && break
    i=$((i + 1)); sleep 1
  done
  [ "$i" -lt 60 ] || { rig_fail "the relay's postgres never became ready"; return 1; }

  "${RIG_BIN}/pointy-relay" migrate --database-url "$RIG_RELAY_DB" \
    >"${RIG_RUN_DIR}/relay-migrate.log" 2>&1 || {
      rig_fail "relay migrations failed" "$(tail -10 "${RIG_RUN_DIR}/relay-migrate.log")"; return 1; }

  POINTY_RELAY_ADMIN_TOKEN="$RIG_RELAY_ADMIN_TOKEN" \
  POINTY_RELAY_ALLOW_INSECURE_HTTP=true \
  POINTY_RELAY_ALLOW_INSECURE_CONNECTOR=true \
    "${RIG_BIN}/pointy-relay" server \
      --http "127.0.0.1:${RIG_RELAY_HTTP_PORT}" \
      --admin-http "127.0.0.1:${RIG_RELAY_ADMIN_PORT}" \
      --connector "127.0.0.1:${RIG_RELAY_CONNECTOR_PORT}" \
      --database-url "$RIG_RELAY_DB" \
      --redis-url "$RIG_RELAY_REDIS" \
      --artifact-dir "$RIG_RELAY_ARTIFACTS" \
      >"${RIG_RUN_DIR}/relay-server.log" 2>&1 &
  RIG_RELAY_PID=$!

  i=0
  while [ "$i" -lt 60 ]; do
    curl -fsS --max-time 2 "${RIG_RELAY_URL}/healthz" >/dev/null 2>&1 && break
    kill -0 "$RIG_RELAY_PID" 2>/dev/null || break
    i=$((i + 1)); sleep 1
  done
  curl -fsS --max-time 2 "${RIG_RELAY_URL}/healthz" >/dev/null 2>&1 || {
    rig_fail "the relay never came up" "$(tail -20 "${RIG_RUN_DIR}/relay-server.log")"; return 1; }
  rig_log "relay serving on ${RIG_RELAY_URL} (admin ${RIG_RELAY_CONTROL_URL})"
}

rig_relay_stop() {
  # Killed deliberately; the shell's job-control notice is noise in the report.
  if [ -n "${RIG_RELAY_PID:-}" ]; then
    rig_kill_tree "$RIG_RELAY_PID"
    wait "$RIG_RELAY_PID" 2>/dev/null
  fi
  [ -n "${RIG_RELAY_PROJECT:-}" ] && \
    docker rm -f "${RIG_RELAY_PROJECT}-pg" "${RIG_RELAY_PROJECT}-redis" >/dev/null 2>&1
  return 0
}

# The operator CLI, with the admin plumbing filled in.
rig_relay_cli() {
  "${RIG_BIN}/pointy-relay" "$@" \
    --control-url "$RIG_RELAY_CONTROL_URL" \
    --admin-token "$RIG_RELAY_ADMIN_TOKEN" \
    --allow-insecure-control 2>&1
}

# Provision an installation and remember its id and connector token — the token
# the shop's agent will authenticate to the relay with.
rig_relay_provision() {
  local out
  out="$("${RIG_BIN}/pointy-relay" provision --database-url "$RIG_RELAY_DB" \
          --shop-name "Rehearsal Shop" --relay-enabled --subscription-active 2>&1)" || {
    rig_fail "provisioning failed" "$out"; return 1; }
  RIG_INSTALLATION_ID="$(printf '%s' "$out" | python3 -c "
import json,sys
print(json.loads(sys.stdin.read())['installation']['id'])" 2>/dev/null)"
  RIG_CONNECTOR_TOKEN="$(printf '%s' "$out" | python3 -c "
import json,sys
print(json.loads(sys.stdin.read())['connector_token'])" 2>/dev/null)"
  [ -n "$RIG_INSTALLATION_ID" ] && [ -n "$RIG_CONNECTOR_TOKEN" ] || {
    rig_fail "could not read the installation id / connector token" "$out"; return 1; }
  rig_log "provisioned installation ${RIG_INSTALLATION_ID}"
}

# What the relay believes about this shop right now.
rig_fleet_field() { # <json-field>
  rig_relay_cli fleet status --json 2>/dev/null | python3 -c "
import json,sys
raw = sys.stdin.read()
start = raw.find('{')
data = json.loads(raw[start:]) if start >= 0 else {}
rows = data.get('installations') or data.get('fleet') or []
for row in rows:
    if row.get('id') == sys.argv[1]:
        print(row.get(sys.argv[2], '') if row.get(sys.argv[2]) is not None else '')
        break
" "$RIG_INSTALLATION_ID" "$1" 2>/dev/null
}

# Run the shop's update agent exactly as its host timer would.
rig_run_agent() { ( cd "$RIG_SHOP" && bash update-agent.sh "$@" ) 2>&1; }

# ---------------------------------------------------------------------------
# Run lifecycle
# ---------------------------------------------------------------------------

rig_setup() {
  RIG_ARCH="$(docker info --format '{{.Architecture}}' 2>/dev/null)"
  case "$RIG_ARCH" in aarch64|arm64) RIG_ARCH=arm64 ;; *) RIG_ARCH=amd64 ;; esac
  RIG_RUN_DIR="${RIG_RUN_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/pointy-rehearsal-run-XXXXXX")}"
  mkdir -p "$RIG_CACHE" "$RIG_BUNDLES" "$RIG_BIN"
  docker info >/dev/null 2>&1 || { printf 'Docker is not reachable.\n' >&2; return 1; }
  rig_build_binaries || return 1
  rig_invalidate_stale_artifacts
  rig_build_infra_tars || return 1
  rig_sweep_leaked_shops
}

rig_summary() {
  printf '\n-----------------------------------------------------\n'
  if [ "$RIG_FAILURES" -eq 0 ]; then
    printf '%s: PASSED (%d assertions)\n' "${RIG_SCENARIO:-scenario}" "$RIG_ASSERTIONS"
    return 0
  fi
  printf '%s: FAILED (%d of %d assertions)\n' "${RIG_SCENARIO:-scenario}" "$RIG_FAILURES" "$RIG_ASSERTIONS"
  return 1
}
