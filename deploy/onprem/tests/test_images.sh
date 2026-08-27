#!/usr/bin/env bash
#
# Image archives: which ones a live update is allowed to load, and the rule that
# an application tar is destroyed the moment Docker has taken it.
. "$(dirname "$0")/harness.sh"

# A `shred` that really unlinks, so the success branch is observable.
_working_shred() {
  stub_script shred <<'EOF'
for a in "$@"; do case "$a" in -*) ;; *) rm -f "$a" ;; esac; done
exit 0
EOF
}
_broken_shred() { stub_script shred <<'EOF'
exit 1
EOF
}

_bundle_images() {
  mkdir -p images
  printf 'backend\n' >images/pointy-backend.tar
  printf 'relay\n'   >images/pointy-relay.tar
  printf 'web\n'     >images/pointy-web.tar
  printf 'edge\n'    >images/pointy-edge.tar
  printf 'pg\n'      >images/postgres.tar
  printf 'redis\n'   >images/redis.tar
}

# ---------------------------------------------------------------------------
# pu_keep_image_archives
# ---------------------------------------------------------------------------

test_archives_are_shredded_by_default() {
  default_env
  assert_fail pu_keep_image_archives
}

test_keep_flag_is_honoured_from_the_environment() {
  default_env
  POINTY_KEEP_IMAGE_ARCHIVES=1 assert_ok pu_keep_image_archives
}

test_keep_flag_is_honoured_from_env_file() {
  write_env 'POINTY_KEEP_IMAGE_ARCHIVES=true'
  assert_ok pu_keep_image_archives
}

test_keep_flag_accepts_the_usual_spellings() {
  local value
  for value in 1 true TRUE yes YES; do
    write_env "POINTY_KEEP_IMAGE_ARCHIVES=${value}"
    assert_ok pu_keep_image_archives
  done
}

test_keep_flag_rejects_negative_spellings() {
  local value
  for value in 0 false no off ''; do
    write_env "POINTY_KEEP_IMAGE_ARCHIVES=${value}"
    assert_fail pu_keep_image_archives
  done
}

test_environment_overrides_the_env_file() {
  write_env 'POINTY_KEEP_IMAGE_ARCHIVES=0'
  POINTY_KEEP_IMAGE_ARCHIVES=1 assert_ok pu_keep_image_archives
}

# ---------------------------------------------------------------------------
# pu_shred_file
# ---------------------------------------------------------------------------

test_shred_file_overwrites_then_unlinks() {
  _working_shred
  printf 'source code\n' >secret.tar
  assert_ok pu_shred_file secret.tar
  assert_no_file secret.tar
  assert_called shred '-n 1 -u secret.tar'
}

test_shred_file_falls_back_to_rm_when_shred_cannot_run() {
  # Not every host has a working shred (and it is meaningless on some
  # filesystems). The file must still go.
  _broken_shred
  printf 'source code\n' >secret.tar
  assert_ok pu_shred_file secret.tar
  assert_no_file secret.tar
}

test_shred_file_is_a_no_op_for_a_missing_file() {
  _working_shred
  assert_ok pu_shred_file not-there.tar
  assert_not_called shred '*not-there.tar*'
}

# ---------------------------------------------------------------------------
# pu_shred_staged_archives — the extracted copy of a bundle holds the same tars
# ---------------------------------------------------------------------------

test_staged_archives_are_shredded_recursively() {
  _working_shred
  default_env
  mkdir -p staging/pointy-onprem-1.1.0/images
  printf 'x\n' >staging/bundle.zip
  printf 'x\n' >staging/pointy-onprem-1.1.0/images/pointy-backend.tar
  printf 'x\n' >staging/pointy-onprem-1.1.0/images/pointy-web.tar
  pu_shred_staged_archives staging
  assert_no_file staging/bundle.zip
  assert_no_file staging/pointy-onprem-1.1.0/images/pointy-backend.tar
  assert_no_file staging/pointy-onprem-1.1.0/images/pointy-web.tar
}

test_staged_third_party_archives_are_left_alone() {
  # None of our code is in them and they are what the next maintenance restart
  # loads; shredding them would cost a shop its offline reinstall.
  _working_shred
  default_env
  mkdir -p staging/images
  printf 'x\n' >staging/images/postgres.tar
  printf 'x\n' >staging/images/pointy-backend.tar
  pu_shred_staged_archives staging
  assert_file staging/images/postgres.tar
  assert_no_file staging/images/pointy-backend.tar
}

