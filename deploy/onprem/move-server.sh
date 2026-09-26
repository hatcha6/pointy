#!/usr/bin/env bash
#
# Move a Pointy on-prem server to another Linux machine - whole.
#
# Everything that makes a shop's server THAT shop's server travels: the deploy
# directory (.env with its secrets, VERSION.txt, update state, pre-update
# backups), every Docker volume of the stack (the database - and with it the
# shop's installation ID - product images, backups, the relay connector's
# certificate) and the exact images it runs. The new machine comes up as the
# same installation: same data, same logins, same relay enrollment. The tills
# find it again by themselves, because they match a server by its installation
# ID, not by its address.
#
# For a shop leaving WSL (Windows) for a Linux box, or a dead server replaced by
# a new one.
#
#   On the OLD server, at closing time. On Windows, keep-pointy-running.ps1
#   -ExportTo runs this inside WSL for you:
#       sudo bash move-server.sh export /media/usb/PointyMove
#
#   On the NEW machine (Linux Mint 21/22, Ubuntu 22.04/24.04, Debian 12;
#   64-bit Intel/AMD), with the same drive attached:
#       sudo bash /media/usb/PointyMove/move-server.sh import /media/usb/PointyMove
#
# export STOPS the stack for a consistent copy and leaves it stopped - with its
# containers removed, so no reboot can bring it back - because a sale rung up
# on the old server after the copy would be lost. --restart makes it a
# rehearsal instead: the same full copy, then the old server comes straight
# back. --skip-local-backups leaves out the backup archives kept on the server
# itself, when the drive is too small for them.
#
# import refuses to touch a machine that already has a Pointy installation.
set -euo pipefail

FORMAT=1
PROG="$(basename "$0")"
SELF="$(cd "$(dirname "$0")" && pwd)/${PROG}"
# Scratch space the stack recreates by itself; copying it moves nothing of value.
SKIP_VOLUMES=" pointy-tmp pointy-backup-staging "

err()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
log()  { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*"; }

usage() { sed -n '2,32p' "$SELF" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# KEY=value out of an env file without evaluating it as shell. Always succeeds.
env_value() {
  grep -E "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'" | tr -d '\r' || true
}

# Replace KEY=... in an env file (or append), like install.sh does.
set_env_var() {
  local file="$1" key="$2" value="$3" tmp
  if grep -qE "^${key}=" "$file"; then
    tmp="$(mktemp)"
    awk -v k="$key" -v v="$value" 'BEGIN{FS=OFS="="} $1==k{print k FS v; next} {print}' "$file" >"$tmp"
    cat "$tmp" >"$file"   # keeps the file's owner and 0600 mode
    rm -f "$tmp"
  else
    printf '%s=%s\n' "$key" "$value" >>"$file"
  fi
}

human() { # bytes -> "1.2 GB"
  awk -v b="$1" 'BEGIN{ split("B KB MB GB TB", u, " "); i = 1; while (b >= 1024 && i < 5) { b /= 1024; i++ }
                        printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i] }'
}

dir_bytes() { du -sb "$1" 2>/dev/null | cut -f1; }

running_under_wsl() {
  [ -n "${WSL_DISTRO_NAME:-}" ] && return 0
  grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null
}

dc() { (cd "$DEPLOY_DIR" && docker compose --env-file .env -f docker-compose.yml "$@"); }

# Archives are written in 1 GB pieces (<name>.0000, .0001, ...): a FAT32 USB
# stick - the format most of them ship in - cannot hold a file over 4 GB.
PIECE_SIZE="1000m"
write_pieces() { split -b "$PIECE_SIZE" -d -a 4 - "$1."; }
has_pieces() { [ -f "$1.0000" ]; }
read_pieces() { cat "$1".[0-9][0-9][0-9][0-9]; }

# This machine's LAN addresses - not Docker's own bridges.
lan_ips() {
  if command -v ip >/dev/null 2>&1; then
    ip -4 -o addr show scope global 2>/dev/null | awk '$2 !~ /^(docker|br-|veth)/ { split($4, a, "/"); print a[1] }'
  else
    hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.' || true
  fi
}

