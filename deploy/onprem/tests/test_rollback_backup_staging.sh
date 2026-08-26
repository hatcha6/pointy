#!/usr/bin/env bash
#
# Rolling back after traffic has already moved, the pre-migration backup, and
# turning a bundle (zip or directory) into something applyable.
. "$(dirname "$0")/harness.sh"

COMPOSE='compose --env-file .env -f docker-compose.yml'

_order() { cat "${PU_TEST_DIR}/order.log"; }

_snapshot_of() { # _snapshot_of -> path to a snapshot holding the current files
  local snap; snap="$(mktemp -d)"
  cp .env "${snap}/.env"
  [ -f docker-compose.yml ] && cp docker-compose.yml "${snap}/docker-compose.yml"
  printf '%s' "$snap"
}

_make_zip() { # _make_zip <output.zip> <dir-to-zip-contents-of>
  local out="$1" dir="$2"
  if command -v zip >/dev/null 2>&1; then
    ( cd "$dir" && zip -qr "$out" . )
  else
    python3 "${PU_TESTS_DIR}/zipdir.py" "$out" "$dir"
  fi
}

# ---------------------------------------------------------------------------
# pu_restore_snapshot
# ---------------------------------------------------------------------------

test_restore_snapshot_puts_both_files_back() {
  installed_deploy 1.0.0
  printf 'POSTGRES_PASSWORD=secret\n' >>.env
  printf 'the running compose\n' >docker-compose.yml
  local snap; snap="$(_snapshot_of)"
  printf 'adopted env\n' >.env
  printf 'adopted compose\n' >docker-compose.yml
  pu_restore_snapshot "$snap"
  assert_file_contains .env 'POSTGRES_PASSWORD=secret'
  assert_file_eq docker-compose.yml 'the running compose'
}

test_restore_snapshot_cleans_itself_up() {
  installed_deploy 1.0.0
  local snap; snap="$(_snapshot_of)"
  pu_restore_snapshot "$snap"
  assert_no_file "$snap"
}

test_restore_snapshot_copes_with_a_snapshot_that_has_no_compose_file() {
  # A deployment mid-install, or one where docker-compose.yml had not landed yet.
  installed_deploy 1.0.0
  rm -f docker-compose.yml
  local snap; snap="$(_snapshot_of)"
  printf 'adopted env\n' >.env
  assert_ok pu_restore_snapshot "$snap"
  assert_file_contains .env 'POINTY_BACKEND_PORT'
}

# ---------------------------------------------------------------------------
# pu_rollback_live — traffic had already moved when something failed
# ---------------------------------------------------------------------------

_mock_rollback_deps() {
  pu_recreate()         { record "recreate:$*"; return "${RECREATE_RC:-0}"; }
  pu_wait_upstream()    { record "wait:$1"; return "${WAIT_RC:-0}"; }
  pu_set_upstream()     { record "flip:$1"; return 0; }
  pu_remove_standby()   { record 'remove-standby'; return 0; }
  pu_container_running(){ record "running?:$1"; [ "${STANDBY_ALIVE:-0}" = 1 ]; }
}

test_rollback_restores_the_previous_release_and_the_shop_stays_open() {
  installed_deploy 1.0.0; _mock_rollback_deps
  local snap; snap="$(_snapshot_of)"
  local out; out="$(pu_rollback_live "$snap" 1.0.0 1.1.0 2>&1)"; local rc=$?
  assert_eq '0' "$rc"
  assert_contains "$out" 'rolled back to 1.0.0; the shop stayed open throughout'
  assert_order 'recreate:backend' 'flip:backend'
  assert_order 'flip:backend' 'remove-standby'
}

test_rollback_puts_the_configuration_back_before_recreating_anything() {
  # The recreate has to happen against the OLD .env, or it just brings the
  # failing release back up again.
  installed_deploy 1.0.0
  printf 'POINTY_BACKEND_IMAGE=pointy-backend:1.0.0\n' >>.env
  local snap; snap="$(_snapshot_of)"
  printf 'POINTY_BACKEND_IMAGE=pointy-backend:1.1.0\n' >>.env
  _mock_rollback_deps
  pu_recreate() { record "env-at-recreate:$(grep -c 'pointy-backend:1.1.0' .env)"; return 0; }
  pu_rollback_live "$snap" 1.0.0 1.1.0 >/dev/null 2>&1
  assert_contains "$(_order)" 'env-at-recreate:0'
}

test_rollback_only_flips_traffic_after_the_old_backend_answers() {
  installed_deploy 1.0.0; _mock_rollback_deps
  pu_rollback_live "$(_snapshot_of)" 1.0.0 1.1.0 >/dev/null 2>&1
  assert_order 'wait:backend' 'flip:backend'
}

