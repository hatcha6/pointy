#!/usr/bin/env bash
#
# The maintenance path: a release that declares it CANNOT be applied live,
# because its migrations are not backward compatible across one version.
#
# Downtime is expected here — that is the trade the release engineer made. What
# is not negotiable is that the shop comes back, on the new release, with its
# data intact: the database, cache and pooler must survive a "full restart"
# untouched, because "restart" means the application, never the state.
#
# It also puts a NUMBER on the outage. "Brief" is not a plan; a shop deciding
# whether to take this at 11am or at closing needs seconds.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. ./lib.sh
RIG_SCENARIO="05-restart-strategy"
rig_setup >/dev/null || exit 1
trap 'rig_teardown_shop' EXIT

rig_step "building a release that declares it needs a restart"
# 1.2.0's images already exist; this is the same release bundled with the marker.
RESTART_ONLY="1.2.0-restart-only"
rig_build_release "$RESTART_ONLY" || { rig_fail "could not build the release"; rig_summary; exit 1; }
rig_build_bundle "$RESTART_ONLY" restart >/dev/null || { rig_fail "could not build the bundle"; rig_summary; exit 1; }

rig_step "installing a shop on 1.0.0"
rig_install_shop 1.0.0 || { rig_summary; exit 1; }

postgres_before="$(rig_container_id postgres)"
redis_before="$(rig_container_id redis)"
pgbouncer_before="$(rig_container_id pgbouncer)"
edge_before="$(rig_container_id edge)"

# Something in the database's volume, so "the data survived" is a fact and not an
# inference from the container id.
rig_compose exec -T postgres psql -U pointy -d pointy \
  -c "CREATE TABLE rehearsal_marker (note text); INSERT INTO rehearsal_marker VALUES ('sale before the update');" \
  >/dev/null 2>&1
rig_assert_contains "$(rig_compose exec -T postgres psql -U pointy -d pointy -tAc 'SELECT note FROM rehearsal_marker' 2>&1)" \
  "sale before the update" "a row exists in the shop's database before the update"

rig_step "traffic on, then a restart-strategy update"
rig_load_start /api/ping
update_log="${RIG_RUN_DIR}/update-05.log"
started="$(date +%s)"
( cd "$RIG_SHOP" && bash update.sh "$(rig_bundle_path "$RESTART_ONLY")" ) >"$update_log" 2>&1
update_rc=$?
elapsed=$(( $(date +%s) - started ))
rig_wait_serving 90 >/dev/null
rig_load_stop
rig_log "update finished in ${elapsed}s (exit ${update_rc})"

rig_step "the release's own declaration was obeyed"
rig_assert_eq "0" "$update_rc" "update.sh reported success"
rig_assert_contains "$(cat "$update_log")" "with a full restart" "the engine chose the restart path"
rig_assert_not_contains "$(cat "$update_log")" "the shop keeps trading" \
  "it did NOT try to apply a release that said it could not be applied live"
rig_assert_not_contains "$(cat "$update_log")" "pointy-backend-standby" \
  "no standby was started — that is the live path, and this is not it"

rig_step "how long were the tills out?"
failed="$(rig_load_field failed)"
gap="$(rig_load_field max_gap_ms)"
total="$(rig_load_field total)"
rig_log "$(printf '%s requests, %s failed, longest outage %sms' "$total" "$failed" "$gap")"
rig_log "$(rig_load_breakdown)"
rig_log "PLAN WITH THIS NUMBER: a restart-strategy release costs the shop roughly ${gap}ms of tills-down"
# Downtime is expected; an unbounded one is not. A shop can absorb a few seconds
# between customers, not a minute.
rig_assert_le "${gap:-99999}" 60000 "the outage was bounded (<=60s)"
rig_assert_ge "${total:-0}" 100 "enough traffic went through to measure the outage"

rig_step "did the shop come back on the new release?"
rig_assert_eq "$RESTART_ONLY" "$(rig_served_version)" "the shop is serving the new release"
rig_assert_eq "$RESTART_ONLY" "$(rig_installed_version)" "VERSION.txt records the new release"
rig_assert_eq "backend" "$(rig_upstream)" "the front door is on the managed backend"

rig_step "did the state survive?"
# This is the whole risk of the restart path: `install.sh` runs `compose up -d`
# over the entire stack. If that ever recreated postgres, a shop would lose its
# trading history to a routine update.
rig_assert_eq "$postgres_before" "$(rig_container_id postgres)" "postgres was NOT recreated"
rig_assert_eq "$redis_before" "$(rig_container_id redis)" "redis was NOT recreated"
rig_assert_eq "$pgbouncer_before" "$(rig_container_id pgbouncer)" "pgbouncer was NOT recreated"
rig_assert_eq "$edge_before" "$(rig_container_id edge)" "the LAN front door was NOT recreated"
rig_assert_contains "$(rig_compose exec -T postgres psql -U pointy -d pointy -tAc 'SELECT note FROM rehearsal_marker' 2>&1)" \
  "sale before the update" "the row written before the update is still there"

rig_step "and a live update still works afterwards"
( cd "$RIG_SHOP" && bash update.sh "$(rig_bundle_path 1.1.0)" ) >"${RIG_RUN_DIR}/update-05-live.log" 2>&1
rig_assert_eq "0" "$?" "a normal live update applies after a restart-strategy one"
rig_assert_contains "$(cat "${RIG_RUN_DIR}/update-05-live.log")" "no downtime" \
  "and it took the live path this time"

rig_summary