have_systemd() { command -v systemctl >/dev/null 2>&1 && [ "$(ps -p 1 -o comm= 2>/dev/null)" = "systemd" ]; }

installation_id() {
  dc exec -T postgres psql -U pointy -d pointy -tAc \
    "select installation_id from core_relayinstallation order by id limit 1" </dev/null 2>/dev/null | tr -d '[:space:]' || true
}


# ===========================================================================
# export
# ===========================================================================

LOCK_HELD=0
STACK_STOPPED=0
EXPORT_DONE=0
TIMERS_STOPPED=()

restore_timers() {
  local unit
  for unit in "${TIMERS_STOPPED[@]+"${TIMERS_STOPPED[@]}"}"; do
    systemctl start "$unit" >/dev/null 2>&1 || true
  done
  TIMERS_STOPPED=()
}

on_export_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ "$EXPORT_DONE" -ne 1 ]; then
    warn "the export did not finish; this server keeps running as before."
    if [ "$STACK_STOPPED" -eq 1 ]; then
      dc start >/dev/null 2>&1 || dc up -d >/dev/null 2>&1 || warn "could not start the stack again - run: cd ${DEPLOY_DIR} && sudo bash install.sh"
    fi
    restore_timers
  fi
  if [ "$LOCK_HELD" -eq 1 ]; then rm -f "${DEPLOY_DIR}/.update.lock"; fi
}