test_rollback_never_destroys_the_standby_before_traffic_has_left_it() {
  installed_deploy 1.0.0; _mock_rollback_deps
  pu_rollback_live "$(_snapshot_of)" 1.0.0 1.1.0 >/dev/null 2>&1
  assert_order 'flip:backend' 'remove-standby'
}

test_rollback_leaves_the_new_release_serving_when_the_old_one_will_not_come_back() {
  # Both releases cannot run: the old image may be gone, or the database may
  # already be migrated past it. The shop must keep trading on whatever is
  # healthy — and the standby needs a restart policy first, because it was
  # created as a one-off and would not survive a reboot.
  installed_deploy 1.0.0; _mock_rollback_deps
  RECREATE_RC=1
  STANDBY_ALIVE=1
  local out; out="$(pu_rollback_live "$(_snapshot_of)" 1.0.0 1.1.0 2>&1)"; local rc=$?
  assert_eq '1' "$rc"
  assert_called docker 'update --restart=unless-stopped pointy-backend-standby'
  assert_contains "$(_order)" 'flip:pointy-backend-standby'
  assert_contains "$out" 'the shop is being served by 1.1.0 from a'
  assert_contains "$out" "Run 'bash install.sh' at the next opportunity"
}

test_rollback_also_survives_an_old_backend_that_starts_but_never_serves() {
  installed_deploy 1.0.0; _mock_rollback_deps
  WAIT_RC=1
  STANDBY_ALIVE=1
  assert_status 1 pu_rollback_live "$(_snapshot_of)" 1.0.0 1.1.0 >/dev/null 2>&1
  assert_called docker 'update --restart=unless-stopped pointy-backend-standby'
}

test_rollback_reports_plainly_when_no_backend_is_left_at_all() {
  installed_deploy 1.0.0; _mock_rollback_deps
  RECREATE_RC=1
  STANDBY_ALIVE=0
  local out; out="$(pu_rollback_live "$(_snapshot_of)" 1.0.0 1.1.0 2>&1)"; local rc=$?
  assert_eq '1' "$rc"
  assert_contains "$out" "no healthy backend left — run 'bash install.sh' now"
  assert_not_called docker 'update --restart*'
}

test_rollback_gives_the_standby_a_restart_policy_before_pointing_at_it() {
  # Order matters: the front door must not be sent to a container that could
  # still vanish on the next crash.
  installed_deploy 1.0.0; _mock_rollback_deps
  RECREATE_RC=1
  STANDBY_ALIVE=1
  pu_set_upstream() { record "flip:$1 (restart-policy-set=$(calls_of docker | grep -c 'update --restart'))"; return 0; }
  pu_rollback_live "$(_snapshot_of)" 1.0.0 1.1.0 >/dev/null 2>&1
  assert_contains "$(_order)" 'flip:pointy-backend-standby (restart-policy-set=1)'
}

# ---------------------------------------------------------------------------
# pu_backup_database
# ---------------------------------------------------------------------------

test_backup_writes_a_dump_named_for_the_transition() {
  default_env
  stub_rule docker "$COMPOSE exec -T postgres sh -c *" 0 '-- PostgreSQL database dump'
  local out; out="$(pu_backup_database 1.0.0 1.1.0 2>&1)"
  assert_file_contains backups/pre-update-1.0.0-to-1.1.0.sql 'PostgreSQL database dump'
  assert_contains "$out" 'database backed up to backups/pre-update-1.0.0-to-1.1.0.sql'
}

test_backup_creates_the_backups_directory() {
  default_env
  rm -rf backups
  stub_rule docker "$COMPOSE exec -T postgres sh -c *" 0 'dump'
  pu_backup_database 1.0.0 1.1.0 >/dev/null 2>&1
  assert_dir backups
}

test_backup_runs_pg_dump_inside_the_database_container() {
  default_env
  pu_backup_database 1.0.0 1.1.0 >/dev/null 2>&1
  assert_called docker "$COMPOSE exec -T postgres sh -c pg_dump*"
}

test_a_failed_backup_leaves_no_empty_file_pretending_to_be_one() {
  # THE ONE THAT MATTERS. The redirect creates the file before pg_dump runs, so
  # a failure leaves a zero-byte .sql sitting in backups/ that looks exactly
  # like a real backup until the day someone tries to restore from it.
  default_env
  stub_rule docker "$COMPOSE exec -T postgres sh -c *" 1
  pu_backup_database 1.0.0 1.1.0 >/dev/null 2>&1
  assert_no_file backups/pre-update-1.0.0-to-1.1.0.sql
}

