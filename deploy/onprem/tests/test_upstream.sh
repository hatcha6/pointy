#!/usr/bin/env bash
#
# The flip: pointing the LAN front door at a backend and PROVING it took effect.
# This is the single most dangerous function in the engine — a mistake here is
# the difference between a shop that keeps trading and one whose tills all stop
# at once — so it gets the most tests.
. "$(dirname "$0")/harness.sh"

COMPOSE='compose --env-file .env -f docker-compose.yml'
UPSTREAM='edge/active/upstream.conf'

# The front door confirms the flip through a response header; make it agree.
_edge_reports() { stub_rule curl '-fsS -I *' 0 "$(curl_header_response "$1")"; }

_use_private_tmp() { export TMPDIR="${PU_TEST_DIR}/tmp"; mkdir -p "$TMPDIR"; }

# ---------------------------------------------------------------------------
# The happy path
# ---------------------------------------------------------------------------

test_set_upstream_writes_both_nginx_variables() {
  default_env
  _edge_reports backend
  assert_ok pu_set_upstream backend
  assert_file_contains "$UPSTREAM" 'set $pointy_upstream      "http://backend:8000";'
  assert_file_contains "$UPSTREAM" 'set $pointy_upstream_name "backend";'
}

test_set_upstream_creates_the_directory_on_a_deployment_that_lacks_it() {
  default_env
  rm -rf edge
  _edge_reports pointy-backend-standby
  assert_ok pu_set_upstream pointy-backend-standby
  assert_file "$UPSTREAM"
}

test_set_upstream_validates_before_it_reloads() {
  default_env
  _edge_reports backend
  pu_set_upstream backend
  assert_called docker "$COMPOSE exec -T edge nginx -t"
  assert_called docker "$COMPOSE exec -T edge nginx -s reload"
  # `nginx -t` must come first: reloading an invalid config is how you find out
  # the hard way that nginx keeps serving the OLD one.
  local calls; calls="$(calls_of docker)"
  local t_line r_line
  t_line="$(printf '%s\n' "$calls" | grep -n 'nginx -t' | head -1 | cut -d: -f1)"
  r_line="$(printf '%s\n' "$calls" | grep -n 'nginx -s reload' | head -1 | cut -d: -f1)"
  [ "$t_line" -lt "$r_line" ] || _fail "nginx -s reload was issued before nginx -t"
}

test_set_upstream_reports_the_target_it_moved_traffic_to() {
  default_env
  _edge_reports pointy-backend-standby
  local out; out="$(pu_set_upstream pointy-backend-standby 2>&1)"
  assert_contains "$out" 'traffic now served by pointy-backend-standby'
}

test_set_upstream_probes_the_configured_port() {
  write_env 'POINTY_BACKEND_PORT=18000'
  stub_rule curl '-fsS -I http://127.0.0.1:18000/healthz-edge' 0 "$(curl_header_response backend)"
  assert_ok pu_set_upstream backend
}

# ---------------------------------------------------------------------------
# A config nginx rejects must never survive on disk
# ---------------------------------------------------------------------------

test_rejected_config_restores_the_previous_pointer_byte_for_byte() {
  # The front door re-reads this file whenever it restarts. Leaving a rejected
  # one behind turns a failed flip into an nginx that cannot start at all —
  # i.e. a shop with no front door after the next reboot.
  default_env
  mkdir -p edge/active
  printf 'set $pointy_upstream      "http://backend:8000";\nset $pointy_upstream_name "backend";\n' >"$UPSTREAM"
  local before; before="$(cat "$UPSTREAM")"
  stub_rule docker "$COMPOSE exec -T edge nginx -t" 1 'nginx: [emerg] unknown directive'
  assert_fail pu_set_upstream pointy-backend-standby
  assert_file_eq "$UPSTREAM" "$before"
}

test_rejected_config_removes_the_file_when_there_was_no_previous_one() {
  # A first-ever flip on a deployment with no pointer yet: there is nothing to
  # restore, so the half-written file must go rather than be left behind.
  default_env
  rm -rf edge
  stub_rule docker "$COMPOSE exec -T edge nginx -t" 1 'nginx: [emerg] bad'
  assert_fail pu_set_upstream pointy-backend-standby
  assert_no_file "$UPSTREAM"
}

test_rejected_config_is_never_reloaded() {
  default_env
  stub_rule docker "$COMPOSE exec -T edge nginx -t" 1 'nginx: [emerg] bad'
  pu_set_upstream backend
  assert_not_called docker '*nginx -s reload*'
}

test_rejected_config_surfaces_the_nginx_error_to_the_operator() {
  default_env
  stub_rule docker "$COMPOSE exec -T edge nginx -t" 1 'nginx: [emerg] host not found in upstream'
  local out; out="$(pu_set_upstream ghost 2>&1)"
  assert_contains "$out" 'front-door config rejected by nginx -t'
  assert_contains "$out" 'leaving traffic where it is'
  assert_contains "$out" 'host not found in upstream'
}

test_rejected_config_leaves_no_temporary_files_behind() {
  _use_private_tmp
  default_env
  mkdir -p edge/active
  printf 'previous\n' >"$UPSTREAM"
  stub_rule docker "$COMPOSE exec -T edge nginx -t" 1 'bad'
  pu_set_upstream backend
  assert_eq '' "$(ls -A "$TMPDIR")"
}

