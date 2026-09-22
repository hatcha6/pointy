#!/usr/bin/env bash
#
# change-license.sh: moving a shop whose install redeemed the wrong license key
# onto the right one.
#
# The rules being pinned here:
#   * the key is redeemed BEFORE anything on this host changes, and a key the
#     relay refuses leaves .env and the connector exactly as they were;
#   * a key is never spent without a confirmation or an explicit --yes;
#   * after a successful redeem, .env holds the new key and the connector's
#     saved identity is gone, so it re-registers as the new installation;
#   * the whole run holds the lock the watchdog and the update agent respect.
. "$(dirname "$0")/harness.sh"

seed_deploy() {
  cp "${PU_ONPREM_DIR}/change-license.sh" "${PU_ONPREM_DIR}/update-lib.sh" .
  printf 'services: {}\n' >docker-compose.yml
  write_env 'COMPOSE_PROJECT_NAME=pointy' \
    'POINTY_RELAY_ENROLLMENT_TOKEN=pte1.wrong-key' \
    'POINTY_DATABASE_URL=postgres://pointy:c2Vj==@pgbouncer:5432/pointy?a=1&b=2'
  stub_rule docker '*ps --status running --quiet backend' 0 'backend-container'
  stub_rule docker 'inspect -f *com.docker.compose.project*' 0 'pointy'
  stub_rule docker 'volume ls *' 0 'pointy_pointy-connector-state'
}

# stdin is never a terminal here, so a run without --yes has nobody to ask.
change_license() { bash change-license.sh "$@" </dev/null >"${PU_TEST_DIR}/out.log" 2>&1; }
output() { cat "${PU_TEST_DIR}/out.log"; }

# The line a docker call was recorded on, to compare the order of two steps.
line_of() { grep -n -F -- "$1" "$PU_STUB_CALLS" | head -1 | cut -d: -f1; }

test_redeems_the_key_then_records_it_then_resets_the_connector() {
  seed_deploy
  assert_ok change_license pte1.right-key --yes

  assert_called docker '*exec -T backend python manage.py relay_change_license --no-input pte1.right-key'
  assert_eq 'pte1.right-key' "$(pu_env_value POINTY_RELAY_ENROLLMENT_TOKEN)"
  assert_called docker '*rm -s -f connector'
  assert_called docker 'volume rm pointy_pointy-connector-state'
  # --no-deps: the backend's environment changed in .env, and recreating it
  # would cut the tills off for a Django cold start.
  assert_called docker '*up -d --no-deps connector'
  assert_not_called docker '*up -d backend*'

  local redeem removed wiped started
  redeem="$(line_of relay_change_license)"
  removed="$(line_of 'rm -s -f connector')"
  wiped="$(line_of 'volume rm')"
  started="$(line_of 'up -d --no-deps connector')"
  [ "$redeem" -lt "$removed" ] && [ "$removed" -lt "$wiped" ] && [ "$wiped" -lt "$started" ] \
    || _fail "steps ran out of order" "$(all_calls)"
  assert_no_file .update.lock
}

test_a_key_the_relay_refuses_changes_nothing_on_this_host() {
  seed_deploy
  stub_rule docker '*relay_change_license*' 1
  local env_before; env_before="$(cat .env)"

  assert_fail change_license pte1.spent-key --yes

  assert_file_eq .env "$env_before"
  assert_not_called docker '*rm -s -f connector'
  assert_not_called docker 'volume rm*'
  assert_contains "$(output)" "licensed exactly as it was"
  assert_no_file .update.lock
}

test_reads_the_key_from_license_key_when_none_is_given() {
  seed_deploy
  printf ' pte1.right-\nkey \n' >license.key
  assert_ok change_license --yes
  assert_called docker '*relay_change_license --no-input pte1.right-key'
}

test_refuses_without_a_key_before_touching_docker() {
  seed_deploy
  assert_fail change_license --yes
  assert_contains "$(output)" "no license key given"
  assert_eq 0 "$(count_calls docker)"
}

