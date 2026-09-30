#!/usr/bin/env bash
#
# update-agent.sh — the entry point the relay actually drives, and the only
# component in the whole remote-update chain that a broken update cannot be
# fixed without visiting the shop. It is run for real here (its own argument
# parsing, its own curl calls, its own token handling); only the network, Docker
# and the final apply are replaced.
#
# The decisions being pinned:
#   * a shop that is up to date, unreachable or still bootstrapping must be a
#     quiet no-op, never a failed update;
#   * nothing is applied until the bundle's sha256 matches;
#   * a download survives any number of interruptions and runs, resuming where
#     it stopped — a bundle over a Libyan shop line never arrives in one piece;
#   * the update lock is held for the apply only, never the hours-long download,
#     and two agents can never overlap;
#   * every terminal state is reported back to the relay, because `fleet status`
#     is what an operator batches on.
. "$(dirname "$0")/harness.sh"

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

# A docker that answers the one thing the agent needs from it: the connector's
# state file, which is where this installation's relay token lives.
_stub_docker_with_connector_state() {
  stub_script docker <<'EOF'
case "$*" in
  *"cp connector:"*)
    [ "${CONNECTOR_STATE_RC:-0}" = 0 ] || exit 1
    for _dest; do :; done
    printf '{"installation_id":"inst_1","connector_token":"%s"}\n' \
      "${CONNECTOR_TOKEN-ct_live_token}" >"$_dest"
    exit 0 ;;
esac
exit 0
EOF
}

# A relay: serves the manifest from a file the test writes, serves the bundle,
# and records every status POST so the test can assert what the fleet was told.
#
# The bundle download behaves like the real endpoint on a bad line. It honours
# `-C -` (resume from the size of the file already there, else start over), and
# AGENT_DOWNLOAD_PLAN scripts each attempt in turn:
#   ok        serve the rest of the file            (the default past the plan)
#   drop:N    serve the next N bytes, then lose the connection (exit 18)
#   fail:RC   fail with curl exit RC, no bytes
#   http:C    answer HTTP C (curl -f exits 22)
#   norange   answer 200 to a range request (curl exit 33)
# Every attempt's starting offset is logged to download-offsets.log.
_stub_curl_as_relay() {
  stub_script curl <<'EOF'
_out=""; _url=""; _body=""; _prev=""; _resume=0; _code=0
for _a in "$@"; do
  case "$_prev" in
    -o) _out="$_a" ;;
    -d) _body="$_a" ;;
    -C) _resume=1 ;;
    -w) _code=1 ;;
  esac
  case "$_a" in http*) _url="$_a" ;; esac
  _prev="$_a"
done
case "$_url" in
  */v1/agent/status)
    printf '%s\n' "$_body" >>"${PU_TEST_DIR}/status-posts.jsonl"
    exit "${AGENT_STATUS_RC:-0}" ;;
  */v1/agent/manifest)
    [ "${AGENT_MANIFEST_RC:-0}" = 0 ] || exit "${AGENT_MANIFEST_RC}"
    cat "${PU_TEST_DIR}/manifest.json" >"$_out"
    exit 0 ;;
esac
[ "${AGENT_DOWNLOAD_RC:-0}" = 0 ] || exit "${AGENT_DOWNLOAD_RC}"
_n=$(( $(cat "${PU_TEST_DIR}/download-attempts" 2>/dev/null || echo 0) + 1 ))
printf '%s' "$_n" >"${PU_TEST_DIR}/download-attempts"
_step="$(printf '%s\n' ${AGENT_DOWNLOAD_PLAN:-} | sed -n "${_n}p")"
_offset=0
if [ "$_resume" = 1 ] && [ -f "$_out" ]; then _offset="$(wc -c <"$_out" | tr -d ' ')"; fi
printf '%s\n' "$_offset" >>"${PU_TEST_DIR}/download-offsets.log"
case "$_step" in
  fail:*) exit "${_step#fail:}" ;;
  http:*) [ "$_code" = 1 ] && printf '%s' "${_step#http:}"; exit 22 ;;
  norange) exit 33 ;;
esac
[ "$_offset" = 0 ] && : >"$_out"
case "$_step" in
  drop:*)
    tail -c +"$(( _offset + 1 ))" "${PU_TEST_DIR}/bundle.zip" | head -c "${_step#drop:}" >>"$_out"
    exit 18 ;;
esac
tail -c +"$(( _offset + 1 ))" "${PU_TEST_DIR}/bundle.zip" >>"$_out"
[ "$_code" = 1 ] && { [ "$_offset" = 0 ] && printf 200 || printf 206; }
exit 0
EOF
}

_sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# A real bundle zip, so the agent's download → verify → stage path is real. It is
# identical for every test here, so it is built once for the suite and copied in
# — rebuilding it per test cost more than everything else in the suite combined.
PU_AGENT_FIXTURES="$(mktemp -d "${TMPDIR:-/tmp}/pu-agent-fixtures-XXXXXX")"
trap 'rm -rf "$PU_AGENT_FIXTURES"' EXIT
export PU_AGENT_FIXTURES

