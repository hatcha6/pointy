#!/usr/bin/env bash
#
# The hardest failure: the new release comes up, passes its readiness gate, takes
# traffic — and only then does something go wrong.
#
# This is the one path where a rollback is genuinely dangerous, because traffic
# has already moved and both the old and the new release have now touched the
# database. The engine's contract says it must bring the previous release back
# and hand the front door to it, WITHOUT the shop going dark in between. That is
# what this measures.
#
# The release used here fails on its third backend start: the install is the
# first, the standby is the second, and the third is the managed backend being
# rebuilt on the new version — which happens after the flip. Nothing about the
# container can distinguish the standby from the rebuild, so the order is the
# only handle there is.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. ./lib.sh
RIG_SCENARIO="04-fails-after-switchover"
rig_setup >/dev/null || exit 1
trap 'rig_teardown_shop' EXIT

BROKEN=2.4.0-fails-after-flip

rig_step "installing a shop on 1.0.0"
rig_install_shop 1.0.0 || { rig_summary; exit 1; }
env_before="$(cat "${RIG_SHOP}/.env")"
edge_before="$(rig_container_id edge)"

rig_step "traffic on, then an update that fails only after traffic has moved"
rig_load_start /api/ping
update_log="${RIG_RUN_DIR}/update-04.log"
started="$(date +%s)"
# PRODUCTION NOTE, deliberately bounded here. The post-switchover waits default
# to 120 x 10s — twenty minutes — during which the shop is served by the STANDBY,
# a one-off container with no restart policy that a reboot would take away, while
# the update lock stays held and the relay still shows "applying". Worst case is
# two of those back to back. Bounded to a minute so the scenario can finish; the
# number an operator would actually live with is in the note above.
( cd "$RIG_SHOP" \
    && POINTY_STANDBY_READY_TRIES=6 POINTY_REBUILD_READY_TRIES=6 POINTY_RESTORE_READY_TRIES=12 \
       bash update.sh "$(rig_bundle_path "$BROKEN")" ) >"$update_log" 2>&1
update_rc=$?
elapsed=$(( $(date +%s) - started ))
rig_load_stop
rig_log "update finished after ${elapsed}s (exit ${update_rc})"

rig_step "the failure was detected after the switchover"
rig_assert_ne "0" "$update_rc" "update.sh reported failure"
rig_assert_contains "$(cat "$update_log")" "traffic now served by pointy-backend-standby" \
  "traffic really did move to the new release first"
rig_assert_contains "$(cat "$update_log")" "rolling back" "the engine rolled back rather than leaving it"

rig_step "did the shop stay open through the rollback?"
total="$(rig_load_field total)"; failed="$(rig_load_field failed)"
streak="$(rig_load_field longest_failure_streak)"; gap="$(rig_load_field max_gap_ms)"
rig_log "$(printf '%s requests, %s failed, longest failure streak %s, largest gap %sms' \
  "$total" "$failed" "$streak" "$gap")"
rig_log "$(rig_load_breakdown)"
rig_log "hand-over: $(rig_load_transitions)"
rig_assert_ge "${total:-0}" 200 "enough traffic went through to mean anything"
# This is the claim the design makes about its worst path: "every failure path
# ends with the shop serving". A rollback that costs the shop a minute of
# downtime is a rollback that happened during trading hours and was noticed.
rig_assert_eq "0" "${failed:-1}" "the shop served every request even while rolling back"
rig_assert_le "${gap:-99999}" 3000 "no gap a cashier could see, even during the rollback"
rig_assert_shop_never_went_down "while rolling back after the switchover"

rig_step "where did the shop end up?"
rig_assert_eq "1.0.0" "$(rig_served_version)" "the shop is back on 1.0.0"
rig_assert_eq "backend" "$(rig_upstream)" "the front door is back on the managed backend"
rig_assert_eq "1.0.0" "$(rig_installed_version)" "VERSION.txt says 1.0.0, not the release that failed"
rig_assert_eq "$env_before" "$(cat "${RIG_SHOP}/.env")" ".env was restored byte-for-byte"
rig_assert_eq "" "$(docker ps -aq -f name=pointy-backend-standby 2>/dev/null)" "the standby was removed"
rig_assert_eq "$edge_before" "$(rig_container_id edge)" "the front door was never recreated"

# The recreated backend must be a real, supervised container — not the one-off
# standby left running with no restart policy, which would look fine all
# afternoon and be gone after a reboot.
backend_id="$(rig_container_id backend)"
rig_assert_eq "true" "$(docker inspect -f '{{.State.Running}}' "$backend_id" 2>/dev/null)" \
  "the managed backend is running again"
rig_assert_contains "$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$backend_id" 2>/dev/null)" \
  "always" "the backend the shop is left on has a restart policy — it will survive a reboot"
rig_assert_eq "pointy-backend:1.0.0" "$(docker inspect -f '{{.Config.Image}}' "$backend_id" 2>/dev/null)" \
  "the restored backend is on the OLD image, not the failed one"

rig_step "and it can still be updated afterwards"
( cd "$RIG_SHOP" && bash update.sh "$(rig_bundle_path 1.1.0)" ) >"${RIG_RUN_DIR}/update-04-recover.log" 2>&1
rig_assert_eq "0" "$?" "a good release applies cleanly after a post-switchover rollback"
rig_assert_eq "1.1.0" "$(rig_served_version)" "the shop recovered onto 1.1.0"

rig_summary
