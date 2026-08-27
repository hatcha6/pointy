#!/usr/bin/env bash
#
# The zero-downtime path. pu_apply_live's return code IS its contract:
#
#     0  the new release is serving
#     1  it aborted BEFORE any traffic moved — the shop never noticed, and the
#        caller must NOT roll anything back (there is nothing to roll back, and
#        recreating the backend would cause the very outage we avoided)
#     2  it failed AFTER the switchover — the caller must roll the backend back
#
# Confusing 1 and 2 is the difference between "nothing happened" and "the shop
# is being served by a container with no restart policy". Every test here exists
# to pin one edge of that contract.
. "$(dirname "$0")/harness.sh"

COMPOSE='compose --env-file .env -f docker-compose.yml'

# Replace pu_apply_live's collaborators with recorders. Each test then breaks
# exactly one of them.
_mock_deps() {
  pu_load_images()   { record "load:$1"; return 0; }
  pu_start_standby() { record 'start-standby'; return 0; }
  pu_remove_standby(){ record 'remove-standby'; return 0; }
  pu_wait_upstream() { record "wait:$1"; return 0; }
  pu_set_upstream()  { record "flip:$1"; return 0; }
  pu_recreate()      { record "recreate:$*"; return 0; }
  pu_publish_clients(){ record 'publish-clients'; return 0; }
  pu_report_staged_infra() { record 'report-infra'; return 0; }
}

_order() { cat "${PU_TEST_DIR}/order.log"; }

# ---------------------------------------------------------------------------
# The happy path
# ---------------------------------------------------------------------------

test_live_update_succeeds_and_returns_zero() {
  _mock_deps
  assert_status 0 pu_apply_live 1.1.0 >/dev/null 2>&1
}

test_live_update_runs_its_steps_in_the_only_safe_order() {
  _mock_deps
  pu_apply_live 1.1.0 >/dev/null 2>&1
  # Images before the standby: the standby must start ON the new image.
  assert_order 'load:live' 'start-standby'
  # Proven ready before any traffic moves. This is the invariant.
  assert_order 'wait:pointy-backend-standby' 'flip:pointy-backend-standby'
  # The managed backend is only rebuilt while the standby is serving.
  assert_order 'flip:pointy-backend-standby' 'recreate:backend'
  # Traffic returns to the managed container before the standby is destroyed.
  assert_order 'flip:backend' 'remove-standby'
}

test_live_update_hands_traffic_back_to_the_managed_container() {
  # The standby is a `compose run` one-off with no restart policy. Leaving the
  # shop on it would work all afternoon and then not survive the night.
  _mock_deps
  pu_apply_live 1.1.0 >/dev/null 2>&1
  local order; order="$(_order)"
  assert_contains "$order" 'flip:backend'
  # ...and the last flip of the update is the one to `backend`.
  assert_eq 'backend' "$(_order | grep '^flip:' | tail -1 | cut -d: -f2)"
}

test_live_update_replaces_the_remaining_services_after_the_tills_are_safe() {
  _mock_deps
  pu_apply_live 1.1.0 >/dev/null 2>&1
  local order; order="$(_order)"
  assert_contains "$order" 'recreate:celery-worker celery-beat'
  assert_contains "$order" 'recreate:connector'
  assert_contains "$order" 'recreate:web'
  assert_order 'flip:backend' 'recreate:web'
}

test_live_update_publishes_client_installers_and_reports_staged_infra() {
  _mock_deps
  pu_apply_live 1.1.0 >/dev/null 2>&1
  assert_contains "$(_order)" 'publish-clients'
  assert_contains "$(_order)" 'report-infra'
}

test_live_update_only_loads_application_images() {
  _mock_deps
  pu_apply_live 1.1.0 >/dev/null 2>&1
  assert_contains "$(_order)" 'load:live'
}

# ---------------------------------------------------------------------------
# Aborting before any traffic moved — return 1
# ---------------------------------------------------------------------------

test_a_failed_image_load_aborts_before_anything_starts() {
  _mock_deps
  pu_load_images() { record 'load-failed'; return 1; }
  assert_status 1 pu_apply_live 1.1.0 >/dev/null 2>&1
  assert_not_contains "$(_order)" 'start-standby'
  assert_not_contains "$(_order)" 'flip:'
}

test_a_standby_that_will_not_start_aborts_without_moving_traffic() {
  _mock_deps
  pu_start_standby() { record 'start-failed'; return 1; }
  local out; out="$(pu_apply_live 1.1.0 2>&1)"; local rc=$?
  assert_eq '1' "$rc"
  assert_contains "$out" 'could not start the new backend'
  assert_not_contains "$(_order)" 'flip:'
}

