#!/usr/bin/env bash
#
# Health probing and container identity — the checks every "is it safe to move
# traffic?" decision rests on.
. "$(dirname "$0")/harness.sh"

COMPOSE='compose --env-file .env -f docker-compose.yml'

# ---------------------------------------------------------------------------
# pu_healthy — the LAN front door answering /readyz, i.e. what a till sees.
# ---------------------------------------------------------------------------

test_healthy_succeeds_on_the_first_probe() {
  default_env
  assert_ok pu_healthy 3
  assert_called curl '-fsS http://127.0.0.1:8000/readyz/'
  assert_call_count curl '-fsS http://127.0.0.1:8000/readyz/' 1
}

test_healthy_probes_the_configured_port_not_8000() {
  write_env 'POINTY_BACKEND_PORT=18080'
  assert_ok pu_healthy 1
  assert_called curl '-fsS http://127.0.0.1:18080/readyz/'
}

test_healthy_gives_up_after_the_requested_number_of_tries() {
  default_env
  stub_rule curl '*' 1
  assert_fail pu_healthy 4
  assert_call_count curl '-fsS http://127.0.0.1:8000/readyz/' 4
}

test_healthy_retries_until_the_backend_comes_up() {
  default_env
  # Two failures then success: a backend that is still running migrations.
  stub_script curl <<'EOF'
n_file="${PU_TEST_DIR}/curl-attempts"
n=$(( $(cat "$n_file" 2>/dev/null || echo 0) + 1 ))
printf '%s' "$n" >"$n_file"
[ "$n" -ge 3 ] && exit 0
exit 1
EOF
  assert_ok pu_healthy 10
  assert_eq '3' "$(cat "${PU_TEST_DIR}/curl-attempts")"
}

test_healthy_with_a_zero_budget_is_platform_dependent() {
  # DOCUMENTED PORTABILITY DIVERGENCE. The retry loop is `for _ in $(seq 1
  # "$tries")`. Under GNU coreutils `seq 1 0` prints nothing, so a zero budget
  # probes zero times; under BSD/macOS seq it counts DOWN and prints "1 0", so
  # the same call probes twice and can return success. Not reachable today —
  # every caller passes 24 or the default 60 — but it is a loop bound built out
  # of `seq`, and the day someone passes a computed budget the two platforms
  # will disagree. Pinned here so that day is loud.
  default_env
  if [ -z "$(seq 1 0 2>/dev/null)" ]; then
    assert_fail pu_healthy 0
    assert_eq '0' "$(count_calls curl)"
  else
    assert_ok pu_healthy 0
    assert_eq '1' "$(count_calls curl)"
  fi
}

# ---------------------------------------------------------------------------
# pu_container_id — compose service name -> real container, for inspect/logs.
# ---------------------------------------------------------------------------

test_container_id_resolves_a_compose_service() {
  stub_rule docker "$COMPOSE ps -aq backend" 0 'abc123def456'
  assert_eq 'abc123def456' "$(pu_container_id backend)"
}

test_container_id_takes_the_first_of_several_containers() {
  # A service scaled to two replicas, or a leftover from a crashed update.
  stub_rule docker "$COMPOSE ps -aq backend" 0 'first111\nsecond222'
  assert_eq 'first111' "$(pu_container_id backend)"
}

test_container_id_falls_back_to_the_name_it_was_given() {
  # The standby is a one-off container, not a compose service, so `ps -aq`
  # knows nothing about it and its own name IS the identifier.
  stub_rule docker "$COMPOSE ps -aq pointy-backend-standby" 0 ''
  assert_eq 'pointy-backend-standby' "$(pu_container_id pointy-backend-standby)"
}

test_container_id_falls_back_when_compose_itself_fails() {
  stub_rule docker '*' 1
  assert_eq 'backend' "$(pu_container_id backend)"
}

# ---------------------------------------------------------------------------
# pu_container_running
# ---------------------------------------------------------------------------

test_container_running_is_true_for_a_running_container() {
  stub_rule docker "$COMPOSE ps -aq backend" 0 'cid1'
  stub_rule docker 'inspect -f * cid1' 0 'true'
  assert_ok pu_container_running backend
}

test_container_running_is_false_for_a_stopped_container() {
  stub_rule docker "$COMPOSE ps -aq backend" 0 'cid1'
  stub_rule docker 'inspect -f * cid1' 0 'false'
  assert_fail pu_container_running backend
}

test_container_running_is_false_when_the_container_does_not_exist() {
  stub_rule docker "$COMPOSE ps -aq ghost" 0 ''
  stub_rule docker 'inspect *' 1 ''
  assert_fail pu_container_running ghost
}

# ---------------------------------------------------------------------------
# pu_edge_available — is the zero-downtime path possible at all?
# ---------------------------------------------------------------------------

test_edge_available_when_the_front_door_is_running() {
  stub_rule docker "$COMPOSE ps --status running --format *" 0 'backend\nedge\nweb'
  assert_ok pu_edge_available
}