_build_shared_bundle_zip() {
  local version="$1"
  make_bundle "${PU_AGENT_FIXTURES}/src/pointy-onprem-${version}" "$version"
  if command -v zip >/dev/null 2>&1; then
    ( cd "${PU_AGENT_FIXTURES}/src" && zip -qr "${PU_AGENT_FIXTURES}/bundle-${version}.zip" . )
  else
    python3 "${PU_TESTS_DIR}/zipdir.py"       "${PU_AGENT_FIXTURES}/bundle-${version}.zip" "${PU_AGENT_FIXTURES}/src"
  fi
  rm -rf "${PU_AGENT_FIXTURES}/src"
}
_build_shared_bundle_zip 1.1.0

_make_bundle_zip() { cp "${PU_AGENT_FIXTURES}/bundle-${1}.zip" "${PU_TEST_DIR}/bundle.zip"; }

_manifest() { # _manifest <directive> <assigned-version> [sha-override]
  local sha="${3:-}" size
  [ -n "$sha" ] || sha="$(_sha256_of "${PU_TEST_DIR}/bundle.zip" 2>/dev/null || echo none)"
  size="$(wc -c <"${PU_TEST_DIR}/bundle.zip" 2>/dev/null | tr -d ' ')"
  cat >"${PU_TEST_DIR}/manifest.json" <<JSON
{"directive":"$1","assigned_version":"$2","bundle":{"path":"/v1/agent/artifacts/$2","sha256":"${sha}","size":${size:-0}}}
JSON
}

# Put the real agent in a deploy directory, with a stand-in update-lib.sh that
# is the real library plus one seam: the apply itself is recorded instead of
# performed. Everything the agent does up to that point is the shipped code.
_install_agent() {
  installed_deploy "${1:-1.0.0}"
  cp "${PU_ONPREM_DIR}/update-agent.sh" ./update-agent.sh
  chmod +x ./update-agent.sh
  cat >./update-lib.sh <<EOF
. "${PU_LIB}"
pu_apply_bundle() {
  printf 'apply:%s->%s mode=%s dir=%s\n' "\$2" "\$3" "\${4:-auto}" "\$1" >>"\${PU_TEST_DIR}/order.log"
  [ -f .update.lock ] && printf 'apply-locked\n' >>"\${PU_TEST_DIR}/order.log"
  POINTY_APPLY_ERROR="\${APPLY_ERROR:-}"
  return "\${APPLY_RC:-0}"
}
EOF
  _stub_docker_with_connector_state
  _stub_curl_as_relay
  _make_bundle_zip "${2:-1.1.0}"
}

_run_agent() { bash ./update-agent.sh "$@"; }
# assert_order_in <text> <a> <b> — the first <a> comes before the first <b>.
assert_order_in() {
  local first second
  first="$(printf '%s\n' "$1" | grep -n -F "$2" | head -1 | cut -d: -f1)"
  second="$(printf '%s\n' "$1" | grep -n -F "$3" | head -1 | cut -d: -f1)"
  [ -n "$first" ] && [ -n "$second" ] && [ "$first" -lt "$second" ] && return 0
  _fail "expected '$2' before '$3'" "$1"
}
_order()  { cat "${PU_TEST_DIR}/order.log" 2>/dev/null; }
_status_posts() { cat "${PU_TEST_DIR}/status-posts.jsonl" 2>/dev/null; }

# ---------------------------------------------------------------------------
# The quiet no-ops — a shop that needs nothing must never look like a failure
# ---------------------------------------------------------------------------

test_an_up_to_date_shop_reports_idle_and_does_nothing() {
  _install_agent 1.0.0 1.1.0
  _manifest hold ''
  local out; out="$(_run_agent 2>&1)"; local rc=$?
  assert_eq '0' "$rc"
  assert_contains "$out" 'up to date'
  assert_contains "$(_status_posts)" '"update_status":"idle"'
  assert_eq '' "$(_order)"
}

test_a_shop_already_on_the_assigned_version_reports_idle() {
  _install_agent 1.1.0 1.1.0
  _manifest apply 1.1.0
  assert_status 0 _run_agent >/dev/null 2>&1
  assert_contains "$(_status_posts)" '"update_status":"idle"'
  assert_eq '' "$(_order)"
}

test_an_apply_directive_with_no_version_is_treated_as_nothing_to_do() {
  _install_agent 1.0.0 1.1.0
  _manifest apply ''
  assert_status 0 _run_agent >/dev/null 2>&1
  assert_eq '' "$(_order)"
}

test_a_no_op_run_leaves_another_updates_lock_alone() {
  # REGRESSION. The agent arms its cleanup trap BEFORE it takes the lock, so
  # cleanup runs on paths where this process never owned one — including the
  # path where it stood down precisely because someone else holds it. Releasing
  # unconditionally there unlinks the other updater's lock: the watchdog stops
  # standing down and starts reconciling the stack mid-flip, and the next timer
  # tick, seeing no lock, launches a SECOND concurrent update. On a fleet where
  # every shop runs this on a timer and a slow link makes downloads long, that
  # is not a corner case.
  _install_agent 1.0.0 1.1.0
  _manifest hold ''
  printf 'pid=4242 started=now\n' >.update.lock
  _run_agent >/dev/null 2>&1
  assert_file_contains .update.lock 'pid=4242'
}