test_never_spends_a_key_without_confirmation_or_yes() {
  seed_deploy
  assert_fail change_license pte1.right-key
  assert_contains "$(output)" "--yes"
  assert_not_called docker '*relay_change_license*'
  assert_eq 'pte1.wrong-key' "$(pu_env_value POINTY_RELAY_ENROLLMENT_TOKEN)"
}

test_refuses_when_the_backend_is_not_running() {
  seed_deploy
  stub_reset_rules docker
  assert_fail change_license pte1.right-key --yes
  assert_contains "$(output)" "backend is not running"
  assert_not_called docker '*relay_change_license*'
}

test_stands_down_while_an_update_holds_the_lock() {
  seed_deploy
  printf 'pid=4242 started=now\n' >.update.lock
  assert_fail change_license pte1.right-key --yes
  assert_contains "$(output)" "update is running"
  assert_not_called docker '*relay_change_license*'
  # Not ours to remove: the update that holds it is still running.
  assert_file_contains .update.lock 'pid=4242'
}

test_holds_the_lock_through_every_step() {
  seed_deploy
  # A docker that notes, for each step, whether the lock was held when it ran.
  stub_script docker <<'EOF'
case "$*" in
  *"ps --status running --quiet backend") echo backend-container ;;
  "inspect -f "*) echo pointy ;;
  "volume ls "*) echo pointy_pointy-connector-state ;;
  *relay_change_license*|*"rm -s -f connector"|"volume rm "*|*"up -d --no-deps connector")
    if [ -f .update.lock ]; then echo held; else echo MISSING; fi >>"${PU_TEST_DIR}/lock.log" ;;
esac
exit 0
EOF
  assert_ok change_license pte1.right-key --yes
  assert_file_eq "${PU_TEST_DIR}/lock.log" "$(printf 'held\nheld\nheld\nheld')"
}

test_finds_the_connector_volume_of_the_project_the_stack_runs_under() {
  # Read off the running backend, not .env: the shell's COMPOSE_PROJECT_NAME
  # overrides .env for compose, and a wrong guess finds no volume at all.
  seed_deploy
  stub_reset_rules docker
  stub_rule docker '*ps --status running --quiet backend' 0 'backend-container'
  stub_rule docker 'inspect -f *com.docker.compose.project*' 0 'shop2'
  assert_ok change_license pte1.right-key --yes
  assert_called docker 'volume ls -q --filter label=com.docker.compose.project=shop2 --filter label=com.docker.compose.volume=pointy-connector-state'
}

test_a_stack_whose_project_cannot_be_read_is_reported_not_guessed() {
  seed_deploy
  stub_reset_rules docker
  stub_rule docker '*ps --status running --quiet backend' 0 'backend-container'
  stub_rule docker 'inspect *' 1

  assert_fail change_license pte1.right-key --yes

  assert_contains "$(output)" "license WAS changed"
  assert_contains "$(output)" "Reset the connector"
  assert_not_called docker '*rm -s -f connector'
  assert_not_called docker 'volume rm*'
  # The key is spent either way, so it is still recorded.
  assert_eq 'pte1.right-key' "$(pu_env_value POINTY_RELAY_ENROLLMENT_TOKEN)"
}

test_env_keeps_its_mode_and_its_other_lines() {
  seed_deploy
  chmod 600 .env
  assert_ok change_license pte1.right-key --yes
  assert_eq '600' "$(stat -c %a .env 2>/dev/null || stat -f %Lp .env)"
  assert_eq 'postgres://pointy:c2Vj==@pgbouncer:5432/pointy?a=1&b=2' "$(pu_env_value POINTY_DATABASE_URL)"
  assert_eq 1 "$(grep -c '^POINTY_RELAY_ENROLLMENT_TOKEN=' .env)"
}

test_a_failed_connector_reset_still_says_the_license_changed_and_how_to_finish() {
  seed_deploy
  stub_rule docker 'volume rm *' 1

  assert_fail change_license pte1.right-key --yes

  assert_contains "$(output)" "license WAS changed"
  assert_contains "$(output)" "rm -s -f connector"
  # The step before it still happened.
  assert_eq 'pte1.right-key' "$(pu_env_value POINTY_RELAY_ENROLLMENT_TOKEN)"
  assert_no_file .update.lock
}

pu_run_tests "$@"
