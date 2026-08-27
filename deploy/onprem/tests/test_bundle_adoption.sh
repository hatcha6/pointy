#!/usr/bin/env bash
#
# Taking a release bundle over a live deployment: which files are replaced,
# which are state and must survive, and how the new images get pinned.
. "$(dirname "$0")/harness.sh"

UPSTREAM='edge/active/upstream.conf'

# ---------------------------------------------------------------------------
# pu_install_file — replace by atomic rename, never in place
# ---------------------------------------------------------------------------

test_install_file_replaces_the_destination() {
  printf 'new contents\n' >src
  printf 'old contents\n' >dest
  assert_ok pu_install_file src dest
  assert_file_eq dest 'new contents'
}

test_install_file_creates_a_destination_that_did_not_exist() {
  printf 'new\n' >src
  assert_ok pu_install_file src brand-new
  assert_file_eq brand-new 'new'
}

test_install_file_leaves_the_old_inode_intact() {
  # THE REASON THIS FUNCTION EXISTS. update.sh and update-agent.sh replace
  # THEMSELVES while running. bash reads a script lazily from its open inode, so
  # overwriting that inode in place makes the running shell start executing the
  # new file from a stale byte offset — arbitrary half-lines of a different
  # script. A rename leaves the running process on the old inode.
  printf 'old script\n' >dest
  ln dest still-open-by-the-running-shell
  printf 'new script\n' >src
  pu_install_file src dest
  assert_file_eq dest 'new script'
  assert_file_eq still-open-by-the-running-shell 'old script'
}

test_install_file_leaves_no_partial_file_behind() {
  printf 'new\n' >src
  pu_install_file src dest
  assert_no_file dest.pointy-new
}

test_install_file_fails_and_changes_nothing_when_the_source_is_missing() {
  printf 'original\n' >dest
  assert_fail eval 'pu_install_file no-such-source dest 2>/dev/null'
  assert_file_eq dest 'original'
  assert_no_file dest.pointy-new
}

# ---------------------------------------------------------------------------
# pu_bundle_strategy — what the release itself asks for
# ---------------------------------------------------------------------------

test_strategy_is_live_when_the_bundle_says_nothing() {
  mkdir -p bundle
  assert_eq 'live' "$(pu_bundle_strategy bundle)"
}

test_strategy_is_restart_when_the_release_demands_it() {
  mkdir -p bundle
  printf 'restart\n' >bundle/UPDATE_STRATEGY.txt
  assert_eq 'restart' "$(pu_bundle_strategy bundle)"
}

test_strategy_accepts_the_downtime_and_offline_spellings() {
  mkdir -p bundle
  printf 'downtime\n' >bundle/UPDATE_STRATEGY.txt
  assert_eq 'restart' "$(pu_bundle_strategy bundle)"
  printf 'offline\n' >bundle/UPDATE_STRATEGY.txt
  assert_eq 'restart' "$(pu_bundle_strategy bundle)"
}

test_strategy_ignores_case_and_surrounding_whitespace() {
  mkdir -p bundle
  printf '  RESTART  \n\n' >bundle/UPDATE_STRATEGY.txt
  assert_eq 'restart' "$(pu_bundle_strategy bundle)"
}

test_strategy_tolerates_crlf_from_a_windows_built_bundle() {
  mkdir -p bundle
  printf 'restart\r\n' >bundle/UPDATE_STRATEGY.txt
  assert_eq 'restart' "$(pu_bundle_strategy bundle)"
}

test_strategy_is_live_for_an_empty_marker_file() {
  mkdir -p bundle
  : >bundle/UPDATE_STRATEGY.txt
  assert_eq 'live' "$(pu_bundle_strategy bundle)"
}

test_strategy_falls_back_to_live_for_an_unrecognised_word() {
  # DOCUMENTED SHARP EDGE: this fails OPEN, toward the live path. A release that
  # genuinely cannot be applied live but whose marker is misspelled ("restrt",
  # "Restart Required") gets a live update and runs its incompatible migrations
  # under the previous version. The safer default would be to fail closed to a
  # restart — a needless restart costs a shop a minute, a wrong live update can
  # cost it its data.
  mkdir -p bundle
  printf 'restrt\n' >bundle/UPDATE_STRATEGY.txt
  assert_eq 'live' "$(pu_bundle_strategy bundle)"
  printf 'restart required\n' >bundle/UPDATE_STRATEGY.txt
  assert_eq 'live' "$(pu_bundle_strategy bundle)"
}

