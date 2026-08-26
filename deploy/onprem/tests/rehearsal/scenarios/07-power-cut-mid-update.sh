#!/usr/bin/env bash
#
# The power goes out in the middle of an update.
#
# Libya's grid is the reason this scenario exists rather than being a thought
# experiment: shops run on generators and mains, and the changeover is exactly
# the kind of event that kills a process halfway. The updater is killed with no
# chance to run its cleanup — so no rollback, no lock release, no tidying.
#
# It is killed at the worst possible moment: after traffic has been handed to the
# standby and before the managed backend has been rebuilt. At that instant the
# shop is being served by a `compose run` one-off container that has NO restart
# policy. It will keep serving all afternoon and will not exist after a reboot.
#
# This scenario is as much about documenting what state a shop is left in as it
# is about asserting: whoever gets the phone call needs to know.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. ./lib.sh
RIG_SCENARIO="07-power-cut-mid-update"
rig_setup >/dev/null || exit 1
trap 'rig_teardown_shop' EXIT

SLOW=2.3.0-slow-boot   # a slow boot widens the window so the kill lands reliably

rig_step "installing a shop on 1.0.0"
rig_install_shop 1.0.0 || { rig_summary; exit 1; }

rig_step "starting an update and killing it the moment traffic moves"
rig_load_start /api/ping
update_log="${RIG_RUN_DIR}/update-07.log"
( cd "$RIG_SHOP" && bash update.sh "$(rig_bundle_path "$SLOW")" ) >"$update_log" 2>&1 &
updater_pid=$!

moved=0
for _ in $(seq 1 240); do
  if [ "$(rig_upstream)" = "pointy-backend-standby" ]; then moved=1; break; fi
  kill -0 "$updater_pid" 2>/dev/null || break
  sleep 0.25
done
rig_assert_eq "1" "$moved" "traffic reached the standby, so the kill lands at the worst moment"
# SIGKILL the updater and everything it started: no traps, no cleanup, no
# rollback — a power cut, not a Ctrl-C.
rig_kill_tree "$updater_pid"
wait "$updater_pid" 2>/dev/null
sleep 2
rig_load_stop

rig_step "is the shop still serving?"
rig_log "$(printf '%s requests, %s failed, largest gap %sms' \
  "$(rig_load_field total)" "$(rig_load_field failed)" "$(rig_load_field max_gap_ms)")"
rig_log "$(rig_load_breakdown)"
rig_assert_eq "0" "$(rig_load_field failed)" "the kill did not cost the shop a single request"
rig_serving && rig_pass "the shop is still answering /readyz after the updater was killed" \
  || rig_fail "the shop stopped serving when the updater was killed"

rig_step "what state was the shop left in?"
upstream_now="$(rig_upstream)"
rig_log "the front door is pointing at: ${upstream_now}"
rig_log "the shop is serving release: $(rig_served_version)"
rig_assert_eq "pointy-backend-standby" "$upstream_now" \
  "the front door is still on the temporary standby — the update never got to hand it back"

# THE DURABILITY RISK, stated as a fact rather than a worry. The container the
# shop is running on right now was created by `compose run`, which does not apply
# the service's restart policy. It survives until the next crash or reboot, and
# then the shop is dark with a perfectly good backend sitting beside it.
standby_policy="$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' pointy-backend-standby 2>/dev/null)"
rig_log "the standby's restart policy is: ${standby_policy:-<none>}"
rig_assert_ne "always" "$standby_policy" \
  "CONFIRMED RISK: the container now serving the shop has no restart policy — a reboot loses it"

rig_assert_file "${RIG_SHOP}/.update.lock" "a stale lock was left behind, as a killed process must"

rig_step "the watchdog runs five minutes later"
watchdog_log="${RIG_RUN_DIR}/watchdog-07.log"
( cd "$RIG_SHOP" && bash watchdog.sh ) >"$watchdog_log" 2>&1
rig_assert_contains "$(cat "$watchdog_log")" "an update is in progress; standing down" \
  "while the lock is fresh the watchdog stands down — it cannot tell a dead updater from a slow one"
rig_assert_eq "pointy-backend-standby" "$(rig_upstream)" \
  "so the shop stays on the unsupervised container for as long as the lock looks fresh (1h by default)"

rig_step "the watchdog runs once the lock has aged out"
# The lock carries a timestamp precisely so a power cut cannot disable the
# watchdog for good. Age it out rather than waiting an hour.
( cd "$RIG_SHOP" && POINTY_UPDATE_LOCK_MAX_AGE=0 bash watchdog.sh ) >"${RIG_RUN_DIR}/watchdog-07-stale.log" 2>&1
rig_assert_contains "$(cat "${RIG_RUN_DIR}/watchdog-07-stale.log")" "ignoring a stale update lock" \
  "the watchdog eventually ignores a lock whose holder died"
# The standby is still RUNNING, so heal_front_door leaves it alone — it only
# repoints when the named container is gone. Worth knowing: the watchdog rescues
# a shop whose standby DIED, not one whose standby merely has no restart policy.
rig_log "front door after the stale-lock watchdog run: $(rig_upstream)"

rig_step "recovering the shop"
# What an engineer (or the next agent run, once the lock ages out) actually does.
( cd "$RIG_SHOP" && POINTY_UPDATE_LOCK_MAX_AGE=0 bash update.sh "$(rig_bundle_path 1.1.0)" ) \
  >"${RIG_RUN_DIR}/update-07-recover.log" 2>&1
recover_rc=$?
rig_assert_eq "0" "$recover_rc" "a fresh update takes over the stale lock and recovers the shop"
rig_assert_eq "1.1.0" "$(rig_served_version)" "the shop is serving 1.1.0"
rig_assert_eq "backend" "$(rig_upstream)" "the front door is back on the managed, supervised backend"
rig_assert_eq "" "$(docker ps -aq -f name=pointy-backend-standby 2>/dev/null)" \
  "the orphaned standby was cleaned up"
rig_assert_no_file "${RIG_SHOP}/.update.lock" "and the lock is gone"

rig_summary