test_a_standby_that_never_becomes_ready_is_torn_down_and_nothing_moves() {
  # The commonest real failure: a release whose migrations fail, or that crashes
  # on boot. The shop must not notice at all.
  _mock_deps
  pu_wait_upstream() { record "wait:$1"; return 1; }
  local out; out="$(pu_apply_live 1.1.0 2>&1)"; local rc=$?
  assert_eq '1' "$rc"
  assert_contains "$out" 'never became ready'
  assert_contains "$out" 'nothing was switched over'
  assert_contains "$(_order)" 'remove-standby'
  assert_not_contains "$(_order)" 'flip:'
}

test_a_rejected_first_flip_returns_one_not_two() {
  # THE EDGE THAT MATTERS. If nginx refuses the config, traffic is still on the
  # old backend — so this is an abort (1), not a post-switchover failure (2).
  # Returning 2 here would send the caller into pu_rollback_live, which recreates
  # the backend container that is at that moment happily serving the shop.
  _mock_deps
  pu_set_upstream() { record "flip-failed:$1"; return 1; }
  assert_status 1 pu_apply_live 1.1.0 >/dev/null 2>&1
  assert_contains "$(_order)" 'remove-standby'
  assert_not_contains "$(_order)" 'recreate:backend'
}

test_an_aborted_update_never_leaves_the_standby_running() {
  # A leftover standby would be swept by nothing (compose ignores one-offs) and
  # would still be holding a database connection.
  _mock_deps
  pu_wait_upstream() { return 1; }
  pu_apply_live 1.1.0 >/dev/null 2>&1
  assert_contains "$(_order)" 'remove-standby'
}

# ---------------------------------------------------------------------------
# Failing after the switchover — return 2
# ---------------------------------------------------------------------------

test_a_backend_that_will_not_be_recreated_returns_two() {
  _mock_deps
  pu_recreate() { case "$1" in backend) record 'recreate-failed'; return 1 ;; esac; record "recreate:$*"; return 0; }
  local out; out="$(pu_apply_live 1.1.0 2>&1)"; local rc=$?
  assert_eq '2' "$rc"
  assert_contains "$out" 'could not recreate the backend service'
}

test_a_rebuilt_backend_that_never_serves_returns_two() {
  _mock_deps
  pu_wait_upstream() { record "wait:$1"; case "$1" in backend) return 1 ;; esac; return 0; }
  assert_status 2 pu_apply_live 1.1.0 >/dev/null 2>&1
}

test_a_failed_flip_back_returns_two() {
  # Traffic is on the standby and cannot be moved off it. The caller must know
  # the shop is on a temporary container.
  _mock_deps
  pu_set_upstream() { record "flip:$1"; case "$1" in backend) return 1 ;; esac; return 0; }
  assert_status 2 pu_apply_live 1.1.0 >/dev/null 2>&1
}

test_a_post_switchover_failure_leaves_the_standby_serving() {
  # It is the only healthy backend at that moment; destroying it would take the
  # shop down. pu_rollback_live decides its fate, not pu_apply_live.
  _mock_deps
  pu_wait_upstream() { record "wait:$1"; case "$1" in backend) return 1 ;; esac; return 0; }
  pu_apply_live 1.1.0 >/dev/null 2>&1
  assert_not_contains "$(_order)" 'remove-standby'
}

# ---------------------------------------------------------------------------
# Non-fatal failures — the tills are already served, so nothing here fails the
# update
# ---------------------------------------------------------------------------

test_background_workers_that_do_not_restart_do_not_fail_the_update() {
  _mock_deps
  pu_recreate() { record "recreate:$*"; case "$1" in celery-worker) return 1 ;; esac; return 0; }
  local out; out="$(pu_apply_live 1.1.0 2>&1)"; local rc=$?
  assert_eq '0' "$rc"
  assert_contains "$out" 'background workers did not restart cleanly'
}

test_a_connector_that_does_not_restart_does_not_fail_the_update() {
  # A shop that cannot reach the relay is still a shop that can sell.
  _mock_deps
  pu_recreate() { record "recreate:$*"; case "$1" in connector) return 1 ;; esac; return 0; }
  local out; out="$(pu_apply_live 1.1.0 2>&1)"; local rc=$?
  assert_eq '0' "$rc"
  assert_contains "$out" 'relay connector did not restart cleanly'
}

test_a_web_app_that_does_not_restart_does_not_fail_the_update() {
  _mock_deps
  pu_recreate() { record "recreate:$*"; case "$1" in web) return 1 ;; esac; return 0; }
  local out; out="$(pu_apply_live 1.1.0 2>&1)"; local rc=$?
  assert_eq '0' "$rc"
  assert_contains "$out" 'web app did not restart cleanly'
}

