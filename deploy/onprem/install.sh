#!/usr/bin/env bash
#
# Pointy on-prem installer (Linux / macOS hosts).
#
# Run this from inside an extracted release bundle. If Docker isn't installed it
# installs it automatically (run as root on Linux), then loads the bundled Docker
# images (so the host never has to pull from a registry) and starts the stack.
# Re-run it any time — it is idempotent.
#
#   sudo bash install.sh
#
set -euo pipefail
cd "$(dirname "$0")"

err() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------------------
# WSL preflight.
#
# On Windows the stack runs inside a WSL2 distro (see wsl/bootstrap-wsl.ps1).
# Three WSL-specific mistakes destroy a shop's data quietly rather than loudly,
# so they are hard failures / loud warnings here rather than a line in a README
# nobody reads at 7am on install day.
# ---------------------------------------------------------------------------
running_under_wsl() {
  [ -n "${WSL_DISTRO_NAME:-}" ] && return 0
  grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null
}

wsl_preflight() {
  running_under_wsl || return 0
  echo "==> WSL detected (${WSL_DISTRO_NAME:-unknown}); running WSL preflight…"

  # 1. NEVER run from the Windows filesystem. /mnt/c is DrvFs (a 9p/plan9
  #    protocol bridge): roughly an order of magnitude slower, and — fatally —
  #    it does not honour POSIX locking or fsync ordering the way Postgres
  #    requires. A database on /mnt/c does not degrade, it corrupts.
  case "$PWD" in
    /mnt/*)
      err "this bundle is on the Windows filesystem (${PWD}).
       Postgres cannot run safely there: DrvFs does not give the file locking
       and fsync ordering the database needs, and the data WILL corrupt.
       Move the bundle onto the distro's own disk and re-run:
         cp -r \"${PWD}\" /opt/pointy && cd /opt/pointy && bash install.sh"
      ;;
  esac

  # 2. systemd must be PID 1, or register-autostart.sh has no supervisor to
  #    install the watchdog and update-agent timers into — the shop would come
  #    up once and never self-heal again.
  if [ "$(ps -p 1 -o comm= 2>/dev/null)" != "systemd" ]; then
    echo "WARN: systemd is not PID 1 in this distro." >&2
    echo "      The watchdog and update agent cannot be registered, so the stack" >&2
    echo "      will NOT come back on its own after a reboot or a crash." >&2
    echo "      Fix: put this in /etc/wsl.conf, then run 'wsl --shutdown' on Windows:" >&2
    echo "          [boot]" >&2
    echo "          systemd=true" >&2
  fi

  echo "    WSL preflight passed (running from ${PWD} on the distro's own disk)."
}

wsl_check_backup_drives() {
  running_under_wsl || return 0
  [ -f .env ] || return 0
  # External backup drives are bind-mounted from the Windows host. If the drive
  # is not attached, /mnt/<letter> does not exist — and Docker CREATES a missing
  # bind source as an empty directory inside the VM. Every backup then
  # "succeeds" into the very virtual disk it was meant to survive, and the shop
  # finds out on the one day it needs the backup.
  local key value letter
  for key in POINTY_BACKUP_DRIVE_1_SOURCE POINTY_BACKUP_DRIVE_2_SOURCE POINTY_BACKUP_DRIVE_3_SOURCE; do
    value="$(sed -n "s/^${key}=//p" .env | tail -1 | tr -d '\r')"
    case "$value" in
      /mnt/*)
        if [ ! -d "$value" ]; then
          letter="${value#/mnt/}"; letter="${letter%%/*}"
          echo "WARN: ${key}=${value} does not exist." >&2
          echo "      That drive is not attached (or Windows has not mounted it yet)." >&2
          echo "      Docker will silently create an empty folder INSIDE the virtual disk," >&2
          echo "      so your off-machine backups would go nowhere. Attach the drive, then:" >&2
          echo "          mkdir -p /mnt/${letter} && mount -t drvfs ${letter}: /mnt/${letter}" >&2
        fi
        ;;
      [A-Za-z]:*|*\\*)
        err "${key}=${value} is a Windows path. Inside WSL use the /mnt form instead
       (D:/PointyBackups becomes /mnt/d/PointyBackups)."
        ;;
    esac
  done
}

wsl_preflight

# Read a single KEY=value out of .env without evaluating it as shell.
#
# ALWAYS succeeds. "no such key" is an answer, not an error - but this is a
# pipeline, and under `set -o pipefail` a grep that matches nothing makes the
# whole substitution exit 1, which `set -e` then turns into the script dying
# mid-way through writing .env with nothing printed to say why.
env_value() {
  grep -E "^$1=" .env 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'" | tr -d '\r' || true
}

# ---------------------------------------------------------------------------
# .env: create it, then make sure it is COMPLETE.
#
# Creating it once was not enough. Every `${VAR:?...}` in docker-compose.yml is a
# variable the stack refuses to boot without, and the failure is a wall of
# "Set X in deploy/onprem/.env" from compose — by which point the operator is
# standing in a shop with no till. That happens whenever .env exists but is
# short of a key: a part-written file from an install that died half way, a
# hand-edited file, or an .env carried over from an older release that predates
# a variable.
#
# So the fill runs on EVERY install, not just the one that creates the file, and
# it only ever writes keys that are missing or empty. A value that is already
# there is never touched — regenerating the Postgres password on a shop with a
# database would lock it out of its own data.
# ---------------------------------------------------------------------------

# Replace KEY=... in .env (or append). awk avoids GNU/BSD sed -i differences and
# sed metacharacter escaping; our values are hex/URLs with no '=' so FS='=' is safe.
set_env_var() {
  local key="$1" value="$2" tmp
  if grep -qE "^${key}=" .env; then
    tmp="$(mktemp)"
    awk -v k="$key" -v v="$value" 'BEGIN{FS=OFS="="} $1==k{print k FS v; next} {print}' .env >"$tmp"
    mv "$tmp" .env
  else
    printf '%s=%s\n' "$key" "$value" >>.env
  fi
}

# A key that is still carrying the template's placeholder has no value. Anything
# that treats `replace-with-at-least-50-random-characters` as configured ships a
# shop a DJANGO_SECRET_KEY that is published in our git history, and a Postgres
# password that every other install also has.
env_needs_value() {
  local v
  v="$(env_value "$1")"
  [ -n "$v" ] || return 0
  case "$v" in *replace-with-*) return 0 ;; esac
  return 1
}

# Write only if the key has no real value yet. This is what makes the whole pass
# safe to re-run against a working shop.
set_env_default() {
  local key="$1" value="$2"
  env_needs_value "$key" || return 0
  set_env_var "$key" "$value"
  echo "    + ${key}"
}

# Every variable compose hard-requires, read out of compose itself so this list
# can never drift from the one that is actually enforced.
required_env_keys() {
  grep -oE '\$\{[A-Z_][A-Z0-9_]*:\?' docker-compose.yml | sed 's/^\${//; s/:?$//' | sort -u
}

# A default for a required key, taken from the shipped template. Used only when
# the key is absent from .env entirely.
example_value() {
  [ -f .env.example ] || return 0
  grep -E "^$1=" .env.example 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'" | tr -d '\r' || true
}

if [ ! -f .env ]; then
  # LICENSING TEMPORARILY OFF ("for now"): on-prem installs don't require a
  # license key, so a shop with no internet can run fully offline. The license
  # gate unlocks by redeeming the key with the relay *online* - which an offline
  # shop can never reach - so requiring it would brick the till. If a license.key
  # is present we still record it, so re-enabling licensing later (set
  # POINTY_REQUIRE_LICENSE=true once the shop has internet) enrolls without a
  # reinstall. To restore enforcement: make the file required again (err/exit) and
  # set POINTY_REQUIRE_LICENSE "true" below.
  LICENSE_FILE="${POINTY_LICENSE_FILE:-license.key}"
  LICENSE_KEY=""
  if [ -f "$LICENSE_FILE" ]; then
    LICENSE_KEY="$(tr -d '[:space:]' < "$LICENSE_FILE")"
  else
    echo "WARN: no license key at ./$LICENSE_FILE - installing without a license (offline mode)."
  fi

  [ -f .env.example ] || err "neither .env nor .env.example is here. This is not a
       complete release bundle - re-extract it and run install.sh from inside it."
  cp .env.example .env
  echo "==> Created .env from .env.example."
else
  LICENSE_KEY=""
  echo "==> Existing .env found; checking it is complete."
fi

command -v openssl >/dev/null 2>&1 || err "openssl is required to generate secrets. Install it and re-run."

# --- Secrets: generated once, then kept forever. ----------------------------
# Rotating any of these on a re-run would be silent data loss: a new Postgres
# password cannot open the existing database, and a new DJANGO_SECRET_KEY logs
# every till out and invalidates every signed URL.
set_env_default POINTY_POSTGRES_PASSWORD "$(openssl rand -hex 24)"
set_env_default DJANGO_SECRET_KEY "$(openssl rand -hex 48)"
set_env_default POINTY_RELAY_CONNECTOR_SETUP_TOKEN "$(openssl rand -hex 24)"
[ -z "$LICENSE_KEY" ] || set_env_default POINTY_RELAY_ENROLLMENT_TOKEN "$LICENSE_KEY"
set_env_default POINTY_REQUIRE_LICENSE "false"

# --- Database URLs, derived from whatever password we ended up with. --------
# Through PgBouncer, not straight at Postgres. The pooler is the thing that caps
# real backends; bypassing it is how a busy shop reached Postgres' connection
# limit and the till started refusing sales. Migrations still go direct, because
# Django's migrate takes a session-scoped advisory lock that a transaction-mode
# pooler cannot carry across statements.
pg_password="$(env_value POINTY_POSTGRES_PASSWORD)"
set_env_default POINTY_DATABASE_URL "postgres://pointy:${pg_password}@pgbouncer:5432/pointy"
set_env_default POINTY_DATABASE_DIRECT_URL "postgres://pointy:${pg_password}@postgres:5432/pointy"

# An install from before this fix wrote the app URL straight at postgres:5432.
# Move it onto the pooler, but only when it is exactly the shape we generated -
# a URL an operator pointed somewhere deliberately is left alone.
current_db_url="$(env_value POINTY_DATABASE_URL)"
case "$current_db_url" in
  "postgres://pointy:${pg_password}@postgres:5432/pointy")
    set_env_var POINTY_DATABASE_URL "postgres://pointy:${pg_password}@pgbouncer:5432/pointy"
    set_env_var POINTY_DATABASE_DIRECT_URL "postgres://pointy:${pg_password}@postgres:5432/pointy"
    echo "    ~ POINTY_DATABASE_URL moved onto PgBouncer (was bypassing the pooler)"
    ;;
esac

# --- Worker recycling: force it off. ----------------------------------------
# This was fix-backend-outages.sh, a script somebody had to know about and run
# by hand after the shop had already been losing its API at fixed intervals.
# POINTY_ASGI_MAX_REQUESTS>0 makes every ASGI worker self-terminate after N
# requests; steady polling from the tills drives them all to the limit within
# the same second, so the whole API dies together for the length of a Django
# cold start, on a timer. There is no shop for which that is the right setting.
for key in POINTY_ASGI_MAX_REQUESTS POINTY_ASGI_MAX_REQUESTS_JITTER; do
  current="$(env_value "$key")"
  case "$current" in
    ""|0) ;;
    *) set_env_var "$key" "0"
       echo "    ~ ${key}=0 (was ${current}: worker recycling caused interval outages)" ;;
  esac
done

# --- Anything still missing gets the shipped default. -----------------------
for key in $(required_env_keys); do
  env_needs_value "$key" || continue
  value="$(example_value "$key")"
  if [ -n "$value" ]; then
    case "$value" in *replace-with-*) continue ;; esac
    set_env_var "$key" "$value"
    echo "    + ${key} (from .env.example)"
  fi
done

# --- Carry over every other key the shipped template knows about. -----------
# The gate below only covers what compose REFUSES to start without. That is not
# the whole story: a key can be absent, take compose's `:-` fallback, and leave
# the shop quietly worse off. POINTY_RELAY_CONNECTOR_TLS_SERVER_NAME is the one
# that matters today - compose defaults it to empty, and the connector then has
# to recover the name from its bootstrap exchange or derive it from the relay
# address, which is a fallback rather than the answer the template already has.
#
# So an .env written before a key existed inherits it now. ABSENT keys only: a
# key that is present but empty was set that way deliberately, and a key that
# already has a value is the shop's, not ours.
carried=0
# Guarded: an incomplete bundle has no template, and redirecting from a file
# that is not there aborts the script on Linux before the check below can name
# what is missing - turning a clear refusal into a bare exit code.
if [ -f .env.example ]; then
  while IFS= read -r line; do
    case "$line" in
      [A-Z]*=*) ;;
      *) continue ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    grep -qE "^${key}=" .env && continue
    case "$value" in *replace-with-*) continue ;; esac
    printf '%s=%s\n' "$key" "$value" >>.env
    carried=$((carried + 1))
  done < .env.example
fi
[ "$carried" -eq 0 ] || echo "    + ${carried} key(s) this .env predated, taken from .env.example"

# --- The gate. --------------------------------------------------------------
# Compose would fail on these anyway, one confusing message at a time. Failing
# here names all of them at once, before anything is started, and while the
# installer still has the context to say what to do about it.
missing=""
for key in $(required_env_keys); do
  ! env_needs_value "$key" || missing="${missing} ${key}"
done
if [ -n "$missing" ]; then
  err "the following variables have no value in .env, and the stack cannot start
       without them:${missing}

       They normally come from the bundle's .env.example. Either this bundle is
       incomplete, or .env has been edited. Fill them in and re-run install.sh."
fi
echo "==> .env is complete ($(required_env_keys | wc -l | tr -d ' ') required variables present)."

# `--env-only` stops here: .env is created, repaired and checked, and nothing
# else has been touched. It is how you fix a shop whose .env is short of a key
# without pulling images or restarting containers, and it is what the tests
# drive. Everything below this line needs Docker.
case "${1:-}" in
  --env-only) echo "==> --env-only: stopping before Docker."; exit 0 ;;
esac

# Install Docker Engine + the Compose plugin (Linux, via Docker's official
# convenience script) or Docker Desktop (macOS, via Homebrew) when it is missing,
# so onboarding a fresh shop is just running this one script.
install_docker_linux() {
  if [ "$(id -u)" -ne 0 ]; then
    err "Docker isn't installed. Re-run as root so it can be installed automatically:  sudo bash install.sh"
  fi
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 \
    || err "Need curl or wget to download Docker. Install one and re-run."
  echo "    Fetching Docker's official install script…"
  script="$(mktemp)"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com -o "$script" || err "Could not download Docker (no internet?)."
  else
    wget -qO "$script" https://get.docker.com || err "Could not download Docker (no internet?)."
  fi
  sh "$script" || err "Docker installation failed."
  rm -f "$script"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now docker || true
  fi
}

install_docker_macos() {
  command -v brew >/dev/null 2>&1 \
    || err "On macOS, install Docker Desktop from https://www.docker.com/products/docker-desktop/ then re-run."
  echo "    Installing Docker Desktop via Homebrew…"
  brew install --cask docker || err "Homebrew could not install Docker Desktop."
  open -a Docker >/dev/null 2>&1 || true
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    return 0
  fi
  echo "==> Docker (with the Compose plugin) was not found; installing it now…"
  case "$(uname -s)" in
    Linux) install_docker_linux ;;
    Darwin) install_docker_macos ;;
    *) err "Automatic Docker install isn't supported on this OS; install Docker manually and re-run." ;;
  esac
  command -v docker >/dev/null 2>&1 || err "Docker still not found after install; install it manually and re-run."
}

ensure_docker

# If Docker is installed but the daemon isn't up, try to start it (best-effort).
if ! docker info >/dev/null 2>&1 && command -v systemctl >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
  systemctl start docker >/dev/null 2>&1 || true
fi

echo "==> Waiting for the Docker daemon…"
for _ in $(seq 1 60); do
  if docker info >/dev/null 2>&1; then break; fi
  sleep 5
done
docker info >/dev/null 2>&1 \
  || err "Docker daemon is not reachable. If Docker was just installed, a reboot/sign-out may be required — then re-run."
docker compose version >/dev/null 2>&1 \
  || err "Docker Compose v2 ('docker compose') is required but missing."

# ---------------------------------------------------------------------------
# Image archives are destroyed once Docker has taken them.
#
# ./images/pointy-*.tar is the softest target on the whole machine: two plain
# `tar xf` calls — no Docker, no root, no knowledge of anything — and the
# application's entire source tree is sitting in a directory. Docker's own image
# store is a materially harder target, and it is the one copy that has to exist
# for the stack to run, so the archives go as soon as `docker load` has them.
#
# What this costs, and it is not nothing: a shop can no longer re-install from
# its own deploy directory if Docker's image store is destroyed (Docker
# reinstalled, /var/lib/docker wiped). It needs the release bundle again for
# that. Set POINTY_KEEP_IMAGE_ARCHIVES=1 (env or .env) to keep them.
#
# Third-party archives (postgres/redis/pgbouncer) are deliberately left alone:
# they carry none of our code, they are freely downloadable anyway, and they are
# what a later maintenance restart loads.
# ---------------------------------------------------------------------------

keep_image_archives() {
  local flag="${POINTY_KEEP_IMAGE_ARCHIVES:-}"
  [ -n "$flag" ] || flag="$(env_value POINTY_KEEP_IMAGE_ARCHIVES)"
  case "$flag" in 1|true|TRUE|yes|YES) return 0 ;; *) return 1 ;; esac
}

# Overwrite once, then unlink. shred is not a guarantee on a journalling or
# copy-on-write filesystem, so this is defence in depth rather than a promise —
# the point is that the file is gone.
shred_archive() {
  if command -v shred >/dev/null 2>&1 && shred -n 1 -u "$1" 2>/dev/null; then
    return 0
  fi
  rm -f "$1"
}

# Are the application images already in Docker's store? This is what makes
# re-running the installer safe after a previous run shredded the archives.
app_images_loaded() {
  local key image
  for key in POINTY_BACKEND_IMAGE POINTY_RELAY_IMAGE POINTY_WEB_IMAGE; do
    image="$(env_value "$key")"
    [ -n "$image" ] || return 1
    docker image inspect "$image" >/dev/null 2>&1 || return 1
  done
  return 0
}

echo "==> Loading Pointy container images (this can take a minute)…"
shopt -s nullglob
images=(images/*.tar)
if [ ${#images[@]} -gt 0 ]; then
  for tar in "${images[@]}"; do
    echo "    - $tar"
    docker load -i "$tar"
    case "$(basename "$tar")" in
      pointy-*)
        if ! keep_image_archives; then
          shred_archive "$tar"
          echo "      archive removed (POINTY_KEEP_IMAGE_ARCHIVES=1 keeps it)"
        fi
        ;;
    esac
  done
elif [ -f .env ] && app_images_loaded; then
  # A re-run after a previous install shredded the archives. Every image is
  # already in Docker's store, which is all `compose up` needs.
  echo "    Already loaded (archives were removed after the last install)."
else
  err "No image archives under ./images, and the images they carry are not in
       Docker either. Archives are removed once they are loaded, so this is
       either an incomplete bundle or a machine whose Docker image store was
       wiped. Re-extract the release bundle and run install.sh from it."
fi

# The .env holds the Postgres password, DJANGO_SECRET_KEY (session forgery) and
# the relay tokens in clear text. Owner-only, every run — not just the run that
# created it, since an older install may predate this and a `cp` from a bundle
# lands with the umask default.
chmod 600 .env 2>/dev/null || true
if [ "$(id -u)" -eq 0 ]; then
  chown root:root .env 2>/dev/null || true
fi

# A full install/restart is the moment everything converges, so reset what a
# live update may have left pointing elsewhere: the LAN front door goes back to
# the managed backend, and any temporary container a previous update was serving
# from is removed. Both are safe no-ops on a fresh install.
echo "==> Resetting the LAN front door to the managed backend…"
mkdir -p edge/active
cat > edge/active/upstream.conf <<'UPSTREAM'
# GENERATED — the backend the LAN front door is currently sending traffic to.
# Rewritten by update.sh during a live update; reset here.
set $pointy_upstream      "http://backend:8000";
set $pointy_upstream_name "backend";
UPSTREAM
docker rm -f pointy-backend-standby >/dev/null 2>&1 || true

wsl_check_backup_drives

compose() { docker compose --env-file .env -f docker-compose.yml "$@"; }

# ---------------------------------------------------------------------------
# Starting the stack, without giving up on a backend that is only slow.
#
# `compose up -d` does more than start containers. The Celery workers and the
# relay connector wait for the backend to be HEALTHY, and compose abandons them
# the moment Docker's healthcheck calls the backend unhealthy:
#
#     dependency failed to start: container pointy-backend-1 is unhealthy
#
# The backend applies the release's migrations before it serves, and on a
# shop's machine that can outlast its healthcheck (Sufian's 2011 OptiPlex took
# about four minutes for 0.4.7 -> 0.5.1). Docker never stops an unhealthy
# container, so the backend finished and came up anyway, which is why a
# hand-run `compose up -d` a few minutes later always worked. By then `set -e`
# had ended this script: the client installers never reached the tills, the
# watchdog was never registered, and update.sh read the exit status as a broken
# release and rolled it back.
#
# So a failed `up` is tried again for as long as something is still coming up.
# It is an error only when the backend keeps crashing, when nothing is coming up
# and `up` still fails (a port in use, a missing image), or once
# POINTY_STACK_START_TIMEOUT seconds have passed (20 minutes by default).
# ---------------------------------------------------------------------------

# One line per container of the stack:
#   <service> <status> <health> <restarts> <depends_on>
# depends_on is compose's own record of what the service waits for, e.g.
# "backend:service_healthy:false". One-off `compose run` containers are not
# part of the stack.
stack_states() {
  local ids
  ids="$(compose ps -aq 2>/dev/null)" || true
  [ -n "$ids" ] || return 0
  # shellcheck disable=SC2086  # one argument per container id
  docker inspect -f '{{index .Config.Labels "com.docker.compose.oneoff"}} {{index .Config.Labels "com.docker.compose.service"}} {{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} {{.RestartCount}} {{index .Config.Labels "com.docker.compose.depends_on"}}' $ids 2>/dev/null \
    | awk '$1 != "True" { print $2, $3, $4, $5, $6 }' || true
}

# What compose is still waiting on, e.g. "backend (unhealthy)": a service that
# something depends on as `service_healthy` and that is still on its way up. A
# healthcheck inside its start period reports "starting", a container Docker is
# bringing back after a crash is "restarting", and a backend still migrating
# past its start period is running but "unhealthy": slow, not broken. Nothing
# waits on the web front door, so a sick one is not a reason to keep trying.
stack_pending() {
  stack_states | awk '
    { svc[NR] = $1; status[NR] = $2; health[NR] = $3
      n = split($5, deps, ",")
      for (i = 1; i <= n; i++) { split(deps[i], dep, ":"); if (dep[2] == "service_healthy") gate[dep[1]] = 1 } }
    END {
      for (r = 1; r <= NR; r++) {
        if (!(svc[r] in gate)) continue
        if (status[r] == "restarting") state = "restarting"
        else if (status[r] == "running" && (health[r] == "starting" || health[r] == "unhealthy")) state = health[r]
        else continue
        printf "%s%s (%s)", sep, svc[r], state; sep = ", "
      }
    }'
}

backend_restarts() { stack_states | awk '$1 == "backend" { print $4; exit }'; }

backend_log() { # <lines>
  local id
  id="$(compose ps -aq backend 2>/dev/null | head -1)" || true
  [ -n "$id" ] || return 0
  docker logs --tail "$1" "$id" 2>&1 || true
}

duration() { printf '%dm%02ds' $(($1 / 60)) $(($1 % 60)); }

# Wall-clock seconds. Not $SECONDS: one `compose up` can itself block for
# minutes, and the tests drive this loop with a clock of their own.
now() { date +%s; }

# The FTP upload server (`ftp`) is the one service a shop can trade without, and
# the one whose port — 21, plus a passive range — some other program on this
# machine may already hold. Compose fails the WHOLE `up` when a single container
# cannot bind its port, so a taken port 21 would fail the install and roll a
# restart-path update back. When everything but `ftp` comes up, that is a
# working shop: say what is missing, and carry on.
compose_up() {
  local rest port
  compose up -d && return 0
  rest="$(compose config --services 2>/dev/null | grep -vx ftp | tr '\n' ' ' || true)"
  [ -n "${rest// /}" ] || return 1
  # shellcheck disable=SC2086 # a list of service names, split on purpose
  compose up -d $rest || return 1
  # The first `up` may have failed for a reason that has since passed; only a
  # server that is really not running is worth a warning.
  compose ps --status running --services 2>/dev/null | grep -qx ftp && return 0
  port="$(env_value POINTY_FTP_PUBLIC_PORT)"
  echo "WARNING: everything is up except the FTP upload server. Most likely another" >&2
  echo "         program holds port ${port:-21} or the passive range 50000-50019. FTP" >&2
  echo "         camera setups receive nothing until it is freed (then run:" >&2
  echo "         docker compose up -d ftp); the rest of Pointy is unaffected." >&2
  return 0
}

start_stack() {
  local timeout started elapsed pending last restarts restarts_from attempt=1 idle=0 next_note=60 out
  timeout="${POINTY_STACK_START_TIMEOUT:-$(env_value POINTY_STACK_START_TIMEOUT)}"
  case "$timeout" in ''|*[!0-9]*) timeout=1200 ;; esac
  started="$(now)"

  compose_up && return 0

  echo "==> Compose stopped waiting, but the stack can still be coming up: usually the"
  echo "    backend applying this release's database migrations. Waiting for it and"
  echo "    trying again (for up to $(duration "$timeout"))…"
  out="$(mktemp)"
  restarts_from="$(backend_restarts)"
  while :; do
    elapsed=$(($(now) - started))
    if [ "$elapsed" -ge "$timeout" ]; then
      echo "ERROR: the stack was still not up after $(duration "$elapsed") (POINTY_STACK_START_TIMEOUT=${timeout})." >&2
      break
    fi
    # A crash loop is a broken release, not a slow one: say so now rather than
    # wait out the whole timeout on a container that cannot come up.
    restarts="$(backend_restarts)"
    if [ "${restarts:-0}" -ge $((${restarts_from:-0} + 3)) ]; then
      echo "ERROR: the backend keeps crashing (it restarted $((restarts - ${restarts_from:-0})) times while this waited)." >&2
      break
    fi
    pending="$(stack_pending)"
    if [ -n "$pending" ]; then
      idle=0
      if [ "$elapsed" -ge "$next_note" ]; then
        echo "    …still coming up after $(duration "$elapsed"): ${pending}"
        # The migration it is on, so a long wait reads as progress, not a hang.
        case "$pending" in
          *backend*) last="$(backend_log 1 | tail -1 | cut -c1-150)"
                     [ -z "$last" ] || echo "      backend: ${last}" ;;
        esac
        next_note=$((elapsed + 60))
      fi
    else
      # Nothing is coming up and `up` still fails: time will not fix that.
      idle=$((idle + 1))
      if [ "$idle" -gt 2 ]; then
        echo "ERROR: compose keeps failing, and nothing is still starting that it could be waiting for." >&2
        break
      fi
    fi
    sleep 10
    attempt=$((attempt + 1))
    if compose_up >"$out" 2>&1; then
      # A missing FTP server is worth repeating here: compose's own chatter
      # stays in the scratch file, but that warning is for the installer.
      sed -n '/^WARNING:/,$p' "$out" >&2
      rm -f "$out"
      echo "==> The stack is up, $(duration $(($(now) - started))) after starting it (compose tried ${attempt} times)."
      return 0
    fi
  done
  if [ -s "$out" ]; then
    echo "    What compose said last:" >&2
    sed 's/^/      /' "$out" >&2
  fi
  rm -f "$out"
  echo "    The backend's last log lines:" >&2
  backend_log 40 | sed 's/^/      /' >&2
  return 1
}

echo "==> Starting the Pointy stack…"
echo "    (The backend applies database migrations before it serves; on a large shop"
echo "    that can take several minutes. It is working, not stuck.)"
start_stack || err "the Pointy stack did not come up (see above), so the client installers
       were not published and the watchdog was not registered."

# Publish the bundled client installers (Android APK + Windows installer + Linux
# tar.gz) into the volume Django serves on the LAN, so on-site devices can
# download and self-update.
if [ -d ./clients ]; then
  echo "==> Publishing client installers for LAN download…"
  if compose cp clients/. backend:/var/lib/pointy/clients/; then
    compose exec -u 0 -T backend chmod -R a+rX /var/lib/pointy/clients >/dev/null 2>&1 || true
  else
    echo "WARN: could not publish client installers; retry with ./install.sh once the backend is up."
  fi
fi

# Register the boot/crash watchdog so the till self-recovers with no operator.
# Best-effort: needs root + systemd. Falls back to a printed instruction.
if command -v systemctl >/dev/null 2>&1; then
  if [ "$(id -u)" -eq 0 ]; then
    echo "==> Registering reboot/crash watchdog (systemd)…"
    bash register-autostart.sh || echo "WARN: watchdog registration failed; run 'sudo bash register-autostart.sh' manually."
  else
    echo "==> To make the stack survive reboots/crashes, run once:"
    echo "      sudo bash register-autostart.sh"
  fi
fi

cat <<'MSG'

Done. Useful follow-ups:

  Status : docker compose --env-file .env -f docker-compose.yml ps
  Logs   : docker compose --env-file .env -f docker-compose.yml logs -f backend
  Health : curl http://127.0.0.1:8000/healthz/   (web alive)
           curl http://127.0.0.1:8000/readyz/    (web + database + Redis)

Resilience: every service uses `restart: always`, and the watchdog re-runs the
stack at boot + every 5 min (recreating destroyed containers, restarting wedged
ones, and starting the Docker daemon itself if it is down). Registering the
watchdog also enables Docker on boot; if you skipped registration, run:
sudo systemctl enable docker
MSG