cmd_export() {
  local target="${1:-}"
  [ -n "$target" ] || usage 1
  shift
  local restart=0 skip_backups=0 arg
  for arg in "$@"; do
    case "$arg" in
      --restart) restart=1 ;;
      --skip-local-backups) skip_backups=1 ;;
      *) err "unknown option for export: ${arg}" ;;
    esac
  done

  [ "$(id -u)" -eq 0 ] || err "run as root: sudo bash ${PROG} export <folder>"
  command -v docker >/dev/null 2>&1 || err "docker is not installed on this machine."
  docker info >/dev/null 2>&1 || err "the Docker daemon is not running."
  docker compose version >/dev/null 2>&1 || err "Docker Compose v2 ('docker compose') is missing."

  DEPLOY_DIR="${POINTY_DEPLOY_DIR:-/opt/pointy}"
  [ -f "${DEPLOY_DIR}/docker-compose.yml" ] && [ -f "${DEPLOY_DIR}/.env" ] \
    || err "no Pointy installation at ${DEPLOY_DIR} (set POINTY_DEPLOY_DIR to where it is)."
  DEPLOY_DIR="$(cd "$DEPLOY_DIR" && pwd)"

  mkdir -p "$target" || err "cannot create ${target}"
  target="$(cd "$target" && pwd)"
  case "$target/" in "${DEPLOY_DIR}/"*) err "the export folder must be outside ${DEPLOY_DIR}." ;; esac
  if [ -e "${target}/manifest.txt" ] || has_pieces "${target}/pointy-deploy.tar.gz" || [ -d "${target}/volumes" ]; then
    err "${target} already holds an export. Use an empty folder (or delete the old export first)."
  fi
  if ! touch "${target}/.write-test" 2>/dev/null; then err "cannot write to ${target}."; fi
  rm -f "${target}/.write-test"

  exec > >(tee -a "${target}/export.log") 2>&1
  log "=== Pointy export: ${DEPLOY_DIR} -> ${target} ==="

  local project
  project="$(env_value "${DEPLOY_DIR}/.env" COMPOSE_PROJECT_NAME)"
  [ -n "$project" ] || project="$(basename "$DEPLOY_DIR")"

  # An update in flight owns the stack; copying under it would copy half an update.
  local lock="${DEPLOY_DIR}/.update.lock" age
  if [ -f "$lock" ]; then
    age=$(( $(date +%s) - $(stat -c %Y "$lock" 2>/dev/null || echo 0) ))
    if [ "$age" -lt 3600 ]; then
      err "an update is running right now ($(cat "$lock" 2>/dev/null)). Wait for it to finish, then run this again."
    fi
  fi
  trap on_export_exit EXIT
  # The watchdog stands down while this lock is fresh; it is touched as the copy goes.
  printf 'pid=%s started=%s holder=move-server\n' "$$" "$(date '+%Y-%m-%dT%H:%M:%S')" >"$lock"
  LOCK_HELD=1

  local unit
  if have_systemd; then
    for unit in pointy-watchdog.timer pointy-update-agent.timer; do
      if systemctl is-active --quiet "$unit" 2>/dev/null; then
        systemctl stop "$unit" && TIMERS_STOPPED+=("$unit")
      fi
    done
  fi

  # --- what there is to copy ------------------------------------------------
  local volumes=() images=() name key img
  while IFS= read -r name; do
    [ -n "$name" ] && volumes+=("$name")
  done < <(docker volume ls -q --filter "label=com.docker.compose.project=${project}")
  [ "${#volumes[@]}" -gt 0 ] || err "no Docker volumes belong to the '${project}' stack - is this the right machine?"

  local have_db=0
  for name in "${volumes[@]}"; do
    [ "$name" = "${project}_pointy-postgres-data" ] && have_db=1
  done
  [ "$have_db" -eq 1 ] || err "the database volume ${project}_pointy-postgres-data was not found."

  # The images the containers actually run, plus any service not created yet.
  while IFS= read -r img; do
    [ -n "$img" ] || continue
    case " ${images[*]+"${images[*]}"} " in *" ${img} "*) continue ;; esac
    if docker image inspect "$img" >/dev/null 2>&1; then images+=("$img"); fi
  done < <( { docker ps -a --filter "label=com.docker.compose.project=${project}" --format '{{.Image}}'
              dc config --images 2>/dev/null; } | sort -u )
  [ "${#images[@]}" -gt 0 ] || err "could not find the stack's images."

  local total=0 bytes mp keys=() names=() sizes=()
  for name in "${volumes[@]}"; do
    key="$(docker volume inspect -f '{{index .Labels "com.docker.compose.volume"}}' "$name" 2>/dev/null || true)"
    case "$key" in ""|"<no value>") key="${name#"${project}"_}" ;; esac
    case "$SKIP_VOLUMES" in *" ${key} "*) continue ;; esac
    if [ "$skip_backups" -eq 1 ] && [ "$key" = "pointy-backups" ]; then
      warn "leaving out ${name} (--skip-local-backups): the backup archives kept on this server stay here."
      continue
    fi
    mp="$(docker volume inspect -f '{{.Mountpoint}}' "$name")"
    [ -d "$mp" ] || err "volume ${name} has no local mountpoint (${mp}); only local volumes can be moved."
    bytes="$(dir_bytes "$mp")"; bytes="${bytes:-0}"
    keys+=("$key"); names+=("$name"); sizes+=("$bytes")
    total=$(( total + bytes ))
  done
  local deploy_bytes image_bytes=0
  deploy_bytes="$(du -sb --exclude=images "$DEPLOY_DIR" 2>/dev/null | cut -f1)"; deploy_bytes="${deploy_bytes:-0}"
  for img in "${images[@]}"; do
    bytes="$(docker image inspect -f '{{.Size}}' "$img" 2>/dev/null || echo 0)"
    image_bytes=$(( image_bytes + bytes ))
  done
  total=$(( total + deploy_bytes + image_bytes ))

  log "to copy (before compression):"
  local i
  for i in "${!keys[@]}"; do log "  volume ${keys[$i]}: $(human "${sizes[$i]}")"; done
  log "  deploy folder ${DEPLOY_DIR}: $(human "$deploy_bytes")"
  log "  ${#images[@]} images: $(human "$image_bytes")"
  local free
  free=$(( $(df -Pk "$target" | awk 'NR==2 {print $4}') * 1024 ))
  log "  total $(human "$total"); free on the drive: $(human "$free")"
  if [ "$free" -lt $(( total / 2 )) ]; then
    err "not enough room on the drive: $(human "$free") free for up to $(human "$total"). Use a bigger drive, or --skip-local-backups."
  elif [ "$free" -lt "$total" ]; then
    warn "the drive may be too small once compression is counted; if it fills up the copy stops and this server simply keeps running."
  fi

  local install_id version
  install_id="$(installation_id)"
  version="$(cat "${DEPLOY_DIR}/VERSION.txt" 2>/dev/null || echo unknown)"

  # --- stop, cleanly ----------------------------------------------------------
  log "stopping the stack (the database shuts down cleanly first)..."
  STACK_STOPPED=1
  dc stop
  if [ -n "$(docker ps -q --filter "label=com.docker.compose.project=${project}")" ]; then
    err "some containers are still running after the stop: $(docker ps --filter "label=com.docker.compose.project=${project}" --format '{{.Names}}' | tr '\n' ' ')"
  fi
  local pg_clean="unknown" pg_id
  pg_id="$(dc ps -a -q postgres 2>/dev/null | head -1)"
  if [ -n "$pg_id" ]; then
    if [ "$(docker inspect -f '{{.State.ExitCode}}' "$pg_id" 2>/dev/null)" = "0" ]; then pg_clean="yes"; else pg_clean="no"; fi
  fi
  [ "$pg_clean" = "no" ] && warn "Postgres did not exit cleanly; the copy is still safe - Postgres recovers it on the first start."

  # --- copy ---------------------------------------------------------------------
  mkdir -p "${target}/volumes"
  log "copying the deploy folder (.env and all)..."
  tar -C "$(dirname "$DEPLOY_DIR")" --numeric-owner -czpf - \
    --exclude="$(basename "$DEPLOY_DIR")/images" --exclude="$(basename "$DEPLOY_DIR")/.update.lock" \
    "$(basename "$DEPLOY_DIR")" | write_pieces "${target}/pointy-deploy.tar.gz"
  for i in "${!keys[@]}"; do
    touch "$lock"
    log "copying volume ${keys[$i]} ($(human "${sizes[$i]}"))..."
    mp="$(docker volume inspect -f '{{.Mountpoint}}' "${names[$i]}")"
    tar -C "$mp" --numeric-owner -czpf - . | write_pieces "${target}/volumes/${keys[$i]}.tar.gz"
  done
  touch "$lock"
  log "copying the ${#images[@]} images..."
  docker save "${images[@]}" | gzip -1 | write_pieces "${target}/images.tar.gz"

  {
    echo "format=${FORMAT}"
    echo "created_at=$(date '+%Y-%m-%dT%H:%M:%S%z')"
    echo "source_host=$(hostname)"
    echo "arch=$(uname -m)"
    if running_under_wsl; then echo "source_kind=wsl"; else echo "source_kind=linux"; fi
    echo "deploy_dir=${DEPLOY_DIR}"
    echo "project=${project}"
    echo "version=${version}"
    echo "installation_id=${install_id}"
    echo "postgres_clean_shutdown=${pg_clean}"
    for i in "${!keys[@]}"; do echo "volume=${keys[$i]} ${names[$i]} ${sizes[$i]}"; done
    for img in "${images[@]}"; do echo "image=${img}"; done
  } >"${target}/manifest.txt"
  [ "$SELF" = "${target}/${PROG}" ] || cp "$SELF" "${target}/move-server.sh"

  touch "$lock"
  log "writing checksums and reading the copy back once to prove it..."
  ( cd "$target" && find . -type f ! -name SHA256SUMS ! -name 'SHA256SUMS.*' ! -name export.log -print0 \
      | sort -z | xargs -0 sha256sum >SHA256SUMS.partial && mv SHA256SUMS.partial SHA256SUMS )
  ( cd "$target" && sha256sum --quiet -c SHA256SUMS ) || err "the copy on ${target} does not read back correctly; the drive may be failing."

  # --- finish -------------------------------------------------------------------
  EXPORT_DONE=1
  if [ "$restart" -eq 1 ]; then
    log "rehearsal: starting the stack again on this machine..."
    dc start
    restore_timers
    log "done. The export in ${target} is complete; this server runs on as before."
    return 0
  fi

  # For good: remove the containers (every service is restart: always, so a
  # merely stopped stack comes back with the next boot) and every timer that
  # would start it again. The data stays in the volumes, untouched.
  dc down
  if have_systemd; then
    for unit in pointy-watchdog.timer pointy-watchdog.service pointy-update-agent.timer \
                pointy-update-agent.service pointy-discovery.service; do
      systemctl disable --now "$unit" >/dev/null 2>&1 || true
    done
    TIMERS_STOPPED=()
  fi
  printf 'This server was exported to %s on %s and stopped for good.\nTo run it here again instead: cd %s && sudo bash install.sh\n' \
    "$target" "$(date '+%Y-%m-%d %H:%M')" "$DEPLOY_DIR" >"${DEPLOY_DIR}/MOVED.txt"

  log "done. The stack on this machine is STOPPED FOR GOOD - do not start it again."
  log "installation ${install_id:-?}, version ${version}. Next, on the new Linux machine:"
  log "    sudo bash <drive>/$(basename "$target")/move-server.sh import <drive>/$(basename "$target")"
}