test_a_failed_backup_warns_and_lets_the_update_continue() {
  # Deliberately best-effort: a shop whose database is down still needs to be
  # able to take the update that fixes it.
  default_env
  stub_rule docker "$COMPOSE exec -T postgres sh -c *" 1
  local out; out="$(pu_backup_database 1.0.0 1.1.0 2>&1)"; local rc=$?
  assert_eq '0' "$rc"
  assert_contains "$out" 'database backup failed'
  assert_contains "$out" 'rollback restores images, not data'
}

test_backup_does_not_read_credentials_out_of_env_itself() {
  # The user and database name are expanded INSIDE the container by its own
  # shell, from the environment compose already gave it — so a password with
  # shell metacharacters never passes through the host's shell.
  default_env
  pu_backup_database 1.0.0 1.1.0 >/dev/null 2>&1
  local call; call="$(calls_of docker | grep 'exec -T postgres' | head -1)"
  assert_contains "$call" '${POSTGRES_USER:-pointy}'
}

# ---------------------------------------------------------------------------
# pu_current_version
# ---------------------------------------------------------------------------

test_current_version_reads_version_txt() {
  printf '1.2.3\n' >VERSION.txt
  assert_eq '1.2.3' "$(pu_current_version)"
}

test_current_version_is_unknown_without_the_file() {
  assert_eq 'unknown' "$(pu_current_version)"
}

test_current_version_trims_whitespace_and_crlf() {
  printf '  1.2.3  \r\n' >VERSION.txt
  assert_eq '1.2.3' "$(pu_current_version)"
}

test_current_version_is_empty_for_a_truncated_file() {
  # DOCUMENTED SHARP EDGE. `echo "$assigned" >VERSION.txt` is not atomic; a power
  # cut at that instant leaves the file empty, and this then reports "" rather
  # than "unknown". The agent posts that empty string to the relay as
  # current_version, so the shop shows up in `fleet status` with a blank version
  # — visible, but not obviously "this shop needs looking at".
  : >VERSION.txt
  assert_eq '' "$(pu_current_version)"
}

# ---------------------------------------------------------------------------
# pu_stage_bundle
# ---------------------------------------------------------------------------

test_staging_accepts_a_bundle_directory_as_is() {
  make_bundle "${PU_TEST_DIR}/b" 1.1.0
  assert_ok pu_stage_bundle "${PU_TEST_DIR}/b"
  assert_eq "${PU_TEST_DIR}/b" "$POINTY_BUNDLE_DIR"
  assert_eq '1.1.0' "$POINTY_BUNDLE_VERSION"
}

test_staging_a_directory_stages_nothing_that_needs_cleaning_up() {
  # An operator's USB stick is their own media — they may be installing several
  # shops from it — so update.sh must not shred anything inside it.
  make_bundle "${PU_TEST_DIR}/b" 1.1.0
  POINTY_BUNDLE_STAGING=''
  pu_stage_bundle "${PU_TEST_DIR}/b"
  assert_eq '' "${POINTY_BUNDLE_STAGING:-}"
}

test_staging_rejects_a_directory_that_is_not_a_bundle() {
  mkdir -p "${PU_TEST_DIR}/not-a-bundle"
  local out; out="$(pu_stage_bundle "${PU_TEST_DIR}/not-a-bundle" 2>&1)"; local rc=$?
  assert_eq '1' "$rc"
  assert_contains "$out" 'not a Pointy bundle: no images/ directory'
}

test_staging_reports_an_unknown_version_when_the_bundle_has_no_version_file() {
  make_bundle "${PU_TEST_DIR}/b" 1.1.0
  rm "${PU_TEST_DIR}/b/VERSION.txt"
  pu_stage_bundle "${PU_TEST_DIR}/b"
  assert_eq 'unknown' "$POINTY_BUNDLE_VERSION"
}

test_staging_trims_the_bundle_version() {
  make_bundle "${PU_TEST_DIR}/b" 1.1.0
  printf '  1.1.0  \r\n' >"${PU_TEST_DIR}/b/VERSION.txt"
  pu_stage_bundle "${PU_TEST_DIR}/b"
  assert_eq '1.1.0' "$POINTY_BUNDLE_VERSION"
}