test_staged_archives_survive_when_the_operator_asked_to_keep_them() {
  _working_shred
  write_env 'POINTY_KEEP_IMAGE_ARCHIVES=1'
  mkdir -p staging
  printf 'x\n' >staging/pointy-backend.tar
  pu_shred_staged_archives staging
  assert_file staging/pointy-backend.tar
  assert_not_called shred '*'
}

test_shredding_a_missing_directory_is_harmless() {
  _working_shred
  default_env
  assert_ok pu_shred_staged_archives no-such-staging
}

test_staged_archives_with_spaces_in_the_path_are_still_shredded() {
  # `unzip -d` into a mktemp dir is safe, but an operator running update.sh
  # against "/Volumes/USB DISK/pointy 1.1.0/" is not hypothetical.
  _working_shred
  default_env
  mkdir -p "staging/pointy onprem 1.1.0/images"
  printf 'x\n' >"staging/pointy onprem 1.1.0/images/pointy-backend.tar"
  pu_shred_staged_archives staging
  assert_no_file "staging/pointy onprem 1.1.0/images/pointy-backend.tar"
}

# ---------------------------------------------------------------------------
# pu_load_images
# ---------------------------------------------------------------------------

test_live_load_takes_only_the_application_images() {
  _working_shred
  default_env
  _bundle_images
  assert_ok pu_load_images live
  assert_called docker 'load -i images/pointy-backend.tar'
  assert_called docker 'load -i images/pointy-relay.tar'
  assert_called docker 'load -i images/pointy-web.tar'
}

test_live_load_never_touches_the_front_door_image() {
  # Loading a new pointy-edge would change what the compose file resolves to and
  # hand the next `compose up` a reason to recreate the container holding the
  # LAN port — precisely the outage a live update exists to avoid.
  _working_shred
  default_env
  _bundle_images
  pu_load_images live
  assert_not_called docker '*pointy-edge.tar*'
  assert_file images/pointy-edge.tar
}

test_live_load_never_touches_infrastructure_images() {
  _working_shred
  default_env
  _bundle_images
  pu_load_images live
  assert_not_called docker '*postgres.tar*'
  assert_not_called docker '*redis.tar*'
  assert_file images/postgres.tar
  assert_file images/redis.tar
}

test_restart_load_takes_everything() {
  _working_shred
  default_env
  _bundle_images
  assert_ok pu_load_images restart
  assert_called docker 'load -i images/pointy-backend.tar'
  assert_called docker 'load -i images/pointy-edge.tar'
  assert_called docker 'load -i images/postgres.tar'
  assert_called docker 'load -i images/redis.tar'
}

test_loaded_application_archives_are_shredded_immediately() {
  _working_shred
  default_env
  _bundle_images
  pu_load_images live
  assert_no_file images/pointy-backend.tar
  assert_no_file images/pointy-relay.tar
  assert_no_file images/pointy-web.tar
}

test_loaded_archives_are_kept_when_the_operator_asked() {
  _working_shred
  write_env 'POINTY_KEEP_IMAGE_ARCHIVES=1'
  _bundle_images
  pu_load_images live
  assert_file images/pointy-backend.tar
  assert_not_called shred '*'
}

test_load_fails_when_there_is_no_image_directory() {
  default_env
  local out; out="$(pu_load_images live 2>&1)"; local rc=$?
  assert_eq '1' "$rc"
  assert_contains "$out" 'no image archives under ./images'
}

test_load_fails_when_the_image_directory_is_empty() {
  default_env
  mkdir -p images
  local out; out="$(pu_load_images live 2>&1)"; local rc=$?
  assert_eq '1' "$rc"
  assert_contains "$out" 'no image archives under ./images'
}

test_live_load_fails_when_the_bundle_carries_only_infrastructure() {
  # A malformed release that shipped no application tars must NOT be treated as
  # a successful load — the update would otherwise proceed to flip traffic to a
  # backend that is still on the old image.
  _working_shred
  default_env
  mkdir -p images
  printf 'pg\n' >images/postgres.tar
  printf 'edge\n' >images/pointy-edge.tar
  local out; out="$(pu_load_images live 2>&1)"; local rc=$?
  assert_eq '1' "$rc"
  assert_contains "$out" 'no application images found'
}

test_load_stops_at_the_first_docker_failure() {
  # A truncated download, a corrupt tar, a full disk. Carrying on would leave
  # the stack with a mixed set of versions.
  _working_shred
  default_env
  _bundle_images
  stub_rule docker 'load -i images/pointy-relay.tar' 1
  assert_fail pu_load_images live
  assert_not_called docker 'load -i images/pointy-web.tar'
}

