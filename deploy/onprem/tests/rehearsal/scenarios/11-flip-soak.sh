#!/usr/bin/env bash
#
# Many live updates in a row, under till traffic, counting every failed request.
#
# One live update proves the flip CAN be clean; it cannot prove it always is. On
# 2026-09-30 scenario 10 saw 12 HTTP 502s in one flip-back out of roughly eight
# clean ones — two bursts of six, one per till connection, labelled as the
# standby. A race that shows up one update in eight passes every single-update
# scenario most of the time, and on a fleet it is a dropped checkout somewhere
# every week. So this flips the same shop back and forth SOAK_ROUNDS times and
# demands zero failures across all of them.
#
# Each round's load events (wall-clock time, upstream, connection reuse) and the
# engine's log with sub-second timestamps are kept in the run directory, so a
# failure can be lined up against the step that caused it.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. ./lib.sh
RIG_SCENARIO="11-flip-soak"
rig_setup >/dev/null || exit 1
trap 'rig_teardown_shop' EXIT

rounds="${SOAK_ROUNDS:-12}"

rig_step "installing a shop on 1.0.0"
rig_install_shop 1.0.0 || { rig_summary; exit 1; }

# Prefix every engine line with wall-clock milliseconds.
stamp() { python3 -u -c '
import sys, time
for line in sys.stdin:
    sys.stdout.write("%d %s" % (time.time() * 1000, line))'; }

total_failed=0
failed_rounds=""
for round in $(seq 1 "$rounds"); do
  if [ $((round % 2)) = 1 ]; then target=1.1.0; else target=1.2.0; fi
  rig_step "round ${round}/${rounds}: live update to ${target}"
  update_log="${RIG_RUN_DIR}/update-11-${round}.log"
  rig_load_start /api/ping
  ( cd "$RIG_SHOP" && bash update.sh "$(rig_bundle_path "$target")" ) 2>&1 | stamp >"$update_log"
  update_rc="${PIPESTATUS[0]}"
  # Let old nginx workers and the removed standby's last responses land.
  sleep 1
  rig_load_stop
  failed="$(rig_load_field failed)"
  rig_log "$(printf '%s requests, %s failed, largest gap %sms' \
    "$(rig_load_field total)" "$failed" "$(rig_load_field max_gap_ms)")"
  rig_assert_eq "0" "$update_rc" "round ${round}: update.sh succeeded"
  rig_assert_eq "$target" "$(rig_served_version)" "round ${round}: the shop serves ${target}"
  if [ "${failed:-0}" != 0 ]; then
    total_failed=$((total_failed + failed))
    failed_rounds="${failed_rounds} ${round}"
    rig_log "round ${round} failures (events: ${RIG_LOAD_OUT%.json}.events.jsonl, engine: ${update_log}):"
    grep '"failure"' "${RIG_LOAD_OUT%.json}.events.jsonl" | head -6 | sed 's/^/      /'
  fi
done

rig_step "across ${rounds} live updates"
rig_assert_eq "0" "$total_failed" \
  "not one till request failed in any of them${failed_rounds:+ (failed rounds:${failed_rounds})}"

rig_summary
