#!/usr/bin/env bash
#
# A release that boots, listens, and never passes its readiness gate — the
# commonest real failure there is (a migration that does not finish) and the one
# a TCP-level check waves straight through.
#
# The question this scenario asks is not "does the update fail?" but "does the
# shop notice?". Nothing has moved at the point this is detected: the standby was
# never given traffic, so the correct outcome is a failed update that a cashier
# could not possibly have observed, and a deployment left byte-for-byte on the
# release it was already running.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. ./lib.sh
RIG_SCENARIO="02-never-ready-rollback"
rig_setup >/dev/null || exit 1
trap 'rig_teardown_shop' EXIT

BROKEN=2.0.0-never-ready

rig_step "installing a shop on 1.0.0"
rig_install_shop 1.0.0 || { rig_summary; exit 1; }

backend_before="$(rig_container_id backend)"
env_before="$(cat "${RIG_SHOP}/.env")"
infra_before=""
for service in postgres redis pgbouncer edge; do
  infra_before="${infra_before}${service}=$(rig_container_id "$service") "
done

rig_step "traffic on, then an update to a release that never becomes ready"
rig_load_start /api/ping
update_log="${RIG_RUN_DIR}/update-02.log"
started="$(date +%s)"
# PRODUCTION NOTE, deliberately overridden here. The engine waits
# POINTY_STANDBY_READY_TRIES (default 180) x 10s for the new backend — half an
# hour. That is generous for a slow shop machine and correct for one site, but
# on a fleet rollout a release that never becomes ready holds EVERY shop's update
# lock for thirty minutes before it gives up, and each shop reports "applying"
# to the relay for that whole time. Worth knowing before batching.
( cd "$RIG_SHOP" && POINTY_STANDBY_READY_TRIES=6 bash update.sh "$(rig_bundle_path "$BROKEN")" ) >"$update_log" 2>&1
update_rc=$?
elapsed=$(( $(date +%s) - started ))
rig_load_stop
rig_log "update gave up after ${elapsed}s (exit ${update_rc}) with a 6-try budget;"
rig_log "production default is POINTY_STANDBY_READY_TRIES=180, i.e. ~30 minutes holding the lock"

rig_step "the update failed"
rig_assert_ne "0" "$update_rc" "update.sh reported failure"
rig_assert_contains "$(cat "$update_log")" "never became ready" \
  "the log says the new backend never became ready"
rig_assert_contains "$(cat "$update_log")" "nothing was switched over" \
  "the log says plainly that no traffic was moved"

rig_step "did the shop notice?"
rig_log "$(printf '%s requests, %s failed, %s refused, largest gap %sms' \
  "$(rig_load_field total)" "$(rig_load_field failed)" \
  "$(rig_load_field connection_refused)" "$(rig_load_field max_gap_ms)")"
rig_log "$(rig_load_breakdown)"
rig_assert_ge "$(rig_load_field total)" 200 "enough traffic went through to mean anything"
rig_assert_eq "0" "$(rig_load_field failed)" "not one request failed during the failed update"
rig_assert_eq "1.0.0" "$(rig_load_versions_seen)" \
  "every single request was served by 1.0.0 — the broken release never took traffic"
rig_assert_eq "backend" "$(rig_load_upstreams_seen)" \
  "the front door never pointed anywhere but the managed backend"

rig_step "is the deployment exactly where it started?"
rig_assert_eq "1.0.0" "$(rig_served_version)" "the shop is still serving 1.0.0"
rig_assert_eq "1.0.0" "$(rig_installed_version)" "VERSION.txt was not moved"
rig_assert_eq "$env_before" "$(cat "${RIG_SHOP}/.env")" \
  ".env was restored byte-for-byte, so the watchdog cannot apply the half-staged release"
rig_assert_eq "pointy-backend:1.0.0" "$(rig_env_value POINTY_BACKEND_IMAGE)" \
  "the image pin was rolled back to 1.0.0"
rig_assert_eq "$backend_before" "$(rig_container_id backend)" \
  "the managed backend container was never touched — the abort came before any switchover"

infra_after=""
for service in postgres redis pgbouncer edge; do
  infra_after="${infra_after}${service}=$(rig_container_id "$service") "
done
rig_assert_eq "$infra_before" "$infra_after" "the infrastructure was never touched either"

rig_step "cleanup and the way back"
rig_assert_eq "" "$(docker ps -aq -f name=pointy-backend-standby 2>/dev/null)" \
  "the failed standby was torn down, not left holding a database connection"
rig_assert_no_file "${RIG_SHOP}/.update.lock" "the update lock was released"

# The old images are the ONLY way back. Pruning them on a failed update would
# turn a recoverable failure into a shop that cannot be restored without the
# bundle it was installed from.
rig_assert_ne "" "$(docker image inspect pointy-backend:1.0.0 --format '{{.Id}}' 2>/dev/null)" \
  "the running release's images were not pruned"
rig_assert_not_contains "$(cat "$update_log")" "removed the superseded image" \
  "nothing was pruned on a failed update"

# THE CONSEQUENCE THAT MATTERS MOST, and the reason this is asserted here rather
# than only in the unit tests. If a failed update left VERSION.txt claiming the
# release that failed, three things break at once and none of them are visible:
# update.sh refuses the retry as "already on X", the update agent sees
# assigned == current and reports `idle` forever instead of retrying, and the
# relay's fleet view shows the shop as updated while it still runs the old code.
# A rollout goes green with shops silently left behind.
rig_step "can the shop still be OFFERED the release that failed?"
retry_log="${RIG_RUN_DIR}/update-02-retry.log"
( cd "$RIG_SHOP" && POINTY_STANDBY_READY_TRIES=2 bash update.sh "$(rig_bundle_path "$BROKEN")" )   >"$retry_log" 2>&1
rig_assert_not_contains "$(cat "$retry_log")" "already on"   "the same release can be offered again — the shop did not record the failed version as installed"
rig_assert_contains "$(cat "$retry_log")" "updating 1.0.0 -> ${BROKEN}"   "the retry knows it is still on 1.0.0"

# A shop that failed an update must still be able to take the NEXT one.
rig_step "the shop can still be updated afterwards"
( cd "$RIG_SHOP" && bash update.sh "$(rig_bundle_path 1.1.0)" ) >"${RIG_RUN_DIR}/update-02-recover.log" 2>&1
rig_assert_eq "0" "$?" "a good release still applies cleanly after a failed one"
rig_assert_eq "1.1.0" "$(rig_served_version)" "the shop recovered onto 1.1.0"

rig_summary