# ---------------------------------------------------------------------------
# The real docker invocations behind the mocks
# ---------------------------------------------------------------------------

test_standby_is_a_one_off_container_that_compose_will_not_sweep() {
  default_env
  pu_start_standby >/dev/null 2>&1
  # `run -d --no-deps --name`: no published port (so it cannot collide with the
  # live container) and the one-off label (so `up --remove-orphans` leaves it).
  assert_called docker "$COMPOSE run -d --no-deps --name pointy-backend-standby backend"
}

test_starting_a_standby_first_clears_any_leftover_one() {
  default_env
  pu_start_standby >/dev/null 2>&1
  assert_called docker 'rm -f pointy-backend-standby'
  local calls; calls="$(calls_of docker)"
  local rm_line run_line
  rm_line="$(printf '%s\n' "$calls" | grep -n 'rm -f pointy-backend-standby' | head -1 | cut -d: -f1)"
  run_line="$(printf '%s\n' "$calls" | grep -n 'run -d --no-deps' | head -1 | cut -d: -f1)"
  [ "$rm_line" -lt "$run_line" ] || _fail 'the leftover standby was not removed before starting a new one'
}

test_removing_a_standby_that_is_not_there_is_harmless() {
  stub_rule docker 'rm -f *' 1
  assert_ok pu_remove_standby
}

test_recreate_replaces_a_service_without_touching_its_dependencies() {
  # `--no-deps` is what keeps postgres, redis and the front door out of it.
  default_env
  pu_recreate backend >/dev/null 2>&1
  assert_called docker "$COMPOSE up -d --no-deps --force-recreate backend"
}

test_recreate_can_replace_several_services_at_once() {
  default_env
  pu_recreate celery-worker celery-beat >/dev/null 2>&1
  assert_called docker "$COMPOSE up -d --no-deps --force-recreate celery-worker celery-beat"
}

# ---------------------------------------------------------------------------
# pu_publish_clients
# ---------------------------------------------------------------------------

test_publishing_clients_is_skipped_when_the_bundle_carried_none() {
  default_env
  assert_ok pu_publish_clients
  assert_eq '0' "$(count_calls docker)"
}

test_publishing_clients_copies_them_into_the_backend_and_makes_them_readable() {
  default_env
  mkdir -p clients
  printf 'installer\n' >clients/pointy-windows.exe
  pu_publish_clients >/dev/null 2>&1
  assert_called docker "$COMPOSE cp clients/. backend:/var/lib/pointy/clients/"
  assert_called docker "$COMPOSE exec -u 0 -T backend chmod -R a+rX /var/lib/pointy/clients"
}

test_publishing_clients_warns_but_does_not_fail_when_the_backend_refuses() {
  default_env
  mkdir -p clients
  stub_rule docker "$COMPOSE cp clients/.*" 1
  local out; out="$(pu_publish_clients 2>&1)"
  assert_contains "$out" 'could not publish client installers'
}

# ---------------------------------------------------------------------------
# pu_register_autostart
# ---------------------------------------------------------------------------

test_autostart_registration_is_skipped_without_systemd() {
  rm -f "${PU_STUB_DIR}/systemctl"
  printf 'exit 0\n' >register-autostart.sh
  assert_ok pu_register_autostart
  assert_eq '' "$(pu_register_autostart 2>&1)"
}

test_autostart_registration_runs_as_root() {
  # Every update re-registers, so services a NEW bundle ships (the update agent
  # itself, the discovery responder) get installed without anyone remembering.
  stub_script id <<'EOF'
echo 0
EOF
  printf 'touch registered\n' >register-autostart.sh
  local out; out="$(pu_register_autostart 2>&1)"
  assert_contains "$out" 're-registering autostart services'
  assert_file registered
}

test_autostart_registration_tells_a_non_root_operator_what_to_run() {
  stub_script id <<'EOF'
echo 1000
EOF
  printf 'touch registered\n' >register-autostart.sh
  local out; out="$(pu_register_autostart 2>&1)"
  assert_contains "$out" 'not running as root'
  assert_contains "$out" 'sudo bash register-autostart.sh'
  assert_no_file registered
}

test_a_failing_autostart_registration_warns_rather_than_aborting() {
  stub_script id <<'EOF'
echo 0
EOF
  printf 'exit 1\n' >register-autostart.sh
  local out; out="$(pu_register_autostart 2>&1)"
  assert_contains "$out" 'autostart registration failed'
}

pu_run_tests "$@"
