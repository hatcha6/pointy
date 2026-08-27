#!/usr/bin/env bash
#
# update.sh — the bundle an engineer carries to the machine. Same engine as the
# agent, different front end: it takes a path rather than a manifest, and it is
# allowed to refuse (exit non-zero) where the agent must stay quiet, because a
# person is watching this one.
. "$(dirname "$0")/harness.sh"

_install_updater() {
  installed_deploy "${1:-1.0.0}"
  cp "${PU_ONPREM_DIR}/update.sh" ./update.sh
  chmod +x ./update.sh
  cat >./update-lib.sh <<EOF
. "${PU_LIB}"
pu_apply_bundle() {
  printf 'apply:%s->%s mode=%s dir=%s\n' "\$2" "\$3" "\${4:-auto}" "\$1" >>"\${PU_TEST_DIR}/order.log"
  return "\${APPLY_RC:-0}"
}
EOF
}

_run() { bash ./update.sh "$@"; }
_order() { cat "${PU_TEST_DIR}/order.log" 2>/dev/null; }

_zip_bundle() { # _zip_bundle <version> -> path
  make_bundle "${PU_TEST_DIR}/src/pointy-onprem-${1}" "$1"
  if command -v zip >/dev/null 2>&1; then
    ( cd "${PU_TEST_DIR}/src" && zip -qr "${PU_TEST_DIR}/bundle-${1}.zip" . )
  else
    python3 "${PU_TESTS_DIR}/zipdir.py" "${PU_TEST_DIR}/bundle-${1}.zip" "${PU_TEST_DIR}/src"
  fi
  printf '%s' "${PU_TEST_DIR}/bundle-${1}.zip"
}

# ---------------------------------------------------------------------------
# Arguments and preconditions
# ---------------------------------------------------------------------------

test_running_it_with_no_bundle_prints_usage() {
  _install_updater
  local out; out="$(_run 2>&1)"; local rc=$?
  assert_eq '1' "$rc"
  assert_contains "$out" 'usage: bash update.sh'
}

test_a_bundle_path_that_does_not_exist_is_refused() {
  _install_updater
  local out; out="$(_run /no/such/bundle.zip 2>&1)"; local rc=$?
  assert_eq '1' "$rc"
  assert_contains "$out" 'bundle not found: /no/such/bundle.zip'
}

test_an_unknown_option_is_refused() {
  # Unlike the agent — a person typed this, and silently ignoring a flag they
  # believed in is worse than stopping.
  _install_updater
  local out; out="$(_run --nope 2>&1)"; local rc=$?
  assert_eq '1' "$rc"
  assert_contains "$out" 'unknown option: --nope'
}

test_it_refuses_to_run_outside_a_deploy_directory() {
  _install_updater
  rm -f .env
  make_bundle "${PU_TEST_DIR}/b" 1.1.0
  local out; out="$(_run "${PU_TEST_DIR}/b" 2>&1)"; local rc=$?
  assert_eq '1' "$rc"
  assert_contains "$out" 'run from the deploy directory'
}

test_it_refuses_to_run_without_docker() {
  _install_updater
  make_bundle "${PU_TEST_DIR}/b" 1.1.0
  local out rc
  out="$(PATH="$(farm_path)" _run "${PU_TEST_DIR}/b" 2>&1)"; rc=$?
  assert_eq '1' "$rc"
  assert_contains "$out" 'docker not found on PATH'
}

# ---------------------------------------------------------------------------
# Applying
# ---------------------------------------------------------------------------

test_a_bundle_directory_is_applied() {
  _install_updater 1.0.0
  make_bundle "${PU_TEST_DIR}/b" 1.1.0
  assert_status 0 _run "${PU_TEST_DIR}/b" >/dev/null 2>&1
  assert_contains "$(_order)" 'apply:1.0.0->1.1.0 mode=auto'
}

test_a_bundle_zip_is_extracted_and_applied() {
  _install_updater 1.0.0
  local zip; zip="$(_zip_bundle 1.1.0)"
  assert_status 0 _run "$zip" >/dev/null 2>&1
  assert_contains "$(_order)" 'apply:1.0.0->1.1.0'
}

test_restart_and_live_are_passed_through() {
  _install_updater 1.0.0
  make_bundle "${PU_TEST_DIR}/b" 1.1.0
  _run "${PU_TEST_DIR}/b" --restart >/dev/null 2>&1
  assert_contains "$(_order)" 'mode=restart'
  : >"${PU_TEST_DIR}/order.log"
  _run "${PU_TEST_DIR}/b" --live >/dev/null 2>&1
  assert_contains "$(_order)" 'mode=live'
}

test_options_may_come_before_the_bundle_path() {
  _install_updater 1.0.0
  make_bundle "${PU_TEST_DIR}/b" 1.1.0
  _run --restart "${PU_TEST_DIR}/b" >/dev/null 2>&1
  assert_contains "$(_order)" 'mode=restart'
  assert_contains "$(_order)" "dir=${PU_TEST_DIR}/b"
}