test_edge_unavailable_when_nothing_is_running() {
  stub_rule docker "$COMPOSE ps --status running --format *" 0 ''
  assert_fail pu_edge_available
}

test_edge_unavailable_when_the_stack_predates_the_front_door() {
  # An older install: everything is up, there is simply no edge service.
  stub_rule docker "$COMPOSE ps --status running --format *" 0 'backend\nweb\npostgres'
  assert_fail pu_edge_available
}

test_edge_availability_requires_an_exact_service_name() {
  # `grep -qx` and not `grep -q`: a service merely CONTAINING "edge" is not the
  # front door, and treating it as one would send an update down the live path
  # with nothing holding the LAN port.
  stub_rule docker "$COMPOSE ps --status running --format *" 0 'backend\nedge-proxy-legacy\nweb'
  assert_fail pu_edge_available
}

test_edge_unavailable_when_compose_cannot_be_reached() {
  stub_rule docker '*' 1
  assert_fail pu_edge_available
}

# ---------------------------------------------------------------------------
# pu_upstream_ready — probes through the front door, on the path traffic takes.
# ---------------------------------------------------------------------------

test_upstream_ready_probes_from_inside_the_front_door() {
  assert_ok pu_upstream_ready pointy-backend-standby
  # It must go through `edge`, not curl from the host: a container name the
  # host can reach but nginx cannot resolve would otherwise pass here and fail
  # immediately after the flip.
  assert_called docker "$COMPOSE exec -T edge wget -q -O /dev/null http://pointy-backend-standby:8000/readyz/"
  assert_eq '0' "$(count_calls curl)"
}

test_upstream_ready_fails_when_the_probe_fails() {
  stub_rule docker "$COMPOSE exec -T edge wget*" 1
  assert_fail pu_upstream_ready backend
}

# ---------------------------------------------------------------------------
# pu_wait_upstream
# ---------------------------------------------------------------------------

_container_is_running() { stub_rule docker 'inspect -f * *' 0 'true'; }

test_wait_upstream_returns_as_soon_as_the_container_serves() {
  _container_is_running
  local out; out="$(pu_wait_upstream backend 'the backend' 5 2>&1)"
  assert_contains "$out" 'the backend is ready'
}

test_wait_upstream_gives_up_early_when_the_container_died() {
  # A backend that crash-loops on a bad migration must not hold the update
  # hostage for the full timeout — and its logs are what the operator needs.
  stub_rule docker "$COMPOSE ps -aq pointy-backend-standby" 0 'cid9'
  stub_rule docker 'inspect -f * cid9' 0 'false'
  stub_rule docker 'logs --tail 40 cid9' 0 'django.db.utils.ProgrammingError: relation does not exist'
  local out; out="$(pu_wait_upstream pointy-backend-standby 'the new backend' 180 2>&1)"
  assert_contains "$out" 'the new backend exited during startup'
  assert_contains "$out" 'ProgrammingError'
  # It bailed on the first iteration rather than probing 180 times.
  assert_call_count docker 'inspect -f * cid9' 1
}

test_wait_upstream_gives_up_after_the_try_budget() {
  _container_is_running
  stub_rule docker "$COMPOSE exec -T edge wget*" 1
  stub_rule docker 'logs --tail 40 *' 0 'still booting'
  local out; out="$(pu_wait_upstream backend 'the backend' 3 2>&1)"
  assert_contains "$out" 'the backend never became ready'
  assert_call_count docker "$COMPOSE exec -T edge wget*" 3
}

test_wait_upstream_reports_progress_every_two_minutes() {
  _container_is_running
  stub_rule docker "$COMPOSE exec -T edge wget*" 1
  stub_rule docker 'logs*' 0 'x'
  local out; out="$(pu_wait_upstream backend 'the backend' 24 2>&1)"
  # Probes are 10s apart, so the twelfth is the two-minute mark.
  assert_contains "$out" 'still waiting for the backend (120s)'
  assert_contains "$out" 'still waiting for the backend (240s)'
}

test_wait_upstream_does_not_probe_at_all_with_a_zero_budget() {
  _container_is_running
  assert_fail pu_wait_upstream backend 'the backend' 0
  assert_not_called docker "$COMPOSE exec -T edge wget*"
}

# ---------------------------------------------------------------------------
# pu_dump_logs
# ---------------------------------------------------------------------------

test_dump_logs_indents_the_container_log() {
  stub_rule docker "$COMPOSE ps -aq backend" 0 'cid7'
  stub_rule docker 'logs --tail 40 cid7' 0 'line one\nline two'
  local out; out="$(pu_dump_logs backend)"
  assert_contains "$out" '    line one'
  assert_contains "$out" '    line two'
}

test_dump_logs_is_silent_and_successful_when_docker_has_nothing() {
  stub_rule docker '*' 1
  assert_ok pu_dump_logs ghost
}

pu_run_tests "$@"
