#!/usr/bin/env bash
#
# The whole update, including which strategy gets chosen and what happens on
# every failure. Two invariants drive most of these tests:
#
#   * VERSION.txt is the deployment's answer to "what am I running?" — the relay
#     reads it back through the agent. It must move ONLY when the new release is
#     actually serving, or the fleet view lies.
#   * the previous release's images are the rollback target, so they must not be
#     pruned on any path that did not succeed.
. "$(dirname "$0")/harness.sh"

# Collaborators become recorders. pu_restore_snapshot stays REAL, because
# "did the shop's .env come back byte-for-byte?" is the point of several tests.
_mock_deps() {
  pu_bundle_strategy() { printf '%s' "${BUNDLE_STRATEGY:-live}"; }
  pu_edge_available()  { record 'checked-edge'; [ "${EDGE_UP:-1}" = 1 ]; }
  pu_backup_database() { record "backup:$1->$2"; return 0; }
  pu_adopt_bundle()    { record "adopt:$2"; printf 'POINTY_BACKEND_IMAGE=pointy-backend:%s\n' "$2" >>.env; return 0; }
  pu_apply_live()      { record 'apply-live'; return "${LIVE_RC:-0}"; }
  pu_apply_restart()   { record 'apply-restart'; return "${RESTART_RC:-0}"; }
  pu_healthy()         { record 'health-check'; return "${HEALTH_RC:-0}"; }
  pu_register_autostart() { record 'register-autostart'; return 0; }
  pu_prune_superseded_images() { record "prune:$1"; return 0; }
  pu_rollback_live()   { record 'rollback-live'; return 1; }
  pu_compose()         { record "compose:$*"; return 0; }
}

# Everything above EXCEPT the adoption, which stays real. `unset -f` would not
# do: it deletes a function outright rather than revealing the one the library
# defined, so the call would simply fail and the test would pass vacuously.
_mock_deps_real_adopt() {
  _mock_deps
  pu_adopt_bundle() { _pu_real_adopt_bundle "$@"; }
}

_order() { cat "${PU_TEST_DIR}/order.log"; }
_bundle() { mkdir -p "${PU_TEST_DIR}/b/images"; printf '%s' "${PU_TEST_DIR}/b"; }

# ---------------------------------------------------------------------------
# Choosing a strategy
# ---------------------------------------------------------------------------

test_auto_applies_live_when_the_front_door_is_up() {
  installed_deploy 1.0.0; _mock_deps
  local out; out="$(pu_apply_bundle "$(_bundle)" 1.0.0 1.1.0 auto 2>&1)"
  assert_contains "$out" 'live (the shop keeps trading)'
  assert_contains "$(_order)" 'apply-live'
}

test_auto_falls_back_to_a_restart_on_a_deployment_with_no_front_door() {
  # A shop installed before the edge existed cannot be updated live — but THIS
  # update installs the front door, so every update after it can be.
  installed_deploy 1.0.0; _mock_deps
  EDGE_UP=0
  local out; out="$(pu_apply_bundle "$(_bundle)" 1.0.0 1.1.0 auto 2>&1)"
  assert_contains "$out" 'no LAN front door in this deployment yet'
  assert_contains "$out" 'updates after it are applied live'
  assert_contains "$(_order)" 'apply-restart'
  assert_not_contains "$(_order)" 'apply-live'
}

test_auto_obeys_a_release_that_declares_it_cannot_be_applied_live() {
  # A release whose migrations are not backward compatible ships
  # UPDATE_STRATEGY.txt=restart. Applying it live would run those migrations
  # while the PREVIOUS version is still serving the shop.
  installed_deploy 1.0.0; _mock_deps
  BUNDLE_STRATEGY=restart
  local out; out="$(pu_apply_bundle "$(_bundle)" 1.0.0 1.1.0 auto 2>&1)"
  assert_contains "$out" 'with a full restart'
  assert_contains "$(_order)" 'apply-restart'
}

test_an_explicit_live_request_still_falls_back_without_a_front_door() {
  installed_deploy 1.0.0; _mock_deps
  EDGE_UP=0
  local out; out="$(pu_apply_bundle "$(_bundle)" 1.0.0 1.1.0 live 2>&1)"
  assert_contains "$out" 'a live update needs the LAN front door'
  assert_contains "$(_order)" 'apply-restart'
}

