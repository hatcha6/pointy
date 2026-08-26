#!/usr/bin/env bash
#
# Tiny zero-dependency test harness for the on-prem update engine.
#
# Why hand-rolled instead of bats: these tests have to be runnable on any host
# that can run the scripts they test — a maintainer's Mac, a Linux CI runner, a
# shop's own machine while debugging a failed update. Anything that needs
# installing first would not get run there.
#
# Two kinds of test live on top of this:
#
#   * unit      — call the real update-lib.sh function with the external
#                 commands it shells out to (docker, curl, sleep…) replaced by
#                 recording stubs whose exit codes and output the test scripts.
#   * wiring    — call an orchestration function (pu_apply_bundle, pu_apply_live)
#                 with its own sub-functions redefined, so the test asserts the
#                 ORDER and the RETURN-CODE CONTRACT between steps rather than
#                 re-testing the steps.
#
# Each test runs in its own subshell, in its own throwaway deploy directory, so
# a test that leaves the world dirty cannot affect the next one. Assertions
# abort the test they fail in (they `exit 1` inside that subshell).
#
# Usage inside a test file:
#
#     . "$(dirname "$0")/harness.sh"
#     test_something() { assert_ok pu_current_version; }
#     pu_run_tests "$@"
#
# Environment:
#     KEEP_TMP=1   keep each test's deploy directory and print its path
#     VERBOSE=1    show stdout/stderr of passing tests too

set -uo pipefail

PU_TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PU_ONPREM_DIR="$(cd "${PU_TESTS_DIR}/.." && pwd)"
PU_LIB="${PU_ONPREM_DIR}/update-lib.sh"

PU_TEST_PASS=0
PU_TEST_FAIL=0
PU_TEST_FAILED_NAMES=()

# ---------------------------------------------------------------------------
# Stubs
#
# Every stub is a copy of one shim that records its own argv to $PU_STUB_CALLS
# and then consults a rules file for what to do. Rules are matched in order,
# first match wins, and the pattern is a glob matched against the whole argv
# joined with spaces — so a test can say "the third `docker load` fails" without
# writing a bespoke fake for it.
# ---------------------------------------------------------------------------

_pu_write_shim() {
  cat >"$1" <<'SHIM_EOF'
#!/usr/bin/env bash
# Recording stub — see tests/harness.sh
_name="$(basename "$0")"
_argv="$*"
printf '%s\t%s\n' "$_name" "$_argv" >>"$PU_STUB_CALLS"
_rules="${PU_STUB_DIR}/rules/${_name}"
if [ -f "$_rules" ]; then
  while IFS=$'\t' read -r _pattern _code _out; do
    [ -n "$_pattern" ] || continue
    case "$_argv" in
      $_pattern)
        [ -n "${_out:-}" ] && printf '%b\n' "$_out"
        exit "${_code:-0}"
        ;;
    esac
  done <"$_rules"
fi
exit "${PU_STUB_DEFAULT_EXIT:-0}"
SHIM_EOF
  chmod +x "$1"
}

# stub_cmd <name>... — install recording stubs that succeed silently by default.
stub_cmd() {
  local name
  for name in "$@"; do
    _pu_write_shim "${PU_STUB_DIR}/${name}"
  done
}

# stub_script <name> — install a stub with a custom body read from stdin. It
# still records its argv first, so assert_called works on it too. Use this when
# a stub must actually DO something (a fake `shred` that really unlinks).
stub_script() {
  local name="$1"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\t%%s\\n" "%s" "$*" >>"$PU_STUB_CALLS"\n' "$name"
    cat
  } >"${PU_STUB_DIR}/${name}"
  chmod +x "${PU_STUB_DIR}/${name}"
}

# stub_rule <cmd> <argv-glob> <exit-code> [stdout] — append a rule. Rules are
# consulted in the order they were added. `stdout` goes through printf %b, so
# \n produces multiple lines.
stub_rule() {
  local cmd="$1" pattern="$2" code="$3" out="${4:-}"
  mkdir -p "${PU_STUB_DIR}/rules"
  printf '%s\t%s\t%s\n' "$pattern" "$code" "$out" >>"${PU_STUB_DIR}/rules/${cmd}"
}