# ===========================================================================
# import
# ===========================================================================

# Docker Engine from Docker's own apt repository, the same source the WSL
# distro used. Not get.docker.com: it refuses Linux Mint by name.
ensure_docker() {
  command -v curl >/dev/null 2>&1 || apt-get install -y curl >/dev/null 2>&1 || true
  if command -v docker >/dev/null 2>&1; then
    if ! docker compose version >/dev/null 2>&1; then
      log "installing the Docker Compose plugin..."
      apt-get install -y docker-compose-plugin >/dev/null 2>&1 || apt-get install -y docker-compose-v2 \
        || err "Docker is installed but 'docker compose' is not, and it could not be added. Install the compose plugin and re-run."
    fi
  else
    local info os_id ubuntu_cn debian_cn version_cn pretty repo codename
    # shellcheck source=/dev/null
    info="$(. /etc/os-release; printf '%s|%s|%s|%s|%s' "${ID:-}" "${UBUNTU_CODENAME:-}" "${DEBIAN_CODENAME:-}" "${VERSION_CODENAME:-}" "${PRETTY_NAME:-}")"
    IFS='|' read -r os_id ubuntu_cn debian_cn version_cn pretty <<<"$info"
    if [ -n "$ubuntu_cn" ]; then repo=ubuntu; codename="$ubuntu_cn"          # Ubuntu, Linux Mint
    elif [ -n "$debian_cn" ]; then repo=debian; codename="$debian_cn"        # LMDE
    elif [ "$os_id" = "debian" ]; then repo=debian; codename="$version_cn"
    elif [ "$os_id" = "ubuntu" ]; then repo=ubuntu; codename="$version_cn"
    else err "cannot install Docker automatically on ${pretty:-this system}. Install Docker Engine with its compose plugin, then re-run."
    fi
    [ -n "$codename" ] || err "could not tell which ${repo} release this is; install Docker Engine by hand, then re-run."
    command -v apt-get >/dev/null 2>&1 || err "apt-get is missing; install Docker Engine by hand, then re-run."
    log "installing Docker Engine (${repo} ${codename}) - this needs internet, once..."
    apt-get update
    apt-get install -y ca-certificates curl
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${repo}/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
      "$(dpkg --print-architecture)" "$repo" "$codename" >/etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  fi
  systemctl enable --now docker >/dev/null 2>&1 || true
  local _
  for _ in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 2; done
  docker info >/dev/null 2>&1 || err "the Docker daemon did not start."
  # The stack's health checks use start_interval, which needs Engine 25+.
  local engine
  engine="$(docker version -f '{{.Server.Version}}' 2>/dev/null || echo 0)"
  if [ "${engine%%.*}" -lt 25 ] 2>/dev/null; then
    err "Docker Engine ${engine} is too old (the stack needs 25 or newer). Remove it and re-run this, which installs the current one from Docker's repository."
  fi
}

