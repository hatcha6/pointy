#!/usr/bin/env bash
#
# What an update cost the shop, written down.
#
# Every apply leaves one JSON line in update-history.jsonl, and two readers work
# through that file with a cursor each: the backend's tracking module and the
# relay. What is pinned here:
#
#   * the record says what happened - outcome, strategy, versions, downtime -
#     for every way an apply can end, not only the happy one;
#   * a reader that fails keeps its place, so no run is ever skipped, and one
#     that succeeds never hands the same run over twice;
#   * recording can never be the reason an update fails.
. "$(dirname "$0")/harness.sh"

_mock_apply() {
  pu_bundle_strategy() { printf '%s' "${BUNDLE_STRATEGY:-live}"; }
  pu_edge_available()  { [ "${EDGE_UP:-1}" = 1 ]; }
  pu_backup_database() { return 0; }
  pu_adopt_bundle()    { return 0; }
  pu_apply_live()      { return "${LIVE_RC:-0}"; }
  pu_apply_restart()   { return "${RESTART_RC:-0}"; }
  pu_healthy()         { return "${HEALTH_RC:-0}"; }
  pu_register_autostart() { return 0; }
  pu_prune_superseded_images() { return 0; }
  pu_rollback_live()   { return "${ROLLBACK_RC:-0}"; }
  pu_compose()         { return 0; }
  # The hand-off to the backend goes through docker itself (so the host's
  # `timeout` can bound it): a docker that keeps what it was piped.
  stub_script docker <<'DOCKER_EOF'
case "$*" in
  *"exec -T backend python manage.py record_deployment_runs")
    printf 'track:%s\n' "$*" >>"${PU_TEST_DIR}/order.log"
    cat >>"${PU_TEST_DIR}/tracked.in"
    exit "${TRACK_RC:-0}" ;;
esac
exit 0
DOCKER_EOF
  POINTY_UPDATE_PROBE=0
}
_bundle() { mkdir -p "${PU_TEST_DIR}/b/images"; printf '%s' "${PU_TEST_DIR}/b"; }
_last() { tail -n 1 update-history.jsonl; }
_valid_json() { python3 -c 'import json,sys; [json.loads(l) for l in sys.stdin]'; }

test_a_live_update_is_recorded_as_one_line_of_json() {
  installed_deploy 1.0.0; _mock_apply
  assert_ok pu_apply_bundle "$(_bundle)" 1.0.0 1.1.0 auto >/dev/null 2>&1
  assert_eq '1' "$(wc -l <update-history.jsonl | tr -d ' ')"
  assert_ok _valid_json <update-history.jsonl
  local line; line="$(_last)"
  assert_contains "$line" '"kind":"update"'
  assert_contains "$line" '"from_version":"1.0.0"'
  assert_contains "$line" '"to_version":"1.1.0"'
  assert_contains "$line" '"strategy":"live"'
  assert_contains "$line" '"outcome":"succeeded"'
  assert_contains "$line" '"trigger":"manual"'
  assert_contains "$line" '"backup":'
}

test_the_agent_is_named_as_the_trigger() {
  installed_deploy 1.0.0; _mock_apply
  POINTY_LOG_TAG=pointy-update-agent
  pu_apply_bundle "$(_bundle)" 1.0.0 1.1.0 auto >/dev/null 2>&1
  assert_contains "$(_last)" '"trigger":"agent"'
}

test_a_restart_update_says_so() {
  installed_deploy 1.0.0; _mock_apply
  pu_apply_bundle "$(_bundle)" 1.0.0 1.1.0 restart >/dev/null 2>&1
  assert_contains "$(_last)" '"strategy":"restart"'
  assert_contains "$(_last)" '"outcome":"succeeded"'
  assert_contains "$(_last)" '"restart":'
}

test_an_update_that_never_moved_traffic_is_aborted_not_failed() {
  installed_deploy 1.0.0; _mock_apply
  LIVE_RC=1 pu_apply_bundle "$(_bundle)" 1.0.0 1.1.0 auto >/dev/null 2>&1
  assert_contains "$(_last)" '"outcome":"aborted"'
}

test_a_rollback_that_worked_is_recorded_as_a_rollback() {
  installed_deploy 1.0.0; _mock_apply
  LIVE_RC=2 ROLLBACK_RC=0 pu_apply_bundle "$(_bundle)" 1.0.0 1.1.0 auto >/dev/null 2>&1
  assert_contains "$(_last)" '"outcome":"rolled_back"'
}

test_a_rollback_that_did_not_work_is_a_failure() {
  installed_deploy 1.0.0; _mock_apply
  LIVE_RC=2 ROLLBACK_RC=1 pu_apply_bundle "$(_bundle)" 1.0.0 1.1.0 auto >/dev/null 2>&1
  assert_contains "$(_last)" '"outcome":"failed"'
}

test_a_failed_restart_that_came_back_is_a_rollback() {
  installed_deploy 1.0.0; _mock_apply
  local calls=0
  pu_healthy() { calls=$((calls + 1)); [ "$calls" -gt 1 ]; }
  pu_apply_bundle "$(_bundle)" 1.0.0 1.1.0 restart >/dev/null 2>&1
  assert_contains "$(_last)" '"outcome":"rolled_back"'
}