# ---------------------------------------------------------------------------
# pu_adopt_bundle — what is replaced and what is state
# ---------------------------------------------------------------------------

test_adopt_replaces_the_scripts_the_bundle_ships() {
  installed_deploy 1.0.0
  make_bundle "${PU_TEST_DIR}/b" 1.1.0
  pu_adopt_bundle "${PU_TEST_DIR}/b" 1.1.0
  assert_file_contains docker-compose.yml 'from 1.1.0'
  assert_file_contains install.sh 'from 1.1.0'
  assert_file_contains watchdog.sh 'from 1.1.0'
  assert_file_contains update-lib.sh 'from 1.1.0'
  assert_file_contains update-agent.sh 'from 1.1.0'
}

test_adopt_never_overwrites_the_shops_env() {
  # .env holds this shop's database password, its relay tokens and its port
  # bindings. Replacing it with the bundle's example would end the shop.
  installed_deploy 1.0.0
  printf 'POSTGRES_PASSWORD=this-shops-secret\n' >>.env
  make_bundle "${PU_TEST_DIR}/b" 1.1.0
  pu_adopt_bundle "${PU_TEST_DIR}/b" 1.1.0
  assert_file_contains .env 'this-shops-secret'
  # ...but .env.example, which is documentation, IS adopted.
  assert_file_contains .env.example 'from 1.1.0'
}

test_adopt_preserves_state_directories() {
  installed_deploy 1.0.0
  mkdir -p backups pgdata
  printf 'last nights dump\n' >backups/pre-update-0.9.0-to-1.0.0.sql
  printf 'database\n' >pgdata/PG_VERSION
  make_bundle "${PU_TEST_DIR}/b" 1.1.0
  pu_adopt_bundle "${PU_TEST_DIR}/b" 1.1.0
  assert_file_contains backups/pre-update-0.9.0-to-1.0.0.sql 'last nights dump'
  assert_file_contains pgdata/PG_VERSION 'database'
}

test_adopt_leaves_an_existing_front_door_pointer_alone() {
  # Which backend is live is STATE. If an update reset it, a bundle adopted
  # mid-flip would silently send traffic back to a container that is being torn
  # down.
  installed_deploy 1.0.0
  mkdir -p edge/active
  printf 'set $pointy_upstream      "http://pointy-backend-standby:8000";\nset $pointy_upstream_name "pointy-backend-standby";\n' >"$UPSTREAM"
  make_bundle "${PU_TEST_DIR}/b" 1.1.0
  pu_adopt_bundle "${PU_TEST_DIR}/b" 1.1.0
  assert_file_contains "$UPSTREAM" 'pointy-backend-standby'
}

test_adopt_writes_a_default_pointer_when_the_deployment_has_none() {
  installed_deploy 1.0.0
  rm -rf edge
  make_bundle "${PU_TEST_DIR}/b" 1.1.0
  pu_adopt_bundle "${PU_TEST_DIR}/b" 1.1.0
  assert_file_contains "$UPSTREAM" 'set $pointy_upstream_name "backend";'
}

test_adopt_creates_the_wsl_subdirectory_for_an_older_deployment() {
  # A shop installed before the Windows bridge script existed has no wsl/. If
  # updates could not create it, no fix to the LAN bridge could ever reach that
  # shop.
  installed_deploy 1.0.0
  rm -rf wsl
  make_bundle "${PU_TEST_DIR}/b" 1.1.0
  pu_adopt_bundle "${PU_TEST_DIR}/b" 1.1.0
  assert_file_contains wsl/bootstrap-wsl.ps1 'from 1.1.0'
  assert_file_contains wsl/timezone-map.txt 'from 1.1.0'
}

