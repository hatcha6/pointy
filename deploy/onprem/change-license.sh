#!/usr/bin/env bash
#
# Re-license this shop with a different license key: for when the install
# redeemed the wrong one.
#
#   sudo bash change-license.sh <new-license-key>
#   sudo bash change-license.sh                    # reads the key from ./license.key
#   sudo bash change-license.sh <key> --yes        # no confirmation, for scripts
#
# Run it from the deploy directory, next to docker-compose.yml and .env, with the
# stack up and the relay reachable. In order, it:
#
#   1. redeems the new key with the relay and moves the backend onto the
#      installation that creates (manage.py relay_change_license). A key the
#      relay refuses (mistyped, already used, expired) changes nothing, and the
#      script stops there;
#   2. records the key in .env as POINTY_RELAY_ENROLLMENT_TOKEN, so a later
#      re-enrollment can never retry the old, spent one;
#   3. resets the relay connector. It keeps its identity in a volume and never
#      asks the backend again while that holds a token, so without this remote
#      access would go on connecting as the OLD installation.
#
# The tills keep selling throughout: the backend is never restarted.
#
# The old installation stays on the relay. Retiring it needs the operator's
# admin token; step 1 prints the command.
set -euo pipefail
cd "$(dirname "$0")"

err() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

KEY=""
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=1 ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    -*) err "unknown option: $arg" ;;
    *) [ -z "$KEY" ] || err "give one license key, not several."; KEY="$arg" ;;
  esac
done

LICENSE_FILE="${POINTY_LICENSE_FILE:-license.key}"
if [ -z "$KEY" ]; then
  [ -f "$LICENSE_FILE" ] || err "no license key given, and there is no ./${LICENSE_FILE} to read one from.
       Usage: sudo bash change-license.sh <new-license-key>"
  KEY="$(cat "$LICENSE_FILE")"
fi
# The same normalisation install.sh gives license.key.
KEY="$(printf '%s' "$KEY" | tr -d '[:space:]')"
[ -n "$KEY" ] || err "the license key is empty."

[ -f docker-compose.yml ] || err "docker-compose.yml not found - run this from the Pointy deploy directory."
[ -f .env ] || err ".env not found - this server was never installed; run install.sh first."
# Checked now, not when the key is already spent.
[ -w .env ] || err "cannot write .env - run as root: sudo bash change-license.sh"
[ -f update-lib.sh ] || err "update-lib.sh is missing from this deploy directory."
POINTY_LOG_TAG="change-license"
# shellcheck source=update-lib.sh
. ./update-lib.sh
declare -F pu_set_env_var >/dev/null \
  || err "update-lib.sh here is older than this script. Copy the one from the same bundle."

command -v docker >/dev/null 2>&1 || err "Docker is not installed."
docker info >/dev/null 2>&1 || err "cannot talk to Docker - run as root: sudo bash change-license.sh"
[ -n "$(pu_compose ps --status running --quiet backend 2>/dev/null)" ] \
  || err "the backend is not running. Start the stack first (bash install.sh)."

if [ "$ASSUME_YES" != 1 ] && ! { [ -t 0 ] && [ -t 1 ]; }; then
  err "nobody at a terminal to confirm. Re-run with --yes to go ahead."
fi

# The watchdog and the update agent both stand down while this is held, so
# neither can recreate the connector halfway through its reset.
pu_acquire_lock || err "an update is running on this server. Try again once it has finished."
trap pu_release_lock EXIT

echo "==> Redeeming the new key with the relay..."
redeem() {
  if [ "$ASSUME_YES" = 1 ]; then
    pu_compose exec -T backend python manage.py relay_change_license --no-input "$KEY"
  else
    # Attached to this terminal: the command asks first, naming the installation
    # it is about to replace.
    pu_compose exec backend python manage.py relay_change_license "$KEY"
  fi
}
redeem || err "the license was not changed (see above). This server is licensed exactly as it was."

# From here on the key is spent, so a failure no longer stops the script: each
# step still left is done, and whatever did not work is named at the end.
UNFINISHED=""

echo "==> Recording the new key in .env..."
if ! pu_set_env_var POINTY_RELAY_ENROLLMENT_TOKEN "$KEY"; then
  UNFINISHED="${UNFINISHED}
  - Set POINTY_RELAY_ENROLLMENT_TOKEN=${KEY} in .env."
fi

echo "==> Resetting the relay connector so remote access follows the new installation..."
reset_connector() {
  local project volume volumes
  # The project the running stack was actually started under, read off its
  # backend: compose lets the shell's COMPOSE_PROJECT_NAME override .env, and a
  # wrong guess would find no volume and leave the old identity in place.
  project="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' \
    "$(pu_container_id backend)" 2>/dev/null)"
  [ -n "$project" ] || return 1
  volumes="$(docker volume ls -q \
    --filter "label=com.docker.compose.project=${project}" \
    --filter "label=com.docker.compose.volume=pointy-connector-state")" || return 1
  pu_compose rm -s -f connector || return 1
  for volume in $volumes; do
    docker volume rm "$volume" >/dev/null || return 1
  done
  pu_compose up -d --no-deps connector
}
if ! reset_connector; then
  UNFINISHED="${UNFINISHED}
  - Reset the connector, which still connects as the old installation:
      docker compose --env-file .env -f docker-compose.yml rm -s -f connector
      docker volume rm \"\$(docker volume ls -q | grep 'pointy-connector-state\$')\"
      docker compose --env-file .env -f docker-compose.yml up -d --no-deps connector"
fi

if [ -n "$UNFINISHED" ]; then
  err "the license WAS changed, but these steps failed. Finish them by hand:${UNFINISHED}"
fi

cat <<'MSG'

Done. The connector re-registers as the new installation within a minute; to
watch it:  docker compose --env-file .env -f docker-compose.yml logs -f connector
MSG