test_the_engines_reason_is_recorded_and_cannot_break_the_json() {
  installed_deploy 1.0.0; _mock_apply
  pu_apply_bundle_steps() { POINTY_APPLY_ERROR='it said "no" \ and
left'; return 1; }
  pu_apply_bundle "$(_bundle)" 1.0.0 1.1.0 auto >/dev/null 2>&1
  assert_ok _valid_json <update-history.jsonl
  assert_contains "$(_last)" 'it said \"no\" \\ and'
}

test_recording_never_changes_the_result_of_the_apply() {
  installed_deploy 1.0.0; _mock_apply
  POINTY_RUN_HISTORY=/nonexistent-dir/history.jsonl
  assert_status 0 pu_apply_bundle "$(_bundle)" 1.0.0 1.1.0 auto >/dev/null 2>&1
  LIVE_RC=1 assert_status 1 pu_apply_bundle "$(_bundle)" 1.0.0 1.1.0 auto >/dev/null 2>&1
}

test_install_sh_inside_an_update_is_told_not_to_record_again() {
  installed_deploy 1.0.0; _mock_apply
  pu_apply_restart() { printf '%s' "${POINTY_RUN_RECORDING:-}" >"${PU_TEST_DIR}/flag"; return 0; }
  pu_apply_bundle "$(_bundle)" 1.0.0 1.1.0 restart >/dev/null 2>&1
  assert_file_eq "${PU_TEST_DIR}/flag" '1'
  assert_eq '' "${POINTY_RUN_RECORDING:-}" 'and the flag does not outlive the apply'
}

# --- the downtime probe ------------------------------------------------------

test_the_probe_counts_the_seconds_a_till_was_refused() {
  installed_deploy 1.0.0
  POINTY_PROBE_FILE="$(mktemp)"; POINTY_PROBE_PID=""
  local now; now="$(date +%s)"
  # up, down for 3 s, up, down for 2 s, up until now
  printf '%s 1\n%s 0\n%s 0\n%s 0\n%s 1\n%s 0\n%s 0\n%s 1\n' \
    $((now-9)) $((now-8)) $((now-7)) $((now-6)) $((now-5)) $((now-4)) $((now-3)) $((now-2)) \
    >"$POINTY_PROBE_FILE"
  assert_eq '5 3 8' "$(pu_probe_stop)"
}

test_a_live_update_that_never_dropped_a_request_records_zero() {
  installed_deploy 1.0.0
  POINTY_PROBE_FILE="$(mktemp)"; POINTY_PROBE_PID=""
  local now; now="$(date +%s)"
  printf '%s 1\n%s 1\n' $((now-2)) $((now-1)) >"$POINTY_PROBE_FILE"
  assert_eq '0 0 2' "$(pu_probe_stop)"
}

test_the_probe_asks_what_a_till_asks_and_stops_with_the_apply() {
  installed_deploy 1.0.0; stub_cmd curl
  pu_probe_start
  local pid="$POINTY_PROBE_PID" file="$POINTY_PROBE_FILE"
  sleep 1.5
  local result; result="$(pu_probe_stop)"
  assert_called curl '*http://127.0.0.1:8000/readyz/*'
  assert_no_file "$file"
  assert_fail kill -0 "$pid"
  assert_contains "$result" '0 0 '
}

test_no_probe_means_no_downtime_claim() {
  installed_deploy 1.0.0; _mock_apply
  pu_apply_bundle "$(_bundle)" 1.0.0 1.1.0 auto >/dev/null 2>&1
  assert_contains "$(_last)" '"downtime_seconds":null'
}

# --- handing runs to the backend --------------------------------------------

test_a_run_is_handed_to_the_backends_tracking_module() {
  installed_deploy 1.0.0; _mock_apply
  pu_apply_bundle "$(_bundle)" 1.0.0 1.1.0 auto >/dev/null 2>&1
  assert_contains "$(cat "${PU_TEST_DIR}/order.log")" \
    'compose --env-file .env -f docker-compose.yml exec -T backend python manage.py record_deployment_runs'
  assert_eq "$(cat update-history.jsonl)" "$(cat "${PU_TEST_DIR}/tracked.in")"
  assert_file_eq .update-history.tracked '1'
}

test_a_backend_that_cannot_take_it_is_offered_it_again_with_the_next_run() {
  installed_deploy 1.0.0; _mock_apply
  TRACK_RC=1 pu_apply_bundle "$(_bundle)" 1.0.0 1.1.0 auto >/dev/null 2>&1
  assert_no_file .update-history.tracked
  : >"${PU_TEST_DIR}/tracked.in"
  pu_apply_bundle "$(_bundle)" 1.1.0 1.2.0 auto >/dev/null 2>&1
  assert_eq '2' "$(wc -l <"${PU_TEST_DIR}/tracked.in" | tr -d ' ')"
  assert_file_eq .update-history.tracked '2'
}

test_a_run_already_handed_over_is_not_handed_over_twice() {
  installed_deploy 1.0.0; _mock_apply
  pu_apply_bundle "$(_bundle)" 1.0.0 1.1.0 auto >/dev/null 2>&1
  : >"${PU_TEST_DIR}/tracked.in"
  pu_track_runs
  assert_eq '' "$(cat "${PU_TEST_DIR}/tracked.in")"
}

test_a_history_that_was_replaced_starts_the_cursor_over() {
  installed_deploy 1.0.0
  printf '{"id":"a"}\n' >update-history.jsonl
  echo 7 >.update-history.tracked
  assert_eq '{"id":"a"}' "$(pu_pending_runs .update-history.tracked)"
}

test_pending_runs_come_in_bounded_batches() {
  installed_deploy 1.0.0
  for i in 1 2 3 4 5; do printf '{"id":"%s"}\n' "$i" >>update-history.jsonl; done
  echo 1 >.update-history.tracked
  assert_eq '{"id":"2"}
{"id":"3"}' "$(pu_pending_runs .update-history.tracked 2)"
  pu_advance_cursor .update-history.tracked 2
  assert_file_eq .update-history.tracked '3'
}

pu_run_tests "$@"