# stub_reset_rules <cmd> — drop every rule for a command.
stub_reset_rules() { rm -f "${PU_STUB_DIR}/rules/${1}"; }

# calls_of <cmd> — every recorded argv for one command, one per line.
calls_of() {
  [ -f "$PU_STUB_CALLS" ] || return 0
  awk -F'\t' -v cmd="$1" '$1 == cmd { sub(/^[^\t]*\t/, ""); print }' "$PU_STUB_CALLS"
}

# all_calls — every recorded call, in order, as "cmd argv".
all_calls() {
  [ -f "$PU_STUB_CALLS" ] || return 0
  tr '\t' ' ' <"$PU_STUB_CALLS"
}

count_calls() { calls_of "$1" | grep -c . ; }

# ---------------------------------------------------------------------------
# Assertions — each aborts the current test on failure.
# ---------------------------------------------------------------------------

_fail() {
  printf '    FAILED: %s\n' "$1" >&2
  shift
  local line
  for line in "$@"; do printf '      %s\n' "$line" >&2; done
  exit 1
}

assert_eq() { # assert_eq <expected> <actual> [message]
  [ "$1" = "$2" ] && return 0
  _fail "${3:-values differ}" "expected: [$1]" "actual:   [$2]"
}

assert_ne() {
  [ "$1" != "$2" ] && return 0
  _fail "${3:-values should differ}" "both: [$1]"
}

assert_ok() { # assert_ok <command...>
  "$@" && return 0
  _fail "expected success from: $*" "exit status: $?"
}

assert_fail() { # assert_fail <command...>  (any non-zero)
  "$@"
  local rc=$?
  [ "$rc" -ne 0 ] && return 0
  _fail "expected failure from: $*" "exit status: 0"
}

assert_status() { # assert_status <expected> <command...>
  local want="$1"; shift
  "$@"
  local rc=$?
  [ "$rc" = "$want" ] && return 0
  _fail "wrong exit status from: $*" "expected: $want" "actual:   $rc"
}

assert_contains() { # assert_contains <haystack> <needle> [message]
  case "$1" in *"$2"*) return 0 ;; esac
  _fail "${3:-substring not found}" "looking for: [$2]" "in:          [$1]"
}

assert_not_contains() {
  case "$1" in *"$2"*) _fail "${3:-substring should be absent}" "found: [$2]" "in:    [$1]" ;; esac
  return 0
}

assert_file() { [ -f "$1" ] || _fail "expected file to exist: $1"; }
assert_no_file() { [ -e "$1" ] && _fail "expected path NOT to exist: $1"; return 0; }
assert_dir() { [ -d "$1" ] || _fail "expected directory to exist: $1"; }

assert_file_contains() { # assert_file_contains <path> <substring>
  assert_file "$1"
  assert_contains "$(cat "$1")" "$2" "file $1 does not contain the expected text"
}

assert_file_lacks() {
  assert_file "$1"
  assert_not_contains "$(cat "$1")" "$2" "file $1 unexpectedly contains the text"
}

assert_file_eq() { # assert_file_eq <path> <exact-contents>
  assert_file "$1"
  assert_eq "$2" "$(cat "$1")" "file $1 has unexpected contents"
}

# assert_called <cmd> <argv-glob> — the command was invoked with matching argv.
assert_called() {
  local line
  while IFS= read -r line; do
    # shellcheck disable=SC2254  # $2 is a glob on purpose — it IS the matcher
    case "$line" in $2) return 0 ;; esac
  done < <(calls_of "$1")
  _fail "expected $1 to be called matching: $2" "recorded $1 calls:" "$(calls_of "$1" | sed 's/^/  /')"
}

assert_not_called() {
  local line
  while IFS= read -r line; do
    # shellcheck disable=SC2254  # $2 is a glob on purpose
    case "$line" in $2) _fail "expected $1 NOT to be called matching: $2" "offending call: $line" ;; esac
  done < <(calls_of "$1")
  return 0
}