test_adopt_skips_files_the_bundle_does_not_carry() {
  installed_deploy 1.0.0
  printf 'local customisation\n' >fix-backend-outages.sh
  make_bundle "${PU_TEST_DIR}/b" 1.1.0
  rm "${PU_TEST_DIR}/b/fix-backend-outages.sh"
  pu_adopt_bundle "${PU_TEST_DIR}/b" 1.1.0
  assert_file_contains fix-backend-outages.sh 'local customisation'
}

test_adopt_copies_only_the_listed_files() {
  installed_deploy 1.0.0
  make_bundle "${PU_TEST_DIR}/b" 1.1.0
  printf 'not part of a deployment\n' >"${PU_TEST_DIR}/b/RELEASE_NOTES.md"
  printf 'secrets\n' >"${PU_TEST_DIR}/b/.env"
  pu_adopt_bundle "${PU_TEST_DIR}/b" 1.1.0
  assert_no_file RELEASE_NOTES.md
  assert_file_lacks .env 'secrets'
}

test_adopt_makes_the_adopted_scripts_executable() {
  installed_deploy 1.0.0
  make_bundle "${PU_TEST_DIR}/b" 1.1.0
  chmod -x "${PU_TEST_DIR}/b"/*.sh
  pu_adopt_bundle "${PU_TEST_DIR}/b" 1.1.0
  [ -x install.sh ] || _fail 'install.sh is not executable after adoption'
  [ -x update-agent.sh ] || _fail 'update-agent.sh is not executable after adoption'
}

test_adopt_replaces_the_image_directory_wholesale() {
  # Stale tars from the previous release must not linger: pu_load_images globs
  # images/*.tar and would happily load last release's backend over the new one.
  installed_deploy 1.0.0
  printf 'stale\n' >images/pointy-backend-OLD.tar
  make_bundle "${PU_TEST_DIR}/b" 1.1.0
  pu_adopt_bundle "${PU_TEST_DIR}/b" 1.1.0
  assert_no_file images/pointy-backend-OLD.tar
  assert_file_contains images/pointy-backend.tar 'fake backend image 1.1.0'
}

test_adopt_replaces_client_installers_when_the_bundle_has_them() {
  installed_deploy 1.0.0
  mkdir -p clients
  printf 'old installer\n' >clients/pointy-windows.exe
  make_bundle "${PU_TEST_DIR}/b" 1.1.0
  mkdir -p "${PU_TEST_DIR}/b/clients"
  printf 'new installer\n' >"${PU_TEST_DIR}/b/clients/pointy-windows.exe"
  pu_adopt_bundle "${PU_TEST_DIR}/b" 1.1.0
  assert_file_contains clients/pointy-windows.exe 'new installer'
}

test_adopt_keeps_existing_client_installers_when_the_bundle_has_none() {
  installed_deploy 1.0.0
  mkdir -p clients
  printf 'old installer\n' >clients/pointy-windows.exe
  make_bundle "${PU_TEST_DIR}/b" 1.1.0
  pu_adopt_bundle "${PU_TEST_DIR}/b" 1.1.0
  assert_file_contains clients/pointy-windows.exe 'old installer'
}

# ---------------------------------------------------------------------------
# Pinning the new image tags into .env
# ---------------------------------------------------------------------------

test_adopt_pins_the_three_application_images() {
  installed_deploy 1.0.0
  make_bundle "${PU_TEST_DIR}/b" 1.1.0
  pu_adopt_bundle "${PU_TEST_DIR}/b" 1.1.0
  assert_file_contains .env 'POINTY_BACKEND_IMAGE=pointy-backend:1.1.0'
  assert_file_contains .env 'POINTY_RELAY_IMAGE=pointy-relay:1.1.0'
  assert_file_contains .env 'POINTY_WEB_IMAGE=pointy-web:1.1.0'
}

test_adopt_does_not_pin_infrastructure_images() {
  # Postgres, Redis, PgBouncer and the front door are never recreated live;
  # repinning them would give the next `compose up` a reason to.
  installed_deploy 1.0.0
  printf 'POINTY_POSTGRES_IMAGE=postgres:17\nPOINTY_EDGE_IMAGE=pointy-edge:3\n' >>.env
  make_bundle "${PU_TEST_DIR}/b" 1.1.0
  pu_adopt_bundle "${PU_TEST_DIR}/b" 1.1.0
  assert_file_contains .env 'POINTY_POSTGRES_IMAGE=postgres:17'
  assert_file_contains .env 'POINTY_EDGE_IMAGE=pointy-edge:3'
}

test_adopt_removes_the_sed_backup_file() {
  installed_deploy 1.0.0
  make_bundle "${PU_TEST_DIR}/b" 1.1.0
  pu_adopt_bundle "${PU_TEST_DIR}/b" 1.1.0
  assert_no_file .env.bak
}

test_adopt_leaves_other_env_keys_untouched() {
  installed_deploy 1.0.0
  printf 'POSTGRES_PASSWORD=hunter2\nPOINTY_BACKEND_PORT=18000\n' >>.env
  local before_lines; before_lines="$(wc -l <.env)"
  make_bundle "${PU_TEST_DIR}/b" 1.1.0
  pu_adopt_bundle "${PU_TEST_DIR}/b" 1.1.0
  assert_file_contains .env 'POSTGRES_PASSWORD=hunter2'
  assert_file_contains .env 'POINTY_BACKEND_PORT=18000'
  assert_eq "$before_lines" "$(wc -l <.env)" 'adoption changed the number of lines in .env'
}

test_pinning_silently_does_nothing_when_env_lacks_the_image_keys() {
  # NASTY AND REACHABLE. The pin is `sed s|^POINTY_BACKEND_IMAGE=.*|...|`, which
  # substitutes only if the line already exists. A deployment whose .env predates
  # those keys (or where someone tidied them away) gets NO pin, `compose up`
  # resolves whatever the compose default is, and the update reports success
  # while the shop keeps running the old image. Nothing downstream notices,
  # because /readyz answers perfectly well — from the wrong version.
  installed_deploy 1.0.0
  write_env 'POSTGRES_USER=pointy' 'POINTY_BACKEND_PORT=8000'
  make_bundle "${PU_TEST_DIR}/b" 1.1.0
  pu_adopt_bundle "${PU_TEST_DIR}/b" 1.1.0
  assert_file_lacks .env 'POINTY_BACKEND_IMAGE'
}

test_pinning_survives_a_version_containing_a_sed_delimiter() {
  # The pin uses `|` as its sed delimiter. A version string containing one would
  # make sed reject the expression; with `set -uo pipefail` and no `-e` the
  # failure is swallowed and .env is left unpinned. Pinned as a test so that if
  # the relay ever starts accepting looser version strings, this fails loudly
  # instead of shipping a silent no-op update.
  installed_deploy 1.0.0
  make_bundle "${PU_TEST_DIR}/b" 'weird'
  pu_adopt_bundle "${PU_TEST_DIR}/b" '1.1.0|rm -rf' 2>/dev/null
  # Whatever happens, the one thing that must never happen is a corrupted .env
  # that no longer holds this shop's credentials.
  assert_file_contains .env 'POSTGRES_USER=pointy'
  assert_no_file .env.bak
}

test_pinning_treats_an_ampersand_in_a_version_literally_or_not_at_all() {
  # In a sed REPLACEMENT, an unescaped `&` expands to the whole matched line.
  # A version of "1.1.0&x" would therefore produce
  # POINTY_BACKEND_IMAGE=pointy-backend:1.1.0POINTY_BACKEND_IMAGE=pointy-backend:1.0.0x
  # — a tag no image has, so `compose up` fails and the update rolls back. Noisy
  # rather than dangerous, but it is a version string reaching sed unescaped and
  # it is worth knowing which of the two it is.
  installed_deploy 1.0.0
  make_bundle "${PU_TEST_DIR}/b" 'weird'
  pu_adopt_bundle "${PU_TEST_DIR}/b" '1.1.0&x' 2>/dev/null
  local pinned; pinned="$(grep '^POINTY_BACKEND_IMAGE=' .env)"
  # Pinned exactly: the `&` DID expand to the whole matched line.
  assert_eq 'POINTY_BACKEND_IMAGE=pointy-backend:1.1.0POINTY_BACKEND_IMAGE=pointy-backend:1.0.0x' \
    "$pinned" 'sed & handling changed — re-read the note above before updating this'
  assert_file_contains .env 'POSTGRES_USER=pointy'
}

pu_run_tests "$@"