test_an_interrupted_precondition_check_leaves_another_updates_lock_alone() {
  # Same defect, reached through the other early-exit paths.
  _install_agent 1.0.0 1.1.0
  _manifest apply 1.1.0
  printf 'pid=4242 started=now\n' >.update.lock
  export AGENT_MANIFEST_RC=7
  _run_agent >/dev/null 2>&1
  assert_file_contains .update.lock 'pid=4242'
  unset AGENT_MANIFEST_RC
  export CONNECTOR_STATE_RC=1
  _run_agent >/dev/null 2>&1
  assert_file_contains .update.lock 'pid=4242'
}

test_a_check_run_leaves_another_updates_lock_alone() {
  _install_agent 1.0.0 1.1.0
  _manifest apply 1.1.0
  printf 'pid=4242 started=now\n' >.update.lock
  _run_agent --check >/dev/null 2>&1
  assert_file_contains .update.lock 'pid=4242'
}

test_a_no_op_run_never_takes_the_update_lock() {
  # The lock tells the watchdog to stand down. Taking it for a run that does
  # nothing would leave the stack unreconciled for no reason.
  _install_agent 1.0.0 1.1.0
  _manifest hold ''
  _run_agent >/dev/null 2>&1
  assert_no_file .update.lock
}

test_a_shop_that_cannot_reach_the_relay_retries_next_run() {
  # Libyan shops lose connectivity constantly. An unreachable relay is not a
  # failed update and must not be reported as one — it would show up in
  # `fleet status` as a shop needing attention when nothing is wrong.
  _install_agent 1.0.0 1.1.0
  _manifest apply 1.1.0
  export AGENT_MANIFEST_RC=7
  local out; out="$(_run_agent 2>&1)"; local rc=$?
  assert_eq '0' "$rc"
  assert_contains "$out" 'manifest fetch failed; retrying next run'
  assert_eq '' "$(_status_posts)"
  assert_eq '' "$(_order)"
}

test_a_shop_still_bootstrapping_its_connector_retries_next_run() {
  # First boot: the connector has not written its state file yet, so there is no
  # token to authenticate with. Exiting 0 keeps the host timer sane.
  _install_agent 1.0.0 1.1.0
  _manifest apply 1.1.0
  export CONNECTOR_STATE_RC=1
  local out; out="$(_run_agent 2>&1)"; local rc=$?
  assert_eq '0' "$rc"
  assert_contains "$out" 'connector state unavailable yet'
  assert_eq '' "$(_status_posts)"
}

test_a_connector_state_without_a_token_is_a_hard_error() {
  _install_agent 1.0.0 1.1.0
  _manifest apply 1.1.0
  export CONNECTOR_TOKEN=''
  local out; out="$(_run_agent 2>&1)"; local rc=$?
  assert_eq '1' "$rc"
  assert_contains "$out" 'connector token not found in connector state'
}

# ---------------------------------------------------------------------------
# --check: what it WOULD do
# ---------------------------------------------------------------------------

test_check_reports_the_pending_update_without_applying_it() {
  _install_agent 1.0.0 1.1.0
  _manifest apply 1.1.0
  local out; out="$(_run_agent --check 2>&1)"; local rc=$?
  assert_eq '0' "$rc"
  assert_contains "$out" 'update available: 1.0.0 -> 1.1.0'
  assert_contains "$out" '--check: would download'
  assert_eq '' "$(_order)"
}

test_check_never_takes_the_lock_or_downloads_anything() {
  # It has to be safe to run against a shop that is trading, at any moment —
  # that is the whole point of a preflight.
  _install_agent 1.0.0 1.1.0
  _manifest apply 1.1.0
  _run_agent --check >/dev/null 2>&1
  assert_no_file .update.lock
  assert_not_called curl '*artifacts*'
}

test_check_reports_up_to_date_for_a_current_shop() {
  _install_agent 1.1.0 1.1.0
  _manifest apply 1.1.0
  local out; out="$(_run_agent --check 2>&1)"
  assert_contains "$out" 'up to date'
}

# ---------------------------------------------------------------------------
# The happy path
# ---------------------------------------------------------------------------

test_an_assigned_update_is_downloaded_verified_and_applied() {
  _install_agent 1.0.0 1.1.0
  _manifest apply 1.1.0
  local out; out="$(_run_agent 2>&1)"; local rc=$?
  assert_eq '0' "$rc"
  assert_contains "$out" 'update available: 1.0.0 -> 1.1.0'
  assert_contains "$(_order)" 'apply:1.0.0->1.1.0'
}

test_the_relay_is_told_applying_then_succeeded() {
  # An operator batching a rollout watches these transitions; a shop that jumps
  # straight from idle to succeeded, or that never leaves applying, is the
  # signal that something is wrong.
  _install_agent 1.0.0 1.1.0
  _manifest apply 1.1.0
  _run_agent >/dev/null 2>&1
  local posts; posts="$(_status_posts)"
  assert_contains "$posts" '"update_status":"applying"'
  assert_contains "$posts" '"update_status":"succeeded"'
  assert_contains "$(printf '%s\n' "$posts" | tail -1)" '"current_version":"1.1.0"'
}