assert_call_count() { # assert_call_count <cmd> <argv-glob> <expected-count>
  local line n=0
  while IFS= read -r line; do
    # shellcheck disable=SC2254  # $2 is a glob on purpose
    case "$line" in $2) n=$((n + 1)) ;; esac
  done < <(calls_of "$1")
  [ "$n" = "$3" ] && return 0
  _fail "wrong number of $1 calls matching: $2" "expected: $3" "actual:   $n" "recorded:" "$(calls_of "$1" | sed 's/^/  /')"
}

# assert_order <marker-a> <marker-b> — a appeared before b in the ORDER log.
assert_order() {
  local order; order="$(cat "${PU_TEST_DIR}/order.log" 2>/dev/null)"
  assert_contains "$order" "$1" "marker '$1' never happened"
  assert_contains "$order" "$2" "marker '$2' never happened"
  local first second
  first="$(grep -n -x -F "$1" "${PU_TEST_DIR}/order.log" | head -1 | cut -d: -f1)"
  second="$(grep -n -x -F "$2" "${PU_TEST_DIR}/order.log" | head -1 | cut -d: -f1)"
  [ "$first" -lt "$second" ] && return 0
  _fail "expected '$1' before '$2'" "order was:" "$(sed 's/^/  /' "${PU_TEST_DIR}/order.log")"
}

# record <marker> — append to the ordering log from a mocked function.
record() { printf '%s\n' "$1" >>"${PU_TEST_DIR}/order.log"; }

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

# write_env <lines...> — replace .env with exactly these lines.
write_env() { printf '%s\n' "$@" >.env; }

# default_env — the keys update-lib.sh actually reads, as a fresh install has them.
default_env() {
  write_env \
    'POINTY_BACKEND_PORT=8000' \
    'POINTY_BACKEND_BIND=0.0.0.0' \
    'POINTY_RELAY_PUBLIC_API_URL=https://relay.example.test' \
    'POINTY_BACKEND_IMAGE=pointy-backend:1.0.0' \
    'POINTY_RELAY_IMAGE=pointy-relay:1.0.0' \
    'POINTY_WEB_IMAGE=pointy-web:1.0.0' \
    'POSTGRES_USER=pointy' \
    'POSTGRES_DB=pointy'
}

# make_bundle <dir> <version> [extra-file...] — a directory that looks like a
# release bundle: images/, VERSION.txt, and the scripts a bundle adopts.
make_bundle() {
  local dir="$1" version="$2"
  mkdir -p "${dir}/images" "${dir}/wsl"
  printf '%s\n' "$version" >"${dir}/VERSION.txt"
  local f
  for f in docker-compose.yml install.sh watchdog.sh register-autostart.sh \
           update.sh update-agent.sh update-lib.sh discovery-responder.py \
           migrate-fahd.sh disable-watchdog.sh fix-backend-outages.sh \
           .env.example INSTALL.md README.md; do
    printf 'bundled %s from %s\n' "$f" "$version" >"${dir}/${f}"
  done
  printf 'bundled bootstrap from %s\n' "$version" >"${dir}/wsl/bootstrap-wsl.ps1"
  printf 'bundled timezones from %s\n' "$version" >"${dir}/wsl/timezone-map.txt"
  printf 'fake backend image %s\n' "$version" >"${dir}/images/pointy-backend.tar"
  printf 'fake relay image %s\n' "$version"   >"${dir}/images/pointy-relay.tar"
  printf 'fake web image %s\n' "$version"     >"${dir}/images/pointy-web.tar"
}

# installed_deploy <version> — the deploy directory as an installed shop has it.
installed_deploy() {
  default_env
  printf '%s\n' "${1:-1.0.0}" >VERSION.txt
  printf 'installed compose\n' >docker-compose.yml
  printf 'installed installer\n' >install.sh
  mkdir -p images backups edge/active
  printf 'old backend image\n' >images/pointy-backend.tar
}

# curl_header_response <upstream-name> — make the stubbed `curl -I` report the
# front door serving <upstream-name>, with the CRLF a real HTTP response has.
curl_header_response() {
  printf 'HTTP/1.1 200 OK\\r\\nX-Pointy-Upstream: %s\\r\\nContent-Length: 2\\r\\n' "$1"
}