test_an_explicit_live_request_cannot_override_the_releases_own_declaration() {
  # The operator does not get to overrule the release engineer here: they cannot
  # know the migrations are incompatible, and the release does.
  installed_deploy 1.0.0; _mock_deps
  BUNDLE_STRATEGY=restart
  local out; out="$(pu_apply_bundle "$(_bundle)" 1.0.0 1.1.0 live 2>&1)"
  assert_contains "$out" 'declares it cannot be applied live'
  assert_contains "$(_order)" 'apply-restart'
}

test_an_explicit_restart_request_wins_over_everything() {
  installed_deploy 1.0.0; _mock_deps
  local out; out="$(pu_apply_bundle "$(_bundle)" 1.0.0 1.1.0 restart 2>&1)"
  assert_contains "$(_order)" 'apply-restart'
  # It does not even ask about the front door — the operator asked for a
  # maintenance window and gets one.
  assert_not_contains "$(_order)" 'checked-edge'
}

# ---------------------------------------------------------------------------
# Backup and snapshot come before anything is changed
# ---------------------------------------------------------------------------

test_the_database_is_backed_up_before_the_new_release_is_adopted() {
  # Adoption is what pins the new image, and the standby's boot is what runs the
  # migrations. A backup taken after either is a backup of the wrong database.
  installed_deploy 1.0.0; _mock_deps
  pu_apply_bundle "$(_bundle)" 1.0.0 1.1.0 auto >/dev/null 2>&1
  assert_order 'backup:1.0.0->1.1.0' 'adopt:1.1.0'
  assert_order 'adopt:1.1.0' 'apply-live'
}

test_the_database_is_backed_up_on_the_restart_path_too() {
  installed_deploy 1.0.0; _mock_deps
  BUNDLE_STRATEGY=restart
  pu_apply_bundle "$(_bundle)" 1.0.0 1.1.0 auto >/dev/null 2>&1
  assert_order 'backup:1.0.0->1.1.0' 'adopt:1.1.0'
}

test_an_aborted_update_restores_the_shops_env_exactly() {
  installed_deploy 1.0.0
  printf 'POSTGRES_PASSWORD=this-shops-secret\n' >>.env
  local before; before="$(cat .env)"
  _mock_deps
  LIVE_RC=1
  pu_apply_bundle "$(_bundle)" 1.0.0 1.1.0 auto >/dev/null 2>&1
  assert_file_eq .env "$before"
}

test_an_aborted_update_restores_the_compose_file_too() {
  installed_deploy 1.0.0
  printf 'the version that is running\n' >docker-compose.yml
  _mock_deps
  pu_adopt_bundle() { record 'adopt'; printf 'the new one\n' >docker-compose.yml; }
  LIVE_RC=1
  pu_apply_bundle "$(_bundle)" 1.0.0 1.1.0 auto >/dev/null 2>&1
  assert_file_eq docker-compose.yml 'the version that is running'
}

# ---------------------------------------------------------------------------
# The live path's three outcomes
# ---------------------------------------------------------------------------

test_a_successful_live_update_records_the_new_version() {
  installed_deploy 1.0.0; _mock_deps
  assert_status 0 pu_apply_bundle "$(_bundle)" 1.0.0 1.1.0 auto >/dev/null 2>&1
  assert_file_eq VERSION.txt '1.1.0'
}

test_a_successful_live_update_reports_no_downtime() {
  installed_deploy 1.0.0; _mock_deps
  local out; out="$(pu_apply_bundle "$(_bundle)" 1.0.0 1.1.0 auto 2>&1)"
  assert_contains "$out" 'updated to 1.1.0 — no downtime'
}

test_a_successful_live_update_prunes_the_superseded_images() {
  installed_deploy 1.0.0; _mock_deps
  pu_apply_bundle "$(_bundle)" 1.0.0 1.1.0 auto >/dev/null 2>&1
  assert_contains "$(_order)" 'prune:1.0.0'
  # And only after the health check — until then the old images are the way back.
  assert_order 'health-check' 'prune:1.0.0'
}

test_an_apparently_successful_update_that_fails_the_health_check_rolls_back() {
  # pu_apply_live returned 0 and the front door reports the new backend, but
  # /readyz through the LAN port does not answer — which is what a till sees.
  installed_deploy 1.0.0; _mock_deps
  HEALTH_RC=1
  assert_status 1 pu_apply_bundle "$(_bundle)" 1.0.0 1.1.0 auto >/dev/null 2>&1
  assert_contains "$(_order)" 'rollback-live'
  assert_file_eq VERSION.txt '1.0.0'
}

