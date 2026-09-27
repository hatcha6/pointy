#!/usr/bin/env bash
#
# A full-restart update whose backend takes longer to boot than Docker's
# healthcheck is prepared to wait: heavy migrations on a shop's old machine.
#
# This is a failure from the field. `compose up -d` gave up on everything that
# waits for the backend ("dependency failed to start: container ...-backend-1
# is unhealthy") while the backend carried on migrating. install.sh died under
# `set -e` before it published the client installers, and update.sh took the
# exit for a broken release and rolled the shop back, killing the migration
# half way. A hand-run `compose up -d` minutes later always worked, because by
# then the backend had finished.
#
# A real migration needs ten minutes to outlast the shipped healthcheck window,
# so the shop's .env shrinks the window (POINTY_BACKEND_START_PERIOD) instead
# of the stand-in's boot growing: the same code path, in two minutes.
#
# The other half of the contract: a release that truly cannot boot must still
# fail, quickly rather than after the whole wait, and be rolled back.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. ./lib.sh
RIG_SCENARIO="09-restart-slow-boot"
rig_setup >/dev/null || exit 1
trap 'rig_teardown_shop' EXIT

SLOW="2.5.0-slow-migrations"

rig_step "installing a shop on 1.0.0, whose healthcheck gives up sooner than the next release boots"
rig_install_shop 1.0.0 || { rig_summary; exit 1; }
printf 'POINTY_BACKEND_START_PERIOD=5s\n' >>"${RIG_SHOP}/.env"

rig_step "a full-restart update to the slow release"
update_log="${RIG_RUN_DIR}/update-09-slow.log"
started="$(date +%s)"
( cd "$RIG_SHOP" && bash update.sh "$(rig_bundle_path "$SLOW")" --restart ) >"$update_log" 2>&1
update_rc=$?
rig_log "update finished in $(( $(date +%s) - started ))s (exit ${update_rc})"

rig_step "compose gave up on the backend, exactly as it did in the field"
rig_assert_contains "$(cat "$update_log")" "is unhealthy" \
  "compose called the still-booting backend unhealthy and stopped waiting"

rig_step "and the update waited it out instead of rolling back"
rig_assert_eq "0" "$update_rc" "update.sh reported success"
rig_assert_contains "$(cat "$update_log")" "The stack is up" "install.sh waited for the backend and converged"
rig_assert_not_contains "$(cat "$update_log")" "rolling back" "nothing was rolled back"
rig_assert_eq "$SLOW" "$(rig_served_version)" "the shop is serving the new release"
rig_assert_eq "$SLOW" "$(rig_installed_version)" "VERSION.txt records the new release"

rig_step "every step after the start ran"
for service in celery-worker celery-beat connector; do
  rig_assert_eq "true" "$(docker inspect -f '{{.State.Running}}' "$(rig_container_id "$service")" 2>/dev/null)" \
    "${service} is running (compose leaves it Created when it gives up)"
done
rig_assert_contains "$(rig_published_manifest)" "\"version\":\"${SLOW}\"" \
  "the new release's client installers were published for the tills"
rig_assert_contains "$(cat "$update_log")" "Done. Useful follow-ups" "install.sh ran to its end"

rig_teardown_shop

rig_step "a release that cannot boot at all, applied with a restart"
rig_install_shop 1.0.0 || { rig_summary; exit 1; }
update_log="${RIG_RUN_DIR}/update-09-crash.log"
started="$(date +%s)"
( cd "$RIG_SHOP" && bash update.sh "$(rig_bundle_path 2.1.0-crash-on-boot)" --restart ) >"$update_log" 2>&1
update_rc=$?
elapsed=$(( $(date +%s) - started ))
rig_log "the broken restart update gave up after ${elapsed}s"

rig_step "it still fails, fast, and the shop comes back on what it was running"
rig_assert_ne "0" "$update_rc" "update.sh reported the failure"
rig_assert_contains "$(cat "$update_log")" "keeps crashing" \
  "install.sh recognised a crash loop instead of waiting it out"
rig_assert_le "$elapsed" 300 "it gave up in minutes, not after the twenty-minute wait"
rig_wait_serving 60 >/dev/null
rig_assert_eq "1.0.0" "$(rig_served_version)" "the shop is serving 1.0.0 again"
rig_assert_eq "1.0.0" "$(rig_installed_version)" "VERSION.txt still says 1.0.0"
rig_assert_contains "$(rig_published_manifest)" '"version":"1.0.0"' \
  "the broken release's installers were never offered to the tills"

rig_summary