test_status_reports_carry_the_agent_version() {
  # The relay uses this to know which shops are running an agent too old to
  # understand a new manifest field.
  _install_agent 1.0.0 1.1.0
  _manifest apply 1.1.0
  _run_agent >/dev/null 2>&1
  assert_contains "$(_status_posts)" '"agent_version":"pointy-update-agent/'
}

test_a_second_agent_run_stands_down_while_the_first_holds_the_lock() {
  _install_agent 1.0.0 1.1.0
  _manifest apply 1.1.0
  printf 'pid=4242 started=now\n' >.update.lock
  local out; out="$(_run_agent 2>&1)"; local rc=$?
  assert_eq '0' "$rc"
  assert_contains "$out" 'another update is already running'
  assert_eq '' "$(_order)"
  # And it must not have stolen the other holder's lock on the way out.
  assert_file_contains .update.lock 'pid=4242'
}

test_the_lock_is_released_even_when_the_update_fails() {
  _install_agent 1.0.0 1.1.0
  _manifest apply 1.1.0
  export APPLY_RC=1
  _run_agent >/dev/null 2>&1
  assert_no_file .update.lock
}

# ---------------------------------------------------------------------------
# Integrity — nothing is applied that did not arrive intact
# ---------------------------------------------------------------------------

test_a_bundle_whose_checksum_does_not_match_is_never_applied() {
  # The one check standing between a corrupted (or substituted) download and
  # `docker load` on a shop's machine.
  _install_agent 1.0.0 1.1.0
  _manifest apply 1.1.0 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef'
  local out; out="$(_run_agent 2>&1)"; local rc=$?
  assert_eq '1' "$rc"
  assert_contains "$out" 'sha256 mismatch'
  assert_eq '' "$(_order)"
  assert_contains "$(_status_posts)" '"update_error":"sha256 mismatch"'
}

test_a_failed_checksum_still_reports_the_version_the_shop_is_running() {
  _install_agent 1.0.0 1.1.0
  _manifest apply 1.1.0 'deadbeef'
  _run_agent >/dev/null 2>&1
  assert_contains "$(printf '%s\n' "$(_status_posts)" | tail -1)" '"current_version":"1.0.0"'
}

# ---------------------------------------------------------------------------
# The download — built for a line that drops, a PC that sleeps, a distro that
# restarts. Every one of these is a shop that would otherwise never update.
# ---------------------------------------------------------------------------

_bundle_bytes() { wc -c <"${PU_TEST_DIR}/bundle.zip" | tr -d ' '; }
_offsets() { tr '\n' ' ' <"${PU_TEST_DIR}/download-offsets.log" 2>/dev/null | sed 's/ $//'; }
_downloads() { ls downloads 2>/dev/null | grep -v '^\.' | tr '\n' ' ' | sed 's/ $//'; }

test_a_dropped_connection_is_resumed_in_the_same_run() {
  _install_agent 1.0.0 1.1.0
  _manifest apply 1.1.0
  export AGENT_DOWNLOAD_PLAN='drop:100 drop:50 ok'
  local out; out="$(_run_agent 2>&1)"; local rc=$?
  assert_eq '0' "$rc"
  assert_eq '0 100 150' "$(_offsets)" 'each retry must continue where the last one stopped'
  assert_contains "$out" 'resuming the download at'
  assert_contains "$(_order)" 'apply:1.0.0->1.1.0'
}

test_a_download_cut_short_by_the_end_of_a_run_resumes_on_the_next_run() {
  # REGRESSION. The agent used to download into a fresh mktemp dir every run,
  # so `curl -C -` never had anything to resume: a 1.1 GB bundle over a shop
  # line had to arrive in one unbroken go, and on 2026-09-30 one shop sat on
  # "applying" for six hours restarting from zero every attempt.
  _install_agent 1.0.0 1.1.0
  _manifest apply 1.1.0
  export POINTY_UPDATE_DOWNLOAD_ATTEMPTS=1 AGENT_DOWNLOAD_PLAN='drop:120'
  local out; out="$(_run_agent 2>&1)"; local rc=$?
  assert_eq '0' "$rc" 'an interrupted download is not a failed update'
  assert_contains "$out" 'the next run resumes it'
  assert_eq '' "$(_order)"
  assert_contains "$(_status_posts | tail -1)" '"update_status":"downloading '
  assert_contains "$(_status_posts | tail -1)" 'resuming next run'
  assert_eq '120' "$(wc -c <downloads/bundle-*.part | tr -d ' ')"

  # The next timer run: a new process, the same file.
  unset AGENT_DOWNLOAD_PLAN
  _run_agent >/dev/null 2>&1
  assert_eq '0 120' "$(_offsets)"
  assert_contains "$(_order)" 'apply:1.0.0->1.1.0'
}

test_a_run_that_keeps_failing_stops_at_its_attempt_budget() {
  _install_agent 1.0.0 1.1.0
  _manifest apply 1.1.0
  export POINTY_UPDATE_DOWNLOAD_ATTEMPTS=3 AGENT_DOWNLOAD_PLAN='fail:7 fail:7 fail:7 fail:7'
  local rc; _run_agent >/dev/null 2>&1; rc=$?
  assert_eq '0' "$rc"
  assert_eq '3' "$(cat "${PU_TEST_DIR}/download-attempts")"
  assert_not_contains "$(_status_posts)" '"update_status":"failed"'
  assert_eq '' "$(_order)"
}