test_a_failed_load_does_not_destroy_the_archive() {
  # The archive is the only copy; shredding one Docker refused would make the
  # failure unrecoverable without re-downloading the whole bundle.
  _working_shred
  default_env
  _bundle_images
  stub_rule docker 'load -i images/pointy-backend.tar' 1
  pu_load_images live
  assert_file images/pointy-backend.tar
}

# ---------------------------------------------------------------------------
# pu_report_staged_infra
# ---------------------------------------------------------------------------

test_staged_infrastructure_is_reported_to_the_operator() {
  default_env
  mkdir -p images
  printf 'x\n' >images/postgres.tar
  printf 'x\n' >images/redis.tar
  printf 'x\n' >images/pointy-edge.tar
  local out; out="$(pu_report_staged_infra 2>&1)"
  assert_contains "$out" 'staged for the next maintenance restart'
  assert_contains "$out" 'postgres'
  assert_contains "$out" 'redis'
  assert_contains "$out" 'pointy-edge'
}

test_application_images_are_not_reported_as_staged() {
  default_env
  mkdir -p images
  printf 'x\n' >images/pointy-backend.tar
  printf 'x\n' >images/postgres.tar
  local out; out="$(pu_report_staged_infra 2>&1)"
  assert_not_contains "$out" 'pointy-backend'
}

test_nothing_is_reported_when_no_infrastructure_is_staged() {
  default_env
  mkdir -p images
  printf 'x\n' >images/pointy-backend.tar
  assert_eq '' "$(pu_report_staged_infra 2>&1)"
}

# ---------------------------------------------------------------------------
# pu_prune_superseded_images
# ---------------------------------------------------------------------------

test_prune_removes_the_previous_releases_application_images() {
  local out; out="$(pu_prune_superseded_images 1.0.0 1.1.0 2>&1)"
  assert_called docker 'image rm pointy-backend:1.0.0'
  assert_called docker 'image rm pointy-relay:1.0.0'
  assert_called docker 'image rm pointy-web:1.0.0'
  assert_contains "$out" 'removed the superseded image pointy-backend:1.0.0'
}

test_prune_never_removes_the_front_door_image() {
  # pointy-edge's tag is hand-bumped and shared across releases; the front door
  # keeps running on it right through a live update.
  pu_prune_superseded_images 1.0.0 1.1.0
  assert_not_called docker '*pointy-edge*'
}

test_prune_never_forces() {
  # `docker image rm` without -f refuses an image a container still holds, which
  # is exactly the guard wanted: if something is still pointed at the old
  # release, its image must survive.
  pu_prune_superseded_images 1.0.0 1.1.0
  assert_not_called docker 'image rm -f *'
}

test_prune_does_nothing_on_a_deployment_of_unknown_version() {
  pu_prune_superseded_images unknown 1.1.0
  assert_eq '0' "$(count_calls docker)"
}

test_prune_does_nothing_when_the_version_is_empty() {
  pu_prune_superseded_images '' 1.1.0
  assert_eq '0' "$(count_calls docker)"
}

test_prune_does_nothing_when_re_applying_the_same_version() {
  # `update.sh --force` re-applies the installed version; pruning "the previous"
  # release would delete the images the shop is running right now.
  pu_prune_superseded_images 1.1.0 1.1.0
  assert_eq '0' "$(count_calls docker)"
}

test_prune_skips_images_that_are_not_present() {
  stub_rule docker 'image inspect pointy-relay:1.0.0' 1
  pu_prune_superseded_images 1.0.0 1.1.0
  assert_not_called docker 'image rm pointy-relay:1.0.0'
  assert_called docker 'image rm pointy-backend:1.0.0'
}

test_prune_keeps_an_image_a_container_still_uses_and_carries_on() {
  stub_rule docker 'image rm pointy-backend:1.0.0' 1
  local out; out="$(pu_prune_superseded_images 1.0.0 1.1.0 2>&1)"
  assert_contains "$out" 'kept pointy-backend:1.0.0 (a container still uses it)'
  # A refusal must not abort the sweep.
  assert_called docker 'image rm pointy-web:1.0.0'
}

test_prune_succeeds_even_when_every_removal_is_refused() {
  stub_rule docker 'image rm *' 1
  assert_ok pu_prune_superseded_images 1.0.0 1.1.0
}

pu_run_tests "$@"
