#!/usr/bin/env bash
#
# Two things must never run underneath an update: another update, and the
# watchdog.
#
# The watchdog reconciles the stack every few minutes with `compose up`. If it
# did that mid-flip it would fight the updater for the backend container. And two
# updates at once would each start a standby, each load images, each rewrite
# .env. One lock file prevents both — which makes that file, and everyone's
# respect for it, load-bearing.
#
# This matters most on a fleet. Every shop runs update-agent.sh on a timer, so a
# slow download on a slow link means the NEXT tick fires while the previous one
# is still working. That is the normal case, not the exotic one.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. ./lib.sh
RIG_SCENARIO="06-update-lock-and-watchdog"
rig_setup >/dev/null || exit 1
trap 'rig_teardown_shop' EXIT

SLOW=2.3.0-slow-boot

rig_step "installing a shop on 1.0.0"
rig_install_shop 1.0.0 || { rig_summary; exit 1; }
backend_before="$(rig_container_id backend)"

rig_step "starting a slow update in the background"
rig_load_start /api/ping
update_log="${RIG_RUN_DIR}/update-06.log"
( cd "$RIG_SHOP" && bash update.sh "$(rig_bundle_path "$SLOW")" ) >"$update_log" 2>&1 &
updater_pid=$!

# Wait until it actually owns the lock, rather than guessing with a sleep.
for _ in $(seq 1 60); do
  [ -f "${RIG_SHOP}/.update.lock" ] && break
  sleep 0.5
done
rig_assert_file "${RIG_SHOP}/.update.lock" "the updater took the lock"
lock_holder="$(cat "${RIG_SHOP}/.update.lock" 2>/dev/null)"

rig_step "a second update arrives while the first is working"
second_log="${RIG_RUN_DIR}/update-06-second.log"
( cd "$RIG_SHOP" && bash update.sh "$(rig_bundle_path 1.1.0)" ) >"$second_log" 2>&1
second_rc=$?
rig_assert_ne "0" "$second_rc" "the second update refused to run"
rig_assert_contains "$(cat "$second_log")" "another update is already running" \
  "and said why, naming the holder"
rig_assert_not_contains "$(cat "$second_log")" "loading" "it did not load a single image"
rig_assert_eq "$lock_holder" "$(cat "${RIG_SHOP}/.update.lock" 2>/dev/null)" \
  "standing down did NOT take the first update's lock away"

rig_step "the update agent arrives while the first is working"
# The agent runs on a timer, so this is the everyday collision, not a rare one.
# It must stand down quietly (exit 0 — nothing is wrong) and leave the lock alone.
agent_log="${RIG_RUN_DIR}/agent-06.log"
( cd "$RIG_SHOP" && bash update-agent.sh ) >"$agent_log" 2>&1
agent_rc=$?
rig_assert_eq "0" "$agent_rc" "the agent exited 0 — a busy shop is not a failed shop"
rig_assert_eq "$lock_holder" "$(cat "${RIG_SHOP}/.update.lock" 2>/dev/null)" \
  "the agent did not take the running update's lock away either"

rig_step "the watchdog fires while the first is working"
watchdog_log="${RIG_RUN_DIR}/watchdog-06.log"
( cd "$RIG_SHOP" && bash watchdog.sh ) >"$watchdog_log" 2>&1
rig_assert_contains "$(cat "$watchdog_log")" "an update is in progress; standing down" \
  "the watchdog saw the lock and stood down"
rig_assert_not_contains "$(cat "$watchdog_log")" "restarting" "it restarted nothing"
rig_assert_eq "$lock_holder" "$(cat "${RIG_SHOP}/.update.lock" 2>/dev/null)" \
  "the watchdog did not take the lock away either"

rig_step "letting the first update finish"
wait "$updater_pid"
first_rc=$?
rig_load_stop
rig_assert_eq "0" "$first_rc" "the first update completed despite the interference"
rig_assert_eq "$SLOW" "$(rig_served_version)" "the shop is serving the release the first update was applying"
rig_assert_eq "$SLOW" "$(rig_installed_version)" "VERSION.txt records it"
rig_assert_no_file "${RIG_SHOP}/.update.lock" "the lock was released at the end"
rig_assert_ne "$backend_before" "$(rig_container_id backend)" "the backend was genuinely replaced"

rig_step "did the shop notice any of it?"
rig_log "$(printf '%s requests, %s failed, largest gap %sms' \
  "$(rig_load_field total)" "$(rig_load_field failed)" "$(rig_load_field max_gap_ms)")"
rig_log "$(rig_load_breakdown)"
# OBSERVED, and worth being precise about rather than asserting away. With two
# updates, an agent and the watchdog all arriving at once, this scenario has been
# seen to produce a handful of isolated 502s — 16 in 15,709 requests on one run,
# 0 in 15,808 on the next. They are never consecutive and never widen the gap
# between good responses beyond a few tens of milliseconds, so the shop is up
# throughout; a till would retry one request and never know. See README.md for
# what they are (nginx workers that predate the reload, still routing to the old
# backend once compose has told it to stop accepting connections).
#
# So assert the thing that actually matters — the shop never went down — and hold
# the isolated failures under a ceiling rather than pretending they are always
# zero. A rig that flakes gets ignored; a rig that hides a real behaviour is
# worse.
rig_assert_shop_never_went_down "with two updates, an agent and the watchdog all at once"

rig_step "and the lock does not outlive its holder"
( cd "$RIG_SHOP" && bash update.sh "$(rig_bundle_path 1.1.0)" ) >"${RIG_RUN_DIR}/update-06-after.log" 2>&1
rig_assert_eq "0" "$?" "the next update runs normally once the lock is gone"

rig_summary