test_a_run_stops_downloading_when_its_time_budget_is_spent() {
  # So a paused or re-targeted rollout takes effect at the next run, rather
  # than after a download that may take all day.
  _install_agent 1.0.0 1.1.0
  _manifest apply 1.1.0
  export POINTY_UPDATE_DOWNLOAD_BUDGET=0 AGENT_DOWNLOAD_PLAN='drop:10 ok'
  _run_agent >/dev/null 2>&1
  assert_eq '1' "$(cat "${PU_TEST_DIR}/download-attempts")"
  assert_eq '' "$(_order)"
}

test_an_http_error_that_retrying_cannot_fix_fails_at_once() {
  # A 404 (version withdrawn) or 401 (token revoked) is not a bad line.
  _install_agent 1.0.0 1.1.0
  _manifest apply 1.1.0
  export AGENT_DOWNLOAD_PLAN='http:404'
  local out; out="$(_run_agent 2>&1)"; local rc=$?
  assert_eq '1' "$rc"
  assert_eq '1' "$(cat "${PU_TEST_DIR}/download-attempts")"
  assert_contains "$(_status_posts)" '"update_error":"bundle download failed (HTTP 404)"'
  assert_eq '' "$(_order)"
}

test_a_server_error_is_retried() {
  _install_agent 1.0.0 1.1.0
  _manifest apply 1.1.0
  export AGENT_DOWNLOAD_PLAN='http:503 http:429 ok'
  assert_status 0 _run_agent >/dev/null 2>&1
  assert_contains "$(_order)" 'apply:1.0.0->1.1.0'
}

test_a_relay_that_will_not_resume_starts_the_download_over() {
  # A proxy that strips Range makes curl -C - give up (exit 33). Appending a
  # full response to a partial file would corrupt it, so start clean.
  _install_agent 1.0.0 1.1.0
  _manifest apply 1.1.0
  export AGENT_DOWNLOAD_PLAN='drop:40 norange ok'
  assert_status 0 _run_agent >/dev/null 2>&1
  assert_eq '0 40 0' "$(_offsets)"
  assert_contains "$(_order)" 'apply:1.0.0->1.1.0'
}

test_a_partial_larger_than_the_bundle_is_discarded() {
  _install_agent 1.0.0 1.1.0
  _manifest apply 1.1.0
  mkdir -p downloads
  local sha; sha="$(_sha256_of "${PU_TEST_DIR}/bundle.zip")"
  head -c "$(( $(_bundle_bytes) + 10 ))" /dev/zero >"downloads/bundle-${sha}.zip.part"
  assert_status 0 _run_agent >/dev/null 2>&1
  assert_eq '0' "$(_offsets)"
  assert_contains "$(_order)" 'apply:1.0.0->1.1.0'
}

test_a_complete_download_that_fails_its_checksum_is_thrown_away() {
  # Kept, it would be "resumed" — i.e. declared complete — into the same wrong
  # bytes on every run, and the shop could never update again.
  _install_agent 1.0.0 1.1.0
  _manifest apply 1.1.0 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef'
  _run_agent >/dev/null 2>&1
  assert_eq '' "$(_downloads)"
}

test_progress_is_reported_while_downloading() {
  _install_agent 1.0.0 1.1.0
  _manifest apply 1.1.0
  export AGENT_DOWNLOAD_PLAN='drop:100 ok'
  _run_agent >/dev/null 2>&1
  local posts; posts="$(_status_posts)"
  assert_contains "$posts" '"update_status":"downloading 0%"'
  assert_order_in "$posts" '"downloading 0%"' '"applying"'
  assert_order_in "$posts" '"applying"' '"succeeded"'
}

test_a_stalled_connection_is_detected_and_the_speed_can_be_capped() {
  # A dead TCP connection on a bad line can sit silent for hours; without a
  # speed floor curl would wait on it forever.
  _install_agent 1.0.0 1.1.0
  _manifest apply 1.1.0
  printf 'POINTY_UPDATE_RATE_LIMIT=200k\n' >>.env
  _run_agent >/dev/null 2>&1
  assert_called curl '*-C -*--speed-limit 1000 --speed-time 120*artifacts*'
  assert_called curl '*--limit-rate 200k*artifacts*'
}

test_the_speed_is_not_capped_by_default() {
  _install_agent 1.0.0 1.1.0
  _manifest apply 1.1.0
  _run_agent >/dev/null 2>&1
  assert_not_called curl '*--limit-rate*'
}

test_the_update_lock_is_held_for_the_apply_but_not_the_download() {
  # REGRESSION. The lock used to cover the download. It tells the watchdog to
  # stand down, so a backend that crashed during a six-hour download stayed
  # down for six hours — and after one hour the lock looked stale anyway.
  _install_agent 1.0.0 1.1.0
  _manifest apply 1.1.0
  stub_script curl <<'EOF'
_out=""; _url=""; _prev=""
for _a in "$@"; do
  case "$_prev" in -o) _out="$_a" ;; esac
  case "$_a" in http*) _url="$_a" ;; esac
  _prev="$_a"
