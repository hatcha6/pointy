#!/usr/bin/env bash
#
# Run the on-prem update rehearsal: the real update engine, against real Docker,
# on a shop installed from a real release bundle.
#
#     bash deploy/onprem/tests/rehearsal/run-rehearsal.sh            # everything
#     bash .../run-rehearsal.sh rollback                             # matching
#     KEEP_SHOP=1 bash .../run-rehearsal.sh 01                       # leave it up
#
# Scenarios run one at a time on purpose. The standby container's name is fixed
# in update-lib.sh, so two rehearsals at once would fight over it — the same
# reason two updates cannot run on one shop, which is itself under test here.
set -uo pipefail
cd "$(dirname "$0")" || exit 1

. ./lib.sh

# `run-rehearsal.sh clean` reclaims everything the rig caches: the stand-in
# images, the built bundles, and any shop an interrupted run left behind. The
# cache is deliberate — it is what makes a re-run take seconds — but it should
# never be something you have to hunt down by hand.
if [ "${1:-}" = "clean" ]; then
  rig_sweep_leaked_shops
  for repo in pointy-backend pointy-relay pointy-web; do
    docker images "$repo" --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | while read -r tag; do
      docker image rm -f "$tag" >/dev/null 2>&1
    done
  done
  rm -rf "$RIG_CACHE" "${RIG_DIR}/root"
  printf 'Removed the rehearsal cache (%s), the stand-in images, and any leftover shops.\n' "$RIG_CACHE"
  exit 0
fi

filter="${1:-}"
scenarios=()
for f in scenarios/*.sh; do
  [ -f "$f" ] || continue
  if [ -n "$filter" ]; then
    case "$f" in *"$filter"*) ;; *) continue ;; esac
  fi
  scenarios+=("$f")
done
[ "${#scenarios[@]}" -gt 0 ] || { printf 'no scenarios matched %s\n' "${filter:-*}" >&2; exit 1; }

printf '==> Preparing the rehearsal (Docker, stand-in releases, bundles)…\n'
rig_setup || exit 1
rig_build_catalog || exit 1

passed=0; failed=0; failed_names=()
for scenario in "${scenarios[@]}"; do
  name="$(basename "$scenario" .sh)"
  printf '\n=====================================================\n'
  printf '### %s\n' "$name"
  printf '=====================================================\n'
  RIG_RUN_DIR="$RIG_RUN_DIR" bash "$scenario"
  if [ $? -eq 0 ]; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1)); failed_names+=("$name")
  fi
done

printf '\n=====================================================\n'
printf 'rehearsal: %d scenarios passed, %d failed\n' "$passed" "$failed"
[ "${#failed_names[@]}" -gt 0 ] && printf 'failing: %s\n' "${failed_names[*]}"
printf 'logs and shops: %s\n' "$RIG_RUN_DIR"
[ "$failed" -eq 0 ]
