#!/usr/bin/env bash
#
# make-update-bundle.sh — the zip the relay serves the fleet, derived from the
# full release bundle. What is pinned:
#
#   * it leaves out exactly what a running shop never uses to update (the WSL
#     installer and distro, the infrastructure images) and nothing else;
#   * what it keeps is byte-for-byte the full bundle's, under the same top-level
#     directory, so every updater applies it unmodified;
#   * a release build that would produce a useless update bundle fails there,
#     not on a shop.
. "$(dirname "$0")/harness.sh"

MAKE_UPDATE="${PU_ONPREM_DIR}/make-update-bundle.sh"

# _full_bundle <version> — a zip laid out like release.yml's full bundle.
_full_bundle() {
  local v="$1" src="${PU_TEST_DIR}/src" root
  root="${src}/pointy-onprem-${v}"
  make_bundle "$root" "$v"
  mv "${root}/images/pointy-backend.tar" "${root}/images/pointy-backend-${v}.tar"
  local f
  for f in postgres redis pgbouncer pointy-edge; do
    printf 'infra %s\n' "$f" >"${root}/images/${f}.tar"
  done
  printf 'msi\n' >"${root}/wsl/wsl.2.3.26.0.x64.msi"
  printf 'rootfs\n' >"${root}/wsl/pointy-wsl-rootfs.tar.gz"
  mkdir -p "${root}/clients"
  printf 'apk\n' >"${root}/clients/pointy-${v}-android-universal.apk"
  printf '{"version":"%s"}\n' "$v" >"${root}/clients/manifest.json"
  ( cd "$src" && zip -qr "${PU_TEST_DIR}/full.zip" . )
  rm -rf "$src"
}

_entries() { unzip -Z1 "$1" | sort; }

test_the_update_bundle_leaves_out_what_a_running_shop_never_uses() {
  _full_bundle 1.1.0
  assert_ok bash "$MAKE_UPDATE" "${PU_TEST_DIR}/full.zip" "${PU_TEST_DIR}/update.zip" >/dev/null
  local e; e="$(_entries "${PU_TEST_DIR}/update.zip")"
  local gone
  for gone in images/postgres.tar images/redis.tar images/pgbouncer.tar images/pointy-edge.tar \
              wsl/wsl.2.3.26.0.x64.msi wsl/pointy-wsl-rootfs.tar.gz; do
    assert_not_contains "$e" "pointy-onprem-1.1.0/${gone}"
  done
}

test_the_update_bundle_keeps_everything_an_update_uses() {
  _full_bundle 1.1.0
  bash "$MAKE_UPDATE" "${PU_TEST_DIR}/full.zip" "${PU_TEST_DIR}/update.zip" >/dev/null
  local full kept
  full="$(_entries "${PU_TEST_DIR}/full.zip" \
    | grep -vE '/images/(postgres|redis|pgbouncer|pointy-edge)\.tar$|\.msi$|rootfs\.tar\.gz$')"
  kept="$(_entries "${PU_TEST_DIR}/update.zip")"
  assert_eq "$full" "$kept" 'exactly the install-only entries may go'
  assert_contains "$kept" 'pointy-onprem-1.1.0/wsl/keep-pointy-running.ps1'
  assert_contains "$kept" 'pointy-onprem-1.1.0/clients/manifest.json'
}

test_what_the_update_bundle_keeps_is_byte_for_byte_the_full_bundles() {
  _full_bundle 1.1.0
  bash "$MAKE_UPDATE" "${PU_TEST_DIR}/full.zip" "${PU_TEST_DIR}/update.zip" >/dev/null
  mkdir -p a b
  unzip -q "${PU_TEST_DIR}/full.zip" -d a
  unzip -q "${PU_TEST_DIR}/update.zip" -d b
  local f
  while IFS= read -r f; do
    assert_eq "$(cat "a/$f")" "$(cat "b/$f")" "entry $f differs"
  done < <(cd b && find . -type f)
}

test_a_release_that_bumps_an_infra_image_can_keep_its_archive() {
  _full_bundle 1.1.0
  local out
  out="$(bash "$MAKE_UPDATE" --keep images/pointy-edge.tar \
          "${PU_TEST_DIR}/full.zip" "${PU_TEST_DIR}/update.zip")"
  assert_contains "$(_entries "${PU_TEST_DIR}/update.zip")" 'pointy-onprem-1.1.0/images/pointy-edge.tar'
  assert_not_contains "$(_entries "${PU_TEST_DIR}/update.zip")" 'pointy-onprem-1.1.0/images/postgres.tar'
  assert_contains "$out" 'kept     images/pointy-edge.tar'
}