done
case "$_url" in
  */v1/agent/status) exit 0 ;;
  */v1/agent/manifest) cat "${PU_TEST_DIR}/manifest.json" >"$_out"; exit 0 ;;
  *) [ -f .update.lock ] && printf 'download-locked\n' >>"${PU_TEST_DIR}/order.log"
     cat "${PU_TEST_DIR}/bundle.zip" >"$_out"; exit 0 ;;
esac
EOF
  _run_agent >/dev/null 2>&1
  assert_not_contains "$(_order)" 'download-locked'
  assert_contains "$(_order)" 'apply-locked'
  assert_no_file .update.lock
}

test_a_second_agent_stands_down_while_the_first_is_downloading() {
  _install_agent 1.0.0 1.1.0
  _manifest apply 1.1.0
  mkdir -p downloads
  sleep_forever_pid=""
  ( exec -a pu-fake-agent /bin/sleep 30 ) & sleep_forever_pid=$!
  printf 'pid=%s started=now\n' "$sleep_forever_pid" >downloads/.lock
  local out; out="$(_run_agent 2>&1)"; local rc=$?
  kill "$sleep_forever_pid" 2>/dev/null
  assert_eq '0' "$rc"
  assert_contains "$out" 'already downloading'
  assert_not_called curl '*artifacts*'
  assert_file_contains downloads/.lock "pid=${sleep_forever_pid}"
}

test_a_download_lock_left_by_a_dead_run_is_taken_over() {
  # A reboot mid-download leaves the lock behind; it must not block the shop.
  _install_agent 1.0.0 1.1.0
  _manifest apply 1.1.0
  mkdir -p downloads
  ( exit 0 ) & local dead=$!; wait "$dead"
  printf 'pid=%s started=then\n' "$dead" >downloads/.lock
  assert_status 0 _run_agent >/dev/null 2>&1
  assert_contains "$(_order)" 'apply:1.0.0->1.1.0'
  assert_no_file downloads/.lock
}

test_a_verified_download_survives_a_failed_apply_and_is_reused() {
  # A failed apply is retried every run. Downloading the bundle again for each
  # retry would bill the shop's line for our bug.
  _install_agent 1.0.0 1.1.0
  _manifest apply 1.1.0
  export APPLY_RC=1
  _run_agent >/dev/null 2>&1
  assert_contains "$(_downloads)" '.zip'
  assert_not_contains "$(_downloads)" '.part'
  unset APPLY_RC
  local out; out="$(_run_agent 2>&1)"
  assert_contains "$out" 'already downloaded'
  assert_eq '1' "$(cat "${PU_TEST_DIR}/download-attempts")"
  assert_eq '2' "$(grep -c '^apply:' "${PU_TEST_DIR}/order.log")"
}

test_a_kept_download_that_no_longer_verifies_is_downloaded_again() {
  _install_agent 1.0.0 1.1.0
  _manifest apply 1.1.0
  mkdir -p downloads
  local sha; sha="$(_sha256_of "${PU_TEST_DIR}/bundle.zip")"
  printf 'bit rot\n' >"downloads/bundle-${sha}.zip"
  assert_status 0 _run_agent >/dev/null 2>&1
  assert_eq '1' "$(cat "${PU_TEST_DIR}/download-attempts")"
  assert_contains "$(_order)" 'apply:1.0.0->1.1.0'
}

test_a_successful_update_removes_the_download() {
  _install_agent 1.0.0 1.1.0
  _manifest apply 1.1.0
  _run_agent >/dev/null 2>&1
  assert_eq '' "$(_downloads)"
}

test_a_new_assignment_discards_the_old_download() {
  _install_agent 1.0.0 1.1.0
  _manifest apply 1.1.0
  mkdir -p downloads
  printf 'half of an older bundle\n' >downloads/bundle-0000.zip.part
  printf 'an older bundle\n' >downloads/bundle-1111.zip
  _run_agent >/dev/null 2>&1
  assert_no_file downloads/bundle-0000.zip.part
  assert_no_file downloads/bundle-1111.zip
}

test_a_paused_rollout_keeps_a_half_finished_download() {
  # Pausing is the operator's kill switch; resuming must not cost the shop the
  # hours it already spent.
  _install_agent 1.0.0 1.1.0
  mkdir -p downloads
  printf 'half\n' >downloads/bundle-abc.zip.part
  _manifest hold ''
  _run_agent >/dev/null 2>&1
  assert_file downloads/bundle-abc.zip.part
}

test_a_shop_running_the_assigned_version_clears_leftover_downloads() {
  # E.g. an agent killed between a successful apply and its own cleanup.
  _install_agent 1.1.0 1.1.0
  mkdir -p downloads
  printf 'leftover\n' >downloads/bundle-abc.zip
  _manifest apply 1.1.0
  _run_agent >/dev/null 2>&1
  assert_no_file downloads/bundle-abc.zip
}

