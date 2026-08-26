#!/usr/bin/env bash
#
# Run the on-prem update engine's unit tests.
#
#     bash deploy/onprem/tests/run-tests.sh              # everything
#     bash deploy/onprem/tests/run-tests.sh upstream     # only suites matching
#     TEST_FILTER=stale bash .../run-tests.sh            # only tests matching
#     TEST_JOBS=1 bash .../run-tests.sh                  # one suite at a time
#     KEEP_TMP=1 ...                                     # keep each test's dir
#
# No dependencies beyond bash and coreutils: every external command the code
# under test calls (docker, curl, sleep, systemctl) is replaced by a stub, so
# this runs on a laptop, in CI, or on a shop's own machine.
#
# Suites are independent — each test gets its own throwaway deploy directory —
# so they run concurrently by default. Almost all of the wall-clock here is
# process spawning: the tests drive the real scripts, which shell out constantly.
set -uo pipefail

cd "$(dirname "$0")" || exit 1

suite_filter="${1:-}"
suites=()
for f in test_*.sh; do
  [ -f "$f" ] || continue
  if [ -n "$suite_filter" ]; then
    case "$f" in *"$suite_filter"*) ;; *) continue ;; esac
  fi
  suites+=("$f")
done

if [ "${#suites[@]}" -eq 0 ]; then
  printf 'no test suites matched %s\n' "${suite_filter:-*}" >&2
  exit 1
fi

outdir="$(mktemp -d "${TMPDIR:-/tmp}/pu-suite-out-XXXXXX")"
trap 'rm -rf "$outdir"' EXIT

if [ "${TEST_JOBS:-0}" = 1 ]; then
  for suite in "${suites[@]}"; do
    bash "$suite" >"${outdir}/${suite}.out" 2>&1
    printf '%s' "$?" >"${outdir}/${suite}.rc"
  done
else
  for suite in "${suites[@]}"; do
    { bash "$suite" >"${outdir}/${suite}.out" 2>&1; printf '%s' "$?" >"${outdir}/${suite}.rc"; } &
  done
  wait
fi

total_pass=0 total_fail=0
failed_suites=()
for suite in "${suites[@]}"; do
  output="$(cat "${outdir}/${suite}.out" 2>/dev/null)"
  rc="$(cat "${outdir}/${suite}.rc" 2>/dev/null || echo 1)"
  printf '%s\n' "$output"
  pass="$(printf '%s\n' "$output" | sed -n 's/^# .*: \([0-9]*\) passed.*/\1/p' | tail -1)"
  fail="$(printf '%s\n' "$output" | sed -n 's/^# .*: [0-9]* passed, \([0-9]*\) failed.*/\1/p' | tail -1)"
  total_pass=$((total_pass + ${pass:-0}))
  total_fail=$((total_fail + ${fail:-0}))
  [ "$rc" = 0 ] || failed_suites+=("$suite")
done

printf '=====================================================\n'
printf 'on-prem update engine: %d passed, %d failed\n' "$total_pass" "$total_fail"
if [ "${#failed_suites[@]}" -gt 0 ]; then
  printf 'failing suites: %s\n' "${failed_suites[*]}"
  exit 1
fi
exit 0