test_a_failing_update_is_reported_by_the_exit_status() {
  # `bash update.sh ... && echo done` has to mean what it looks like.
  _install_updater 1.0.0
  make_bundle "${PU_TEST_DIR}/b" 1.1.0
  export APPLY_RC=1
  assert_status 1 _run "${PU_TEST_DIR}/b" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Re-applying the installed version
# ---------------------------------------------------------------------------

test_re_applying_the_installed_version_is_refused() {
  _install_updater 1.1.0
  make_bundle "${PU_TEST_DIR}/b" 1.1.0
  local out; out="$(_run "${PU_TEST_DIR}/b" 2>&1)"; local rc=$?
  assert_eq '1' "$rc"
  assert_contains "$out" 'already on 1.1.0; pass --force to re-apply'
  assert_eq '' "$(_order)"
}

test_force_re_applies_the_installed_version() {
  # The repair path: a shop whose images were lost or whose stack drifted.
  _install_updater 1.1.0
  make_bundle "${PU_TEST_DIR}/b" 1.1.0
  assert_status 0 _run "${PU_TEST_DIR}/b" --force >/dev/null 2>&1
  assert_contains "$(_order)" 'apply:1.1.0->1.1.0'
}

test_a_deployment_of_unknown_version_is_not_treated_as_already_current() {
  _install_updater 1.0.0
  rm -f VERSION.txt
  make_bundle "${PU_TEST_DIR}/b" 1.1.0
  assert_status 0 _run "${PU_TEST_DIR}/b" >/dev/null 2>&1
  assert_contains "$(_order)" 'apply:unknown->1.1.0'
}

test_a_bundle_with_no_version_file_against_an_unknown_deployment_is_refused() {
  # Both sides read "unknown", which compares equal — so the guard fires. Better
  # than applying a bundle whose identity nobody can establish.
  _install_updater 1.0.0
  rm -f VERSION.txt
  make_bundle "${PU_TEST_DIR}/b" 1.1.0
  rm "${PU_TEST_DIR}/b/VERSION.txt"
  local out; out="$(_run "${PU_TEST_DIR}/b" 2>&1)"; local rc=$?
  assert_eq '1' "$rc"
  assert_contains "$out" 'already on unknown'
}

# ---------------------------------------------------------------------------
# The lock
# ---------------------------------------------------------------------------

test_it_refuses_to_start_while_another_update_holds_the_lock() {
  _install_updater 1.0.0
  make_bundle "${PU_TEST_DIR}/b" 1.1.0
  printf 'pid=4242 started=now\n' >.update.lock
  local out; out="$(_run "${PU_TEST_DIR}/b" 2>&1)"; local rc=$?
  assert_eq '1' "$rc"
  assert_contains "$out" 'another update is already running'
  assert_eq '' "$(_order)"
}

test_standing_down_does_not_take_the_other_updates_lock_away() {
  # update.sh gets this right by construction — it acquires BEFORE arming the
  # trap. Pinned so a future tidy-up of the two front ends cannot regress it
  # into the shape update-agent.sh had.
  _install_updater 1.0.0
  make_bundle "${PU_TEST_DIR}/b" 1.1.0
  printf 'pid=4242 started=now\n' >.update.lock
  _run "${PU_TEST_DIR}/b" >/dev/null 2>&1
  assert_file_contains .update.lock 'pid=4242'
}

test_the_lock_is_released_when_the_update_finishes() {
  _install_updater 1.0.0
  make_bundle "${PU_TEST_DIR}/b" 1.1.0
  _run "${PU_TEST_DIR}/b" >/dev/null 2>&1
  assert_no_file .update.lock
}

test_the_lock_is_released_when_the_update_fails() {
  _install_updater 1.0.0
  make_bundle "${PU_TEST_DIR}/b" 1.1.0
  export APPLY_RC=1
  _run "${PU_TEST_DIR}/b" >/dev/null 2>&1
  assert_no_file .update.lock
}

# ---------------------------------------------------------------------------
# The operator's media is theirs
# ---------------------------------------------------------------------------

test_a_bundle_directory_is_left_completely_untouched() {
  # An engineer installing six shops from one USB stick must still have six
  # shops' worth of bundle after the first one.
  _install_updater 1.0.0
  make_bundle "${PU_TEST_DIR}/b" 1.1.0
  _run "${PU_TEST_DIR}/b" >/dev/null 2>&1
  assert_file "${PU_TEST_DIR}/b/images/pointy-backend.tar"
  assert_file "${PU_TEST_DIR}/b/images/pointy-relay.tar"
  assert_file "${PU_TEST_DIR}/b/VERSION.txt"
}

test_a_zip_is_left_untouched_but_its_extracted_copy_is_cleaned_up() {
  _install_updater 1.0.0
  local zip; zip="$(_zip_bundle 1.1.0)"
  _run "$zip" >/dev/null 2>&1
  assert_file "$zip"
  # Nothing extracted should survive: it holds the same image archives.
  local leftovers; leftovers="$(find "${TMPDIR:-/tmp}" -maxdepth 2 -name 'pointy-onprem-1.1.0' -newer "$zip" 2>/dev/null)"
  assert_eq '' "$leftovers"
}

pu_run_tests "$@"