test_a_hostile_bundle_name_cannot_leave_the_downloads_directory() {
  _install_agent 1.0.0 1.1.0
  cat >"${PU_TEST_DIR}/manifest.json" <<'JSON'
{"directive":"apply","assigned_version":"1.1.0","bundle":{"path":"/v1/agent/artifacts/1.1.0","sha256":"../../../etc/evil"}}
JSON
  _run_agent >/dev/null 2>&1
  assert_no_file "${PU_TEST_DIR}/etc/evil.zip.part"
  assert_no_file "${PU_TEST_DIR}/evil.zip.part"
  assert_call_count curl '*-o downloads/bundle-./etc/evil.zip.part*' 0
  assert_called curl '*-o downloads/bundle-.etcevil.zip.part*'
}

test_check_reports_how_much_is_already_downloaded() {
  _install_agent 1.0.0 1.1.0
  _manifest apply 1.1.0
  mkdir -p downloads
  local sha; sha="$(_sha256_of "${PU_TEST_DIR}/bundle.zip")"
  head -c 10 "${PU_TEST_DIR}/bundle.zip" >"downloads/bundle-${sha}.zip.part"
  local out; out="$(_run_agent --check 2>&1)"
  assert_contains "$out" 'already downloaded'
  assert_file "downloads/bundle-${sha}.zip.part"
}

test_the_connector_token_authenticates_every_relay_call() {
  _install_agent 1.0.0 1.1.0
  _manifest apply 1.1.0
  _run_agent >/dev/null 2>&1
  assert_called curl '*X-Pointy-Connector-Token: ct_live_token*v1/agent/manifest*'
  assert_called curl '*X-Pointy-Connector-Token: ct_live_token*artifacts*'
  assert_called curl '*X-Pointy-Connector-Token: ct_live_token*v1/agent/status*'
}

test_a_manifest_without_a_bundle_path_is_refused() {
  _install_agent 1.0.0 1.1.0
  cat >"${PU_TEST_DIR}/manifest.json" <<'JSON'
{"directive":"apply","assigned_version":"1.1.0","bundle":{"sha256":"abc"}}
JSON
  local out; out="$(_run_agent 2>&1)"; local rc=$?
  assert_eq '1' "$rc"
  assert_contains "$out" 'manifest is missing the bundle path'
  assert_eq '' "$(_order)"
}

test_a_bundle_that_cannot_be_staged_is_reported() {
  _install_agent 1.0.0 1.1.0
  printf 'not a zip\n' >"${PU_TEST_DIR}/bundle.zip"
  _manifest apply 1.1.0
  local out; out="$(_run_agent 2>&1)"; local rc=$?
  assert_eq '1' "$rc"
  assert_contains "$out" 'bundle could not be staged'
  assert_contains "$(_status_posts)" '"update_error":"bundle could not be staged"'
}

# ---------------------------------------------------------------------------
# A failed apply
# ---------------------------------------------------------------------------

test_a_failed_apply_is_reported_with_the_version_that_survived() {
  _install_agent 1.0.0 1.1.0
  _manifest apply 1.1.0
  export APPLY_RC=1
  local rc; _run_agent >/dev/null 2>&1; rc=$?
  assert_eq '1' "$rc"
  local last; last="$(printf '%s\n' "$(_status_posts)" | tail -1)"
  assert_contains "$last" '"update_status":"failed"'
  assert_contains "$last" '"update_error":"update to 1.1.0 failed"'
  # pu_apply_bundle rolled back, so VERSION.txt still says 1.0.0 and that is
  # what the fleet must be told.
  assert_contains "$last" '"current_version":"1.0.0"'
}

test_a_failed_apply_reports_the_engines_reason_when_it_gives_one() {
  # "needs the full bundle" is an operator action, not a mystery to diagnose.
  _install_agent 1.0.0 1.1.0
  _manifest apply 1.1.0
  export APPLY_RC=1 APPLY_ERROR='needs the full bundle: missing pointy-edge:4'
  _run_agent >/dev/null 2>&1
  assert_contains "$(_status_posts | tail -1)" '"update_error":"needs the full bundle: missing pointy-edge:4"'
}

test_a_status_post_that_fails_does_not_fail_the_update() {
  # DOCUMENTED SHARP EDGE. report_status ends in `|| true`, which is right — an
  # update that worked must not be reported as failed because the uplink blinked.
  # The cost is that `fleet status` can under-report: a shop that succeeded but
  # could not say so stays "applying" until its next run. Treat the fleet view as
  # advisory, and confirm a batch against VERSION.txt or a diagnostics pull.
  _install_agent 1.0.0 1.1.0
  _manifest apply 1.1.0
  export AGENT_STATUS_RC=7
  assert_status 0 _run_agent >/dev/null 2>&1
  assert_contains "$(_order)" 'apply:1.0.0->1.1.0'
}

# ---------------------------------------------------------------------------
# Mode flags
# ---------------------------------------------------------------------------

test_the_agent_applies_in_auto_mode_by_default() {
  _install_agent 1.0.0 1.1.0
  _manifest apply 1.1.0
  _run_agent >/dev/null 2>&1
  assert_contains "$(_order)" 'mode=auto'
}

test_restart_and_live_can_be_forced_from_the_command_line() {
  _install_agent 1.0.0 1.1.0
  _manifest apply 1.1.0
  _run_agent --restart >/dev/null 2>&1
  assert_contains "$(_order)" 'mode=restart'
  : >"${PU_TEST_DIR}/order.log"
  installed_deploy 1.0.0
  _run_agent --live >/dev/null 2>&1
  assert_contains "$(_order)" 'mode=live'
}