# A WSL install reaches USB backup drives as /mnt/<letter>. That path means
# nothing on Linux - and Docker would silently create it as an empty folder on
# the system disk, so "off-machine" backups would land on the machine.
fix_wsl_backup_drives() {
  local envf="${DEPLOY_DIR}/.env" n key value
  for n in 1 2 3; do
    key="POINTY_BACKUP_DRIVE_${n}_SOURCE"
    value="$(env_value "$envf" "$key")"
    case "$value" in
      /mnt/[A-Za-z]|/mnt/[A-Za-z]/*)
        set_env_var "$envf" "$key" "./external-backups/drive-${n}"
        mkdir -p "${DEPLOY_DIR}/external-backups/drive-${n}"
        warn "${key} was ${value}, a Windows drive as WSL saw it. It now points at ${DEPLOY_DIR}/external-backups/drive-${n}, which is on THIS disk. Set it to your backup drive's mount point in ${envf}, then run: cd ${DEPLOY_DIR} && sudo bash install.sh"
        ;;
    esac
  done
}

prepare_server_host() {
  # A server must never suspend: a sleeping box serves no till.
  if have_systemd; then
    systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target >/dev/null 2>&1 \
      && log "this machine will no longer sleep or hibernate"
  fi
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    local api web
    api="$(env_value "${DEPLOY_DIR}/.env" POINTY_BACKEND_PORT)"; api="${api:-8000}"
    web="$(env_value "${DEPLOY_DIR}/.env" POINTY_WEB_PORT)"; web="${web:-80}"
    ufw allow "${api}/tcp" >/dev/null && ufw allow "${web}/tcp" >/dev/null && ufw allow 47777/udp >/dev/null \
      && log "firewall (ufw): allowed tills in on TCP ${api}, TCP ${web} and UDP 47777"
  fi
}

cmd_import() {
  local src="${1:-}"
  [ -n "$src" ] || usage 1
  shift
  [ "$#" -eq 0 ] || err "unknown option for import: $1"
  [ "$(id -u)" -eq 0 ] || err "run as root: sudo bash ${PROG} import <folder>"
  [ -d "$src" ] || err "${src} is not a folder."
  src="$(cd "$src" && pwd)"
  local f
  for f in manifest.txt SHA256SUMS; do
    [ -f "${src}/${f}" ] || err "${src}/${f} is missing - is this a complete export?"
  done
  for f in pointy-deploy.tar.gz images.tar.gz; do
    has_pieces "${src}/${f}" || err "${src}/${f}.0000 is missing - is this a complete export?"
  done
  running_under_wsl && err "this is WSL. Import on the real Linux machine instead."

  exec > >(tee -a /var/log/pointy-move-import.log) 2>&1
  log "=== Pointy import from ${src} ==="

  manifest() { sed -n "s/^$1=//p" "${src}/manifest.txt" | head -1; }
  [ "$(manifest format)" = "$FORMAT" ] || err "this export was written by a different version of ${PROG}."
  DEPLOY_DIR="$(manifest deploy_dir)"
  local project version install_id
  project="$(manifest project)"
  version="$(manifest version)"
  install_id="$(manifest installation_id)"
  [ -n "$DEPLOY_DIR" ] && [ -n "$project" ] || err "the manifest is incomplete."
  [ "$(uname -m)" = "$(manifest arch)" ] \
    || err "the exported images are for $(manifest arch) machines; this one is $(uname -m)."
  log "installation ${install_id:-?}, version ${version}, exported $(manifest created_at) from $(manifest source_host) ($(manifest source_kind))"

  log "checking the export is intact (reads every file once)..."
  ( cd "$src" && sha256sum --quiet -c SHA256SUMS ) \
    || err "the export is damaged: a file does not match its checksum. Copy it again from the old machine."

  if [ -e "$DEPLOY_DIR" ] && [ -n "$(ls -A "$DEPLOY_DIR" 2>/dev/null)" ]; then
    err "${DEPLOY_DIR} already exists on this machine. This imports only onto a machine without Pointy; nothing was changed. (If an earlier import stopped half-way on this new machine, remove ${DEPLOY_DIR} and the ${project}_* Docker volumes, then run this again.)"
  fi

  ensure_docker

  local key name bytes
  while read -r key name bytes; do
    if docker volume inspect "$name" >/dev/null 2>&1; then
      err "a Docker volume named ${name} already exists here. This imports only onto a machine without Pointy; nothing was changed."
    fi
    has_pieces "${src}/volumes/${key}.tar.gz" || err "${src}/volumes/${key}.tar.gz.0000 is missing."
  done < <(sed -n 's/^volume=//p' "${src}/manifest.txt")

  log "restoring ${DEPLOY_DIR} (.env and all)..."
  mkdir -p "$(dirname "$DEPLOY_DIR")"
  read_pieces "${src}/pointy-deploy.tar.gz" | tar -C "$(dirname "$DEPLOY_DIR")" --numeric-owner -xzpf -
  rm -f "${DEPLOY_DIR}/.update.lock"

  log "loading the images..."
  read_pieces "${src}/images.tar.gz" | gunzip -c | docker load

  fix_wsl_backup_drives

  # Created the way compose labels its own volumes, and filled BEFORE any
  # container exists: Docker copies an image's files into a volume only while
  # it is empty, so these keep exactly what the old server had.
  local compose_version mp
  compose_version="$(docker compose version --short 2>/dev/null || echo 2)"
  while read -r key name bytes; do
    log "restoring volume ${key} ($(human "$bytes"))..."
    docker volume create --label "com.docker.compose.project=${project}" \
      --label "com.docker.compose.volume=${key}" --label "com.docker.compose.version=${compose_version}" \
      "$name" >/dev/null
    mp="$(docker volume inspect -f '{{.Mountpoint}}' "$name")"
    read_pieces "${src}/volumes/${key}.tar.gz" | tar -C "$mp" --numeric-owner -xzpf -
  done < <(sed -n 's/^volume=//p' "${src}/manifest.txt")

  # install.sh keeps an existing .env exactly as it is, starts the stack,
  # publishes the till installers and registers the boot-time systemd units.
  log "starting Pointy (install.sh)..."
  ( cd "$DEPLOY_DIR" && bash install.sh )

  prepare_server_host

  local api _ ready=0
  api="$(env_value "${DEPLOY_DIR}/.env" POINTY_BACKEND_PORT)"; api="${api:-8000}"
  log "waiting for Pointy to answer..."
  for _ in $(seq 1 60); do
    if curl -fsS -m 5 -o /dev/null "http://127.0.0.1:${api}/readyz/"; then ready=1; break; fi
    sleep 5
  done
  local now_id
  now_id="$(installation_id)"
  if [ "$ready" -ne 1 ]; then
    warn "Pointy has not answered on port ${api} yet. Check: cd ${DEPLOY_DIR} && docker compose --env-file .env -f docker-compose.yml ps"
  fi
  if [ -n "$install_id" ] && [ "$now_id" != "$install_id" ]; then
    warn "the installation ID reads '${now_id}', expected '${install_id}'."
  fi

  log "done. This machine is now the shop's Pointy server: installation ${now_id:-?}, version ${version}."
  log "tills reach it at: $(lan_ips | sed "s|.*|http://&:${api}|" | tr '\n' ' ')"
  log "the tills find it again by themselves; giving this machine the old server's IP address (a DHCP reservation) makes that instant."
  log "keep the old server switched off. Log: /var/log/pointy-move-import.log"
}


case "${1:-}" in
  export) shift; cmd_export "$@" ;;
  import) shift; cmd_import "$@" ;;
  -h|--help|help|"") usage 0 ;;
  *) err "unknown command: $1 (use export or import; --help for more)" ;;
esac