test_an_abort_before_the_switchover_does_not_roll_anything_back() {
  # Return 1 means nothing moved. Calling pu_rollback_live here would recreate
  # the backend container that is at that moment serving the shop — turning a
  # non-event into an outage.
  installed_deploy 1.0.0; _mock_deps
  LIVE_RC=1
  local out; out="$(pu_apply_bundle "$(_bundle)" 1.0.0 1.1.0 auto 2>&1)"
  assert_contains "$out" 'aborted before any traffic moved; still on 1.0.0'
  assert_not_contains "$(_order)" 'rollback-live'
}

test_a_failure_after_the_switchover_rolls_the_backend_back() {
  installed_deploy 1.0.0; _mock_deps
  LIVE_RC=2
  assert_status 1 pu_apply_bundle "$(_bundle)" 1.0.0 1.1.0 auto >/dev/null 2>&1
  assert_contains "$(_order)" 'rollback-live'
}

test_a_failed_live_update_never_moves_version_txt() {
  # The relay believes VERSION.txt. A shop that failed to update but claims the
  # new version disappears from the rollout's "still to do" list forever.
  local rc
  for rc in 1 2; do
    installed_deploy 1.0.0; _mock_deps
    LIVE_RC="$rc"
    pu_apply_bundle "$(_bundle)" 1.0.0 1.1.0 auto >/dev/null 2>&1
    assert_file_eq VERSION.txt '1.0.0'
  done
}

test_a_failed_live_update_never_prunes_the_old_images() {
  local rc
  for rc in 1 2; do
    installed_deploy 1.0.0; _mock_deps
    LIVE_RC="$rc"
    pu_apply_bundle "$(_bundle)" 1.0.0 1.1.0 auto >/dev/null 2>&1
    assert_not_contains "$(_order)" 'prune:'
  done
}

test_a_health_check_failure_never_prunes_the_old_images() {
  installed_deploy 1.0.0; _mock_deps
  HEALTH_RC=1
  pu_apply_bundle "$(_bundle)" 1.0.0 1.1.0 auto >/dev/null 2>&1
  assert_not_contains "$(_order)" 'prune:'
}

# ---------------------------------------------------------------------------
# The restart path
# ---------------------------------------------------------------------------

test_a_successful_restart_update_records_the_new_version() {
  installed_deploy 1.0.0; _mock_deps
  BUNDLE_STRATEGY=restart
  assert_status 0 pu_apply_bundle "$(_bundle)" 1.0.0 1.1.0 auto >/dev/null 2>&1
  assert_file_eq VERSION.txt '1.1.0'
  assert_contains "$(_order)" 'prune:1.0.0'
}

test_a_restart_update_that_fails_rolls_back_and_brings_the_stack_up() {
  installed_deploy 1.0.0; _mock_deps
  BUNDLE_STRATEGY=restart
  RESTART_RC=1
  local out; out="$(pu_apply_bundle "$(_bundle)" 1.0.0 1.1.0 auto 2>&1)"
  assert_contains "$out" 'failed health check; rolling back to 1.0.0'
  assert_contains "$out" 'rolled back to 1.0.0'
  assert_contains "$(_order)" 'compose:up -d --remove-orphans'
  assert_file_eq VERSION.txt '1.0.0'
}

test_a_restart_update_that_installs_but_never_answers_rolls_back() {
  installed_deploy 1.0.0; _mock_deps
  BUNDLE_STRATEGY=restart
  HEALTH_RC=1
  # The rollback's own health check has to pass for the shop to be declared safe.
  pu_healthy() { record 'health-check'; [ "$(cat "${PU_TEST_DIR}/order.log" | grep -c '^health-check$')" -ge 2 ]; }
  local out; out="$(pu_apply_bundle "$(_bundle)" 1.0.0 1.1.0 auto 2>&1)"
  assert_contains "$out" 'rolled back to 1.0.0'
  assert_file_eq VERSION.txt '1.0.0'
}

test_a_restart_update_whose_rollback_is_also_unhealthy_says_so_plainly() {
  # The worst case a shop can be in. It must be unmistakable in the log, because
  # the next thing that happens is a phone call.
  installed_deploy 1.0.0; _mock_deps
  BUNDLE_STRATEGY=restart
  HEALTH_RC=1
  local out; out="$(pu_apply_bundle "$(_bundle)" 1.0.0 1.1.0 auto 2>&1)"
  assert_contains "$out" 'AND the rollback is unhealthy — manual intervention needed'
}

test_a_failed_restart_update_never_prunes_the_old_images() {
  installed_deploy 1.0.0; _mock_deps
  BUNDLE_STRATEGY=restart
  RESTART_RC=1
  pu_apply_bundle "$(_bundle)" 1.0.0 1.1.0 auto >/dev/null 2>&1
  assert_not_contains "$(_order)" 'prune:'
}

