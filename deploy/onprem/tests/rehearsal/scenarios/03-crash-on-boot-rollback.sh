#!/usr/bin/env bash
#
# A release that dies on startup — a failed migration, a bad config, a missing
# environment variable.
#
# The interesting question is not whether it fails but HOW FAST. The engine waits
# up to POINTY_STANDBY_READY_TRIES x 10s for a new backend, which is half an hour
# on the default. A container that has already EXITED should not cost that: the
# engine watches for the exit and gives up immediately. On one shop that is a
# nicety; across a fleet it is the difference between a bad release costing you
# an afternoon and costing you a minute, because each shop holds its update lock
# — and reports "applying" to the relay — for as long as it waits.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. ./lib.sh
RIG_SCENARIO="03-crash-on-boot-rollback"
rig_setup >/dev/null || exit 1
trap 'rig_teardown_shop' EXIT

BROKEN=2.1.0-crash-on-boot

rig_step "installing a shop on 1.0.0"
rig_install_shop 1.0.0 || { rig_summary; exit 1; }
backend_before="$(rig_container_id backend)"

rig_step "traffic on, then an update to a release that dies on boot"
rig_load_start /api/ping
update_log="${RIG_RUN_DIR}/update-03.log"
started="$(date +%s)"
# Deliberately the PRODUCTION default budget: the whole point is that the engine
# must not use it. If it ever stops noticing the exit, this scenario stops
# finishing, which is a loud enough failure.
( cd "$RIG_SHOP" && bash update.sh "$(rig_bundle_path "$BROKEN")" ) >"$update_log" 2>&1
update_rc=$?
elapsed=$(( $(date +%s) - started ))
rig_load_stop
rig_log "update gave up after ${elapsed}s (exit ${update_rc})"

rig_step "did it fail fast?"
rig_assert_ne "0" "$update_rc" "update.sh reported failure"
# The default budget is 1800s. Anything in the same postcode as that means the
# engine is waiting out a timeout on a container it could see had died.
rig_assert_le "$elapsed" 120 "the engine noticed the container had exited instead of waiting out its 30-minute budget"
rig_assert_contains "$(cat "$update_log")" "exited during startup" \
  "the log says the new backend exited rather than 'never became ready'"

rig_step "was the operator given anything to work with?"
# A shop is not next to an engineer. Whatever the container said on its way out
# is the only diagnosis anyone gets, so it has to be in the update log.
rig_assert_contains "$(cat "$update_log")" "simulated boot failure" \
  "the dead container's own log output was captured into the update log"

rig_step "did the shop notice?"
rig_log "$(printf '%s requests, %s failed, %s refused' \
  "$(rig_load_field total)" "$(rig_load_field failed)" "$(rig_load_field connection_refused)")"
rig_log "$(rig_load_breakdown)"
rig_assert_eq "0" "$(rig_load_field failed)" "not one request failed"
rig_assert_eq "1.0.0" "$(rig_load_versions_seen)" "every request was served by 1.0.0 throughout"

rig_step "is the deployment where it started?"
rig_assert_eq "1.0.0" "$(rig_served_version)" "the shop is still serving 1.0.0"
rig_assert_eq "1.0.0" "$(rig_installed_version)" "VERSION.txt still says 1.0.0"
rig_assert_eq "pointy-backend:1.0.0" "$(rig_env_value POINTY_BACKEND_IMAGE)" "the image pin was rolled back"
rig_assert_eq "$backend_before" "$(rig_container_id backend)" "the managed backend was never touched"
rig_assert_eq "" "$(docker ps -aq -f name=pointy-backend-standby 2>/dev/null)" "the dead standby was removed"
rig_assert_no_file "${RIG_SHOP}/.update.lock" "the update lock was released"

rig_summary