# farm_path [exclude...] — a PATH directory holding just the real binaries these
# scripts use, minus the named ones. The only reliable way to test "what happens
# on a host that does not have jq / unzip / docker" is to hand the script a PATH
# that genuinely lacks it; a stub placed earlier would still be found.
farm_path() {
  local dir="${PU_TEST_DIR}/farm" c p skip
  rm -rf "$dir"; mkdir -p "$dir"
  for c in date mktemp cat rm mv cp ls sed awk grep cut tr head tail find sort \
           basename dirname chmod mkdir rmdir stat seq id touch wc \
           sha256sum shasum unzip zip python3 python bash sh env sleep; do
    skip=0
    for e in "$@"; do [ "$c" = "$e" ] && skip=1; done
    [ "$skip" = 1 ] && continue
    p="$(command -v "$c" 2>/dev/null)" || continue
    [ -n "$p" ] && ln -sf "$p" "${dir}/${c}"
  done
  printf '%s' "$dir"
}

# ---------------------------------------------------------------------------
# Per-test lifecycle
# ---------------------------------------------------------------------------

pu_test_setup() {
  PU_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pu-test-XXXXXX")"
  export PU_TEST_DIR
  export PU_STUB_DIR="${PU_TEST_DIR}/stubs"
  export PU_STUB_CALLS="${PU_TEST_DIR}/calls.log"
  export PU_STUB_DEFAULT_EXIT=0
  mkdir -p "$PU_STUB_DIR/rules" "${PU_TEST_DIR}/deploy"
  : >"$PU_STUB_CALLS"
  : >"${PU_TEST_DIR}/order.log"

  # The externals update-lib.sh and update-agent.sh shell out to. `sleep` is
  # stubbed so retry loops cost nothing; `date` deliberately is NOT, because the
  # lock's staleness maths depends on real timestamps.
  stub_cmd docker curl sleep systemctl
  export PATH="${PU_STUB_DIR}:${PATH}"

  cd "${PU_TEST_DIR}/deploy" || exit 1
  # Sourced by the code under test, not run — matches how update.sh uses it.
  # shellcheck disable=SC1090
  . "$PU_LIB"
  # Keep an untouched alias of the functions a wiring test may want to mock and
  # then put back. `unset -f` cannot do it: it deletes the function rather than
  # revealing the library's, so the call fails and the test passes vacuously.
  eval "_pu_real_adopt_bundle() $(declare -f pu_adopt_bundle | tail -n +2)"
}

pu_test_teardown() {
  cd / || true
  if [ "${KEEP_TMP:-0}" = 1 ]; then
    printf '    kept: %s\n' "$PU_TEST_DIR"
  else
    rm -rf "$PU_TEST_DIR"
  fi
}

# pu_run_tests [name-filter] — run every test_* function defined in the caller.
pu_run_tests() {
  local filter="${1:-${TEST_FILTER:-}}"
  local suite; suite="$(basename "${BASH_SOURCE[1]}" .sh)"
  local fn rc out
  local names; names="$(declare -F | awk '{print $3}' | grep '^test_' | sort)"

  printf '# %s\n' "$suite"
  for fn in $names; do
    if [ -n "$filter" ]; then
      case "$fn" in *"$filter"*) ;; *) continue ;; esac
    fi
    out="$( {
      pu_test_setup
      trap pu_test_teardown EXIT
      "$fn"
    } 2>&1 )"
    rc=$?
    if [ "$rc" = 0 ]; then
      PU_TEST_PASS=$((PU_TEST_PASS + 1))
      printf 'ok   %s\n' "${fn#test_}"
      [ "${VERBOSE:-0}" = 1 ] && [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/     /'
    else
      PU_TEST_FAIL=$((PU_TEST_FAIL + 1))
      PU_TEST_FAILED_NAMES+=("${suite}: ${fn#test_}")
      printf 'FAIL %s\n' "${fn#test_}"
      [ -n "$out" ] && printf '%s\n' "$out"
    fi
  done

  printf '# %s: %d passed, %d failed\n\n' "$suite" "$PU_TEST_PASS" "$PU_TEST_FAIL"
  [ "$PU_TEST_FAIL" = 0 ]
}
