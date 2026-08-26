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
#   * the lock is taken before the download, so the watchdog stands down for the
#     whole operation and two agents can never overlap;
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
_stub_curl_as_relay() {
  stub_script curl <<'EOF'
_out=""; _url=""; _body=""; _prev=""
for _a in "$@"; do
  case "$_prev" in
    -o) _out="$_a" ;;
    -d) _body="$_a" ;;
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
  *)
    [ "${AGENT_DOWNLOAD_RC:-0}" = 0 ] || exit "${AGENT_DOWNLOAD_RC}"
    cat "${PU_TEST_DIR}/bundle.zip" >"$_out"
    exit 0 ;;
esac
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
  local sha="${3:-}"
  [ -n "$sha" ] || sha="$(_sha256_of "${PU_TEST_DIR}/bundle.zip" 2>/dev/null || echo none)"
  cat >"${PU_TEST_DIR}/manifest.json" <<JSON
{"directive":"$1","assigned_version":"$2","bundle":{"path":"/v1/agent/artifacts/$2","sha256":"${sha}"}}
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
  return "\${APPLY_RC:-0}"
}
EOF
  _stub_docker_with_connector_state
  _stub_curl_as_relay
  _make_bundle_zip "${2:-1.1.0}"
}

_run_agent() { bash ./update-agent.sh "$@"; }
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

test_the_lock_is_taken_before_the_download_and_released_afterwards() {
  # The download can take a long time on a shop's connection. Holding the lock
  # across it is what stops the watchdog reconciling the stack halfway through.
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
  *) [ -f .update.lock ] && printf 'locked\n' >>"${PU_TEST_DIR}/order.log"
     cat "${PU_TEST_DIR}/bundle.zip" >"$_out"; exit 0 ;;
esac
EOF
  _run_agent >/dev/null 2>&1
  assert_contains "$(_order)" 'locked'
  assert_no_file .update.lock
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

test_a_download_that_fails_is_reported_and_nothing_is_applied() {
  _install_agent 1.0.0 1.1.0
  _manifest apply 1.1.0
  export AGENT_DOWNLOAD_RC=18
  local out; out="$(_run_agent 2>&1)"; local rc=$?
  assert_eq '1' "$rc"
  assert_contains "$out" 'bundle download failed'
  assert_contains "$(_status_posts)" '"update_error":"bundle download failed"'
  assert_eq '' "$(_order)"
}

test_the_download_is_resumable() {
  # Shops lose their connection mid-download routinely; without -C - every
  # attempt would start from zero and a large bundle might never complete.
  _install_agent 1.0.0 1.1.0
  _manifest apply 1.1.0
  _run_agent >/dev/null 2>&1
  assert_called curl '*-C -*artifacts*'
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
