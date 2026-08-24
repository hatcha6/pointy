#!/usr/bin/env bash
#
# Pointy on-prem manual updater (Linux / macOS hosts).
#
# Applies a newer release bundle to THIS deployment. By default it is a LIVE
# update: the new backend is started alongside the one serving customers, runs
# its migrations, has to pass /readyz, and only then takes traffic — so you can
# update a shop in the middle of the trading day without closing a till. Use it
# for shops without internet/relay, or to update on your own schedule:
#
#     bash update.sh /path/to/pointy-onprem-1.5.0.zip
#     bash update.sh /path/to/extracted/pointy-onprem-1.5.0/
#
# Options:
#     --restart   apply the old way — stop the whole stack and bring it back on
#                 the new images. Only for a maintenance window; the tills are
#                 offline for the length of a full restart.
#     --force     re-apply the version that is already installed.
#
# Run it from the CURRENT deploy directory (next to docker-compose.yml + .env).
# Data (.env, volumes, backups) is preserved; only images + scripts change.
#
# What a live update deliberately does NOT touch: the database, the cache, the
# connection pooler and the LAN front door. Their new images ship in the bundle
# and install at the next full restart (`bash install.sh`), because replacing
# them means recreating them — the one thing that cannot be done under a
# trading shop.
set -uo pipefail
# Everything below is relative to the deploy directory, including a few rm -rf.
cd "$(dirname "$0")" || exit 1

# shellcheck source=update-lib.sh
. ./update-lib.sh

SOURCE=""
MODE=auto
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --restart) MODE=restart ;;
    --live) MODE=live ;;
    --force) FORCE=1 ;;
    -*) pu_log "unknown option: $arg"; exit 1 ;;
    *) [ -n "$SOURCE" ] || SOURCE="$arg" ;;
  esac
done

fail() { pu_log "ERROR: $*"; exit 1; }

[ -n "$SOURCE" ] || fail "usage: bash update.sh <pointy-onprem-bundle.zip | bundle-dir> [--restart] [--force]"
[ -e "$SOURCE" ] || fail "bundle not found: $SOURCE"
command -v docker >/dev/null 2>&1 || fail "docker not found on PATH"
[ -f .env ] || fail ".env not found next to this script — run from the deploy directory"

POINTY_BUNDLE_STAGING=""
cleanup() {
  # Only the copy WE extracted. A bundle directory the operator pointed us at is
  # their own media — they may be installing several shops from one stick — so it
  # is never touched here; the archives inside ./images are shredded as they load.
  if [ -n "${POINTY_BUNDLE_STAGING:-}" ]; then
    pu_shred_staged_archives "$POINTY_BUNDLE_STAGING"
    rm -rf "$POINTY_BUNDLE_STAGING"
  fi
  pu_release_lock
}

pu_acquire_lock || exit 1
trap cleanup EXIT

pu_stage_bundle "$SOURCE" || fail "could not stage the bundle"

CURRENT_VERSION="$(pu_current_version)"
if [ "$POINTY_BUNDLE_VERSION" = "$CURRENT_VERSION" ] && [ "$FORCE" != 1 ]; then
  fail "already on ${CURRENT_VERSION}; pass --force to re-apply"
fi

pu_apply_bundle "$POINTY_BUNDLE_DIR" "$CURRENT_VERSION" "$POINTY_BUNDLE_VERSION" "$MODE"