test_the_update_bundle_is_accepted_by_the_updater() {
  _full_bundle 1.1.0
  bash "$MAKE_UPDATE" "${PU_TEST_DIR}/full.zip" "${PU_TEST_DIR}/update.zip" >/dev/null
  installed_deploy 1.0.0
  assert_ok pu_stage_bundle "${PU_TEST_DIR}/update.zip"
  assert_eq '1.1.0' "$POINTY_BUNDLE_VERSION"
  # Docker (stubbed) has every infrastructure image, as a running shop does.
  assert_eq '' "$(pu_missing_infra_images "$POINTY_BUNDLE_DIR")"
}

test_a_shop_without_an_infra_image_is_told_what_is_missing() {
  _full_bundle 1.1.0
  bash "$MAKE_UPDATE" "${PU_TEST_DIR}/full.zip" "${PU_TEST_DIR}/update.zip" >/dev/null
  installed_deploy 1.0.0
  printf 'POINTY_EDGE_IMAGE=pointy-edge:2\n' >>.env
  stub_rule docker 'image inspect pointy-edge:2' 1
  pu_stage_bundle "${PU_TEST_DIR}/update.zip"
  assert_eq 'pointy-edge:2' "$(pu_missing_infra_images "$POINTY_BUNDLE_DIR")"
  # The full bundle carries it, so the full bundle is the answer.
  pu_stage_bundle "${PU_TEST_DIR}/full.zip"
  assert_eq '' "$(pu_missing_infra_images "$POINTY_BUNDLE_DIR")"
}

test_the_update_bundle_is_smaller() {
  _full_bundle 1.1.0
  # Make the install-only pieces weigh what they do in a real bundle.
  mkdir -p big/pointy-onprem-1.1.0/wsl
  head -c 200000 /dev/urandom >big/pointy-onprem-1.1.0/wsl/pointy-wsl-rootfs.tar.gz
  ( cd big && zip -q -g "${PU_TEST_DIR}/full.zip" pointy-onprem-1.1.0/wsl/pointy-wsl-rootfs.tar.gz )
  bash "$MAKE_UPDATE" "${PU_TEST_DIR}/full.zip" "${PU_TEST_DIR}/update.zip" >/dev/null
  local full update
  full="$(wc -c <"${PU_TEST_DIR}/full.zip")"; update="$(wc -c <"${PU_TEST_DIR}/update.zip")"
  [ "$update" -lt $(( full - 150000 )) ] || _fail "update bundle is not smaller" "full=$full update=$update"
}

test_an_older_bundle_without_infra_archives_is_passed_through() {
  _full_bundle 1.1.0
  zip -q -d "${PU_TEST_DIR}/full.zip" 'pointy-onprem-1.1.0/images/postgres.tar' \
    'pointy-onprem-1.1.0/images/redis.tar' 'pointy-onprem-1.1.0/images/pgbouncer.tar' \
    'pointy-onprem-1.1.0/images/pointy-edge.tar' 'pointy-onprem-1.1.0/wsl/wsl.2.3.26.0.x64.msi' \
    'pointy-onprem-1.1.0/wsl/pointy-wsl-rootfs.tar.gz'
  assert_ok bash "$MAKE_UPDATE" "${PU_TEST_DIR}/full.zip" "${PU_TEST_DIR}/update.zip" >/dev/null
  assert_eq "$(_entries "${PU_TEST_DIR}/full.zip")" "$(_entries "${PU_TEST_DIR}/update.zip")"
}

test_a_zip_that_is_not_a_release_bundle_is_refused() {
  mkdir -p src/other && printf 'x\n' >src/other/file
  ( cd src && zip -qr "${PU_TEST_DIR}/full.zip" . )
  local out; out="$(bash "$MAKE_UPDATE" "${PU_TEST_DIR}/full.zip" "${PU_TEST_DIR}/update.zip" 2>&1)"; local rc=$?
  assert_eq '1' "$rc"
  assert_contains "$out" 'is not a release bundle'
  assert_no_file "${PU_TEST_DIR}/update.zip"
}

test_a_bundle_with_no_backend_image_fails_the_build() {
  _full_bundle 1.1.0
  zip -q -d "${PU_TEST_DIR}/full.zip" 'pointy-onprem-1.1.0/images/pointy-backend-1.1.0.tar'
  local out; out="$(bash "$MAKE_UPDATE" "${PU_TEST_DIR}/full.zip" "${PU_TEST_DIR}/update.zip" 2>&1)"; local rc=$?
  assert_eq '1' "$rc"
  assert_contains "$out" 'no backend image'
  assert_no_file "${PU_TEST_DIR}/update.zip"
}

test_a_bundle_missing_the_update_agent_fails_the_build() {
  _full_bundle 1.1.0
  zip -q -d "${PU_TEST_DIR}/full.zip" 'pointy-onprem-1.1.0/update-agent.sh'
  local out; out="$(bash "$MAKE_UPDATE" "${PU_TEST_DIR}/full.zip" "${PU_TEST_DIR}/update.zip" 2>&1)"; local rc=$?
  assert_eq '1' "$rc"
  assert_contains "$out" 'no update-agent.sh'
}

pu_run_tests "$@"