# ---------------------------------------------------------------------------
# What the deployment SAYS it is running, after a failure
#
# These use the REAL pu_adopt_bundle. The tests above mock it — which is exactly
# why they missed this: adoption copies the bundle's VERSION.txt over the
# deployment's as one of POINTY_ADOPT_FILES, so the new version is on disk
# before a single container has started. The rehearsal rig caught it against
# real Docker; these pin it here, where it costs milliseconds.
# ---------------------------------------------------------------------------

test_adoption_alone_already_rewrites_version_txt() {
  # The fact that makes the rest of this section necessary.
  installed_deploy 1.0.0
  make_bundle "${PU_TEST_DIR}/b" 2.0.0
  pu_adopt_bundle "${PU_TEST_DIR}/b" 2.0.0
  assert_file_eq VERSION.txt '2.0.0'
}

test_an_aborted_update_restores_the_version_the_shop_is_really_running() {
  # REGRESSION. Left unrestored, a failed update leaves the deployment claiming
  # the release that just failed to install, and three things go wrong at once:
  # update.sh refuses the retry ("already on 2.0.0"), the update agent sees
  # assigned == current and reports `idle` forever instead of retrying, and the
  # relay's fleet view shows the shop as updated while it still runs the old
  # code. A rollout looks green with shops silently left behind — the single
  # worst way for a fleet update to fail, because nobody finds out.
  installed_deploy 1.0.0
  _mock_deps_real_adopt
  make_bundle "${PU_TEST_DIR}/b" 2.0.0
  LIVE_RC=1
  pu_apply_bundle "${PU_TEST_DIR}/b" 1.0.0 2.0.0 auto >/dev/null 2>&1
  assert_file_eq VERSION.txt '1.0.0'
  assert_eq '1.0.0' "$(pu_current_version)" 'pu_current_version still reports the running release'
}

test_a_post_switchover_failure_also_restores_the_version() {
  installed_deploy 1.0.0
  _mock_deps_real_adopt
  pu_rollback_live() { record 'rollback-live'; pu_restore_snapshot "$1"; return 1; }
  make_bundle "${PU_TEST_DIR}/b" 2.0.0
  LIVE_RC=2
  pu_apply_bundle "${PU_TEST_DIR}/b" 1.0.0 2.0.0 auto >/dev/null 2>&1
  assert_file_eq VERSION.txt '1.0.0'
}

test_restoring_a_deployment_that_never_had_a_version_file_removes_the_adopted_one() {
  # A deployment predating VERSION.txt reports "unknown". After a failed update
  # it must report "unknown" again — not the version that failed.
  installed_deploy 1.0.0
  rm -f VERSION.txt
  _mock_deps_real_adopt
  make_bundle "${PU_TEST_DIR}/b" 2.0.0
  LIVE_RC=1
  pu_apply_bundle "${PU_TEST_DIR}/b" unknown 2.0.0 auto >/dev/null 2>&1
  assert_no_file VERSION.txt
  assert_eq 'unknown' "$(pu_current_version)"
}

test_a_successful_update_still_records_the_new_version() {
  # The restore must not have broken the ordinary path.
  installed_deploy 1.0.0
  _mock_deps_real_adopt
  make_bundle "${PU_TEST_DIR}/b" 2.0.0
  assert_status 0 pu_apply_bundle "${PU_TEST_DIR}/b" 1.0.0 2.0.0 auto >/dev/null 2>&1
  assert_file_eq VERSION.txt '2.0.0'
}

# ---------------------------------------------------------------------------
# Re-applying the same version (update.sh --force, or a relay re-assignment)
# ---------------------------------------------------------------------------

test_re_applying_the_installed_version_does_not_prune_its_own_images() {
  installed_deploy 1.1.0; _mock_deps
  pu_prune_superseded_images() { record "prune:$1->$2"; }
  pu_apply_bundle "$(_bundle)" 1.1.0 1.1.0 auto >/dev/null 2>&1
  # pu_apply_bundle still calls it; the guard lives inside prune itself and is
  # covered in test_images.sh. What matters here is that it is told the truth.
  assert_contains "$(_order)" 'prune:1.1.0->1.1.0'
}

test_updating_from_an_unknown_version_still_works() {
  # A deployment that predates VERSION.txt, or one whose file was lost.
  installed_deploy 1.0.0; rm -f VERSION.txt; _mock_deps
  assert_status 0 pu_apply_bundle "$(_bundle)" unknown 1.1.0 auto >/dev/null 2>&1
  assert_file_eq VERSION.txt '1.1.0'
}

pu_run_tests "$@"