test_an_unknown_flag_is_ignored_rather_than_fatal() {
  # This is invoked by a host timer that a future bundle may have re-registered
  # with different arguments; refusing to run would strand the shop.
  _install_agent 1.0.0 1.1.0
  _manifest apply 1.1.0
  assert_status 0 _run_agent --some-future-flag >/dev/null 2>&1
  assert_contains "$(_order)" 'apply:1.0.0->1.1.0'
}

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------

test_the_agent_refuses_to_run_outside_a_deploy_directory() {
  _install_agent 1.0.0 1.1.0
  rm -f .env
  local out; out="$(_run_agent 2>&1)"; local rc=$?
  assert_eq '1' "$rc"
  assert_contains "$out" '.env not found next to this script'
}

test_the_agent_refuses_to_run_without_a_relay_url() {
  _install_agent 1.0.0 1.1.0
  grep -v POINTY_RELAY_PUBLIC_API_URL .env >.env.tmp && mv .env.tmp .env
  local out; out="$(_run_agent 2>&1)"; local rc=$?
  assert_eq '1' "$rc"
  assert_contains "$out" 'POINTY_RELAY_PUBLIC_API_URL is not set'
}

test_the_agent_refuses_to_run_without_docker() {
  _install_agent 1.0.0 1.1.0
  local out rc
  out="$(PATH="$(farm_path)" _run_agent 2>&1)"; rc=$?
  assert_eq '1' "$rc"
  assert_contains "$out" 'docker not found on PATH'
}

test_the_agent_refuses_to_run_without_a_json_parser() {
  # It needs jq OR python3 to read the manifest; a host with neither cannot be
  # updated remotely and must say so rather than silently misparsing.
  _install_agent 1.0.0 1.1.0
  local out rc
  out="$(PATH="${PU_STUB_DIR}:$(farm_path jq python3 python)" _run_agent 2>&1)"; rc=$?
  assert_eq '1' "$rc"
  assert_contains "$out" 'need jq or python3 to parse relay responses'
}

test_the_manifest_is_parsed_correctly_without_jq() {
  # The python3 fallback is what most shop hosts actually use — jq is not in a
  # minimal Debian image — so it has to be exercised, not assumed.
  _install_agent 1.0.0 1.1.0
  _manifest apply 1.1.0
  PATH="${PU_STUB_DIR}:$(farm_path jq)" _run_agent >/dev/null 2>&1
  assert_contains "$(_order)" 'apply:1.0.0->1.1.0'
}

test_the_relay_url_is_used_without_a_trailing_slash() {
  # A trailing slash in .env would otherwise produce //v1/agent/manifest, which
  # some proxies reject and others route differently.
  _install_agent 1.0.0 1.1.0
  sed -i.bak 's|^POINTY_RELAY_PUBLIC_API_URL=.*|POINTY_RELAY_PUBLIC_API_URL=https://relay.example.test/|' .env
  rm -f .env.bak
  _manifest apply 1.1.0
  _run_agent >/dev/null 2>&1
  assert_called curl '*https://relay.example.test/v1/agent/manifest*'
  assert_not_called curl '*relay.example.test//v1*'
}

# ---------------------------------------------------------------------------
# Self-update
# ---------------------------------------------------------------------------

test_a_staged_new_agent_is_promoted_and_re_executed() {
  # Older bundles rewrote scripts in place, so they staged the replacement as
  # update-agent.sh.new. A shop that has not been updated since then still has
  # one waiting, and it has to be picked up.
  _install_agent 1.0.0 1.1.0
  cat >update-agent.sh.new <<'EOF'
#!/usr/bin/env bash
printf 'the promoted agent ran with args: %s\n' "$*"
EOF
  local out; out="$(_run_agent --check 2>&1)"
  assert_contains "$out" 'the promoted agent ran with args: --check'
  assert_no_file update-agent.sh.new
  assert_file_contains update-agent.sh 'the promoted agent ran'
}

test_promotion_happens_at_most_once_per_run() {
  # The promoted agent re-execs itself. Without the guard the two would hand off
  # to each other forever, and a shop's host timer would spin at 100% CPU.
  _install_agent 1.0.0 1.1.0
  cat >update-agent.sh.new <<'EOF'
#!/usr/bin/env bash
printf 'promoted\n' >>"${PU_TEST_DIR}/order.log"
if [ -f update-agent.sh.new ]; then printf 'staged-again\n' >>"${PU_TEST_DIR}/order.log"; fi
printf 'guard=%s\n' "${POINTY_AGENT_PROMOTED:-unset}" >>"${PU_TEST_DIR}/order.log"
EOF
  _run_agent >/dev/null 2>&1
  assert_contains "$(_order)" 'guard=1'
  assert_eq '1' "$(grep -c '^promoted$' "${PU_TEST_DIR}/order.log")"
}

test_a_run_with_the_guard_already_set_does_not_promote() {
  _install_agent 1.0.0 1.1.0
  _manifest hold ''
  printf 'should not run\n' >update-agent.sh.new
  POINTY_AGENT_PROMOTED=1 _run_agent >/dev/null 2>&1
  assert_file update-agent.sh.new
}

pu_run_tests "$@"