test_successful_flip_leaves_no_temporary_files_behind() {
  _use_private_tmp
  default_env
  mkdir -p edge/active
  printf 'previous\n' >"$UPSTREAM"
  _edge_reports backend
  assert_ok pu_set_upstream backend
  assert_eq '' "$(ls -A "$TMPDIR")"
}

# ---------------------------------------------------------------------------
# "The command returned 0" is not evidence — the response header is
# ---------------------------------------------------------------------------

test_flip_fails_when_the_front_door_never_reports_the_new_target() {
  # nginx keeps serving its previous config if a reload silently fails, so a
  # zero exit status from `nginx -s reload` proves nothing.
  default_env
  stub_rule curl '-fsS -I *' 0 "$(curl_header_response backend)"
  local out; out="$(pu_set_upstream pointy-backend-standby 2>&1)"
  assert_contains "$out" 'front door did not report pointy-backend-standby'
  assert_status 1 pu_set_upstream pointy-backend-standby
}

test_flip_retries_the_header_check_ten_times_before_giving_up() {
  default_env
  stub_rule curl '-fsS -I *' 0 'HTTP/1.1 200 OK'
  pu_set_upstream backend
  assert_call_count curl '-fsS -I http://127.0.0.1:8000/healthz-edge' 10
}

test_flip_succeeds_once_the_header_catches_up() {
  # nginx finishes the reload asynchronously; the first probes legitimately
  # still show the old upstream.
  default_env
  stub_script curl <<'EOF'
case "$*" in
  *-I*)
    n_file="${PU_TEST_DIR}/probe-count"
    n=$(( $(cat "$n_file" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$n" >"$n_file"
    if [ "$n" -ge 4 ]; then
      printf 'HTTP/1.1 200 OK\r\nX-Pointy-Upstream: pointy-backend-standby\r\n'
    else
      printf 'HTTP/1.1 200 OK\r\nX-Pointy-Upstream: backend\r\n'
    fi
    ;;
esac
exit 0
EOF
  assert_ok pu_set_upstream pointy-backend-standby
  assert_eq '4' "$(cat "${PU_TEST_DIR}/probe-count")"
}

test_header_match_is_anchored_so_a_name_prefix_cannot_pass_for_the_target() {
  # THE NASTY ONE. "backend" is a prefix of "pointy-backend-standby". An
  # unanchored match would let a flip BACK to `backend` report success while the
  # front door is still pointed at the standby — a one-off container with no
  # restart policy, which then dies at the next reboot and takes the shop with
  # it. The anchors in the grep are load-bearing.
  default_env
  stub_rule curl '-fsS -I *' 0 "$(curl_header_response pointy-backend-standby)"
  assert_status 1 pu_set_upstream backend
}

test_header_match_is_anchored_at_the_end_too() {
  default_env
  stub_rule curl '-fsS -I *' 0 "$(curl_header_response backend-canary)"
  assert_status 1 pu_set_upstream backend
}

test_header_match_tolerates_crlf_line_endings() {
  # Real HTTP headers end in CRLF; without `tr -d '\r'` the anchored match can
  # never succeed and every flip would report failure.
  default_env
  stub_rule curl '-fsS -I *' 0 'HTTP/1.1 200 OK\r\nX-Pointy-Upstream: backend\r\nServer: nginx\r\n'
  assert_ok pu_set_upstream backend
}

test_header_match_is_case_insensitive_in_the_field_name() {
  # HTTP field names are case-insensitive and proxies do normalise them.
  default_env
  stub_rule curl '-fsS -I *' 0 'HTTP/1.1 200 OK\r\nx-pointy-upstream: backend\r\n'
  assert_ok pu_set_upstream backend
}

test_flip_fails_when_the_front_door_does_not_answer_at_all() {
  default_env
  stub_rule curl '-fsS -I *' 7
  assert_status 1 pu_set_upstream backend
}

# ---------------------------------------------------------------------------
# pu_write_default_upstream
# ---------------------------------------------------------------------------

test_default_upstream_points_at_the_managed_backend() {
  pu_write_default_upstream
  assert_file_contains "$UPSTREAM" 'set $pointy_upstream      "http://backend:8000";'
  assert_file_contains "$UPSTREAM" 'set $pointy_upstream_name "backend";'
}

test_default_upstream_never_points_at_the_standby() {
  # The standby is a one-off container with no restart policy. A default that
  # named it would not survive a reboot.
  pu_write_default_upstream
  assert_file_lacks "$UPSTREAM" 'standby'
}

test_default_upstream_creates_its_directory() {
  rm -rf edge
  pu_write_default_upstream
  assert_file "$UPSTREAM"
}

test_generated_pointer_is_readable_by_the_watchdog() {
  # watchdog.sh recovers a half-finished update by parsing the name back out of
  # this file with its own sed. If the two ever disagree on the format, the
  # watchdog stops being able to repoint the front door at all.
  default_env
  _edge_reports pointy-backend-standby
  pu_set_upstream pointy-backend-standby
  local parsed
  parsed="$(sed -n 's/^set \$pointy_upstream_name *"\([^"]*\)".*/\1/p' "$UPSTREAM" | head -1)"
  assert_eq 'pointy-backend-standby' "$parsed"
}

test_default_pointer_is_readable_by_the_watchdog() {
  pu_write_default_upstream
  local parsed
  parsed="$(sed -n 's/^set \$pointy_upstream_name *"\([^"]*\)".*/\1/p' "$UPSTREAM" | head -1)"
  assert_eq 'backend' "$parsed"
}

pu_run_tests "$@"