test_staging_extracts_a_zip_and_finds_the_release_directory() {
  make_bundle "${PU_TEST_DIR}/src/pointy-onprem-1.1.0" 1.1.0
  _make_zip "${PU_TEST_DIR}/bundle.zip" "${PU_TEST_DIR}/src"
  assert_ok pu_stage_bundle "${PU_TEST_DIR}/bundle.zip"
  assert_contains "$POINTY_BUNDLE_DIR" 'pointy-onprem-1.1.0'
  assert_eq '1.1.0' "$POINTY_BUNDLE_VERSION"
  assert_dir "${POINTY_BUNDLE_DIR}/images"
}

test_staging_a_zip_records_where_to_clean_up_afterwards() {
  make_bundle "${PU_TEST_DIR}/src/pointy-onprem-1.1.0" 1.1.0
  _make_zip "${PU_TEST_DIR}/bundle.zip" "${PU_TEST_DIR}/src"
  pu_stage_bundle "${PU_TEST_DIR}/bundle.zip"
  assert_ne '' "${POINTY_BUNDLE_STAGING:-}" 'staging directory was not recorded for cleanup'
  assert_dir "$POINTY_BUNDLE_STAGING"
}

test_staging_handles_a_zip_whose_contents_are_at_the_root() {
  # Not how release.yml builds them, but it is how a re-zipped bundle from an
  # operator's machine usually comes out.
  make_bundle "${PU_TEST_DIR}/src" 1.1.0
  _make_zip "${PU_TEST_DIR}/flat.zip" "${PU_TEST_DIR}/src"
  assert_ok pu_stage_bundle "${PU_TEST_DIR}/flat.zip"
  assert_eq '1.1.0' "$POINTY_BUNDLE_VERSION"
  assert_dir "${POINTY_BUNDLE_DIR}/images"
}

test_staging_rejects_a_zip_that_is_not_a_bundle() {
  mkdir -p "${PU_TEST_DIR}/src"
  printf 'notes\n' >"${PU_TEST_DIR}/src/README.md"
  _make_zip "${PU_TEST_DIR}/junk.zip" "${PU_TEST_DIR}/src"
  local out; out="$(pu_stage_bundle "${PU_TEST_DIR}/junk.zip" 2>&1)"; local rc=$?
  assert_eq '1' "$rc"
  assert_contains "$out" 'not a Pointy bundle'
}

test_staging_rejects_a_corrupt_zip() {
  # A truncated download that somehow passed (or skipped) the sha256 check.
  printf 'this is not a zip file at all\n' >"${PU_TEST_DIR}/corrupt.zip"
  local out; out="$(pu_stage_bundle "${PU_TEST_DIR}/corrupt.zip" 2>&1)"; local rc=$?
  assert_eq '1' "$rc"
  assert_contains "$out" 'could not unzip bundle'
}

test_staging_fails_cleanly_when_unzip_is_not_installed() {
  # Documented in INSTALL.md as a prerequisite, but a minimal host image will
  # not have it, and the failure has to name the missing tool.
  stub_script date <<'EOF'
echo 2026-01-01T00:00:00
EOF
  printf 'x\n' >"${PU_TEST_DIR}/b.zip"
  local out rc
  out="$(PATH="$PU_STUB_DIR" pu_stage_bundle "${PU_TEST_DIR}/b.zip" 2>&1)"; rc=$?
  assert_eq '1' "$rc"
  assert_contains "$out" 'unzip not found on PATH'
}

test_staging_handles_a_bundle_path_containing_spaces() {
  # "/Volumes/USB DISK/pointy 1.1.0/" is an ordinary Tuesday.
  make_bundle "${PU_TEST_DIR}/USB DISK/pointy onprem 1.1.0" 1.1.0
  assert_ok pu_stage_bundle "${PU_TEST_DIR}/USB DISK/pointy onprem 1.1.0"
  assert_eq '1.1.0' "$POINTY_BUNDLE_VERSION"
}

test_staging_picks_one_release_directory_when_a_zip_holds_several() {
  # DOCUMENTED NON-DETERMINISM: `find | head -1` has no defined order, so a zip
  # carrying two releases installs an arbitrary one. Never produced by
  # release.yml; reachable if someone zips a folder of bundles together.
  make_bundle "${PU_TEST_DIR}/src/pointy-onprem-1.1.0" 1.1.0
  make_bundle "${PU_TEST_DIR}/src/pointy-onprem-1.2.0" 1.2.0
  _make_zip "${PU_TEST_DIR}/two.zip" "${PU_TEST_DIR}/src"
  assert_ok pu_stage_bundle "${PU_TEST_DIR}/two.zip"
  case "$POINTY_BUNDLE_VERSION" in
    1.1.0|1.2.0) ;;
    *) _fail "expected one of the two bundled versions, got [$POINTY_BUNDLE_VERSION]" ;;
  esac
}

pu_run_tests "$@"
