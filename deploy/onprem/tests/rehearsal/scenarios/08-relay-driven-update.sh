#!/usr/bin/env bash
#
# The whole point of the exercise: updating a shop WITHOUT visiting it.
#
# Real relay, real Postgres, real operator CLI, real update agent, real Docker
# stack. An operator uploads a bundle, targets a channel, and a shop on the other
# end of a bad link picks it up and applies it. Everything in between — rollout
# gating, the connector token, checksum verification, status reporting — is the
# shipped code.
#
# The questions here are the ones that decide whether you can batch this:
#
#   * does PAUSED actually stop a shop taking an update? (the kill switch)
#   * does a canary list mean only those shops move?
#   * can you PIN a shop backwards to undo a bad release?
#   * does the relay refuse a bundle that arrived corrupted?
#   * and, above all, does `fleet status` TELL THE TRUTH — because on a fleet of
#     fifty, that view is the only thing you have. A shop that failed and reports
#     success is worse than a shop that failed loudly.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. ./lib.sh
RIG_SCENARIO="08-relay-driven-update"
rig_setup >/dev/null || exit 1
trap 'rig_teardown_shop; rig_relay_stop' EXIT

rig_step "standing up a relay and provisioning a shop on it"
rig_relay_start || { rig_summary; exit 1; }
rig_relay_provision || { rig_summary; exit 1; }

rig_step "installing the shop, pointed at that relay"
rig_install_shop 1.0.0 || { rig_summary; exit 1; }
rig_assert_eq "$RIG_RELAY_URL" "$(rig_env_value POINTY_RELAY_PUBLIC_API_URL)" \
  "the shop's .env points at the rehearsal relay"

# The agent reads this shop's token out of the connector container with
# `docker compose cp`, not `exec cat` — the connector image is FROM scratch and
# has no shell or coreutils in it at all. Read it the same way here, or the
# assertion tests the rig's assumptions rather than the shop's.
state_copy="${RIG_RUN_DIR}/connector-state.json"
rig_compose cp connector:/var/lib/pointy/relay-connector.json "$state_copy" >/dev/null 2>&1
rig_assert_contains "$(cat "$state_copy" 2>&1)" "$RIG_CONNECTOR_TOKEN" \
  "the connector holds the token the relay issued, readable the way the agent reads it"

rig_step "an agent run with nothing assigned"
out="$(rig_run_agent)"
rig_assert_contains "$out" "up to date" "the agent found nothing to do"
rig_assert_eq "idle" "$(rig_fleet_field update_status)" "and the relay was told the shop is idle"
rig_assert_eq "1.0.0" "$(rig_fleet_field current_version)" "the relay knows which release the shop runs"

rig_step "the operator uploads 1.1.0 and PAUSES the rollout"
rig_relay_cli artifacts upload --version 1.1.0 --bundle "$(rig_bundle_path 1.1.0)" >/dev/null
rig_relay_cli fleet set-version 1.1.0 --channel stable --rollout paused >/dev/null
out="$(rig_run_agent)"
# The kill switch has to work before anything else is worth trusting.
rig_assert_contains "$out" "up to date" "a paused rollout does not reach the shop"
rig_assert_eq "1.0.0" "$(rig_served_version)" "the shop is untouched"
rig_assert_eq "hold" "$(rig_fleet_field directive)" "the relay is telling it to hold"

rig_step "a channel target with no uploaded artifact is refused outright"
refusal="$(rig_relay_cli fleet set-version 9.9.9 --channel stable --rollout all)"
rig_assert_contains "$refusal" "artifact" \
  "the relay refuses to point a channel at a version it cannot serve"

rig_step "the operator canaries this one shop"
rig_relay_cli fleet set-version 1.1.0 --channel stable --rollout canary --canary "$RIG_INSTALLATION_ID" >/dev/null
rig_assert_eq "apply" "$(rig_fleet_field directive)" "the canary shop is now told to apply"

# --check is the preflight an operator runs before batching. It must be safe to
# run against a trading shop and must change nothing.
out="$(rig_run_agent --check)"
rig_assert_contains "$out" "update available: 1.0.0 -> 1.1.0" "--check reports what would happen"
rig_assert_contains "$out" "would download" "and does not apply it"
rig_assert_eq "1.0.0" "$(rig_served_version)" "--check left the shop alone"
rig_assert_no_file "${RIG_SHOP}/.update.lock" "--check did not even take the lock"

rig_step "the agent applies it, with tills trading throughout"
rig_load_start /api/ping
agent_log="${RIG_RUN_DIR}/agent-08.log"
rig_run_agent >"$agent_log" 2>&1
agent_rc=$?
rig_load_stop
rig_log "$(printf '%s requests, %s failed, largest gap %sms' \
  "$(rig_load_field total)" "$(rig_load_field failed)" "$(rig_load_field max_gap_ms)")"
rig_log "$(rig_load_breakdown)"

rig_assert_eq "0" "$agent_rc" "the agent reported success"
rig_assert_eq "0" "$(rig_load_field failed)" "a relay-driven update costs the shop nothing either"
rig_assert_eq "1.1.0" "$(rig_served_version)" "the shop is serving 1.1.0 — updated without anyone visiting it"
rig_assert_eq "1.1.0" "$(rig_installed_version)" "VERSION.txt records it"
rig_assert_eq "pointy-backend:1.1.0" \
  "$(docker inspect -f '{{.Config.Image}}' "$(rig_container_id backend)" 2>/dev/null)" \
  "the running container really is on the new image"

rig_step "does the fleet view tell the truth?"
rig_assert_eq "succeeded" "$(rig_fleet_field update_status)" "the relay was told the update succeeded"
rig_assert_eq "1.1.0" "$(rig_fleet_field current_version)" "and which release the shop now runs"
rig_log "fleet: $(rig_relay_cli fleet status | grep "$RIG_INSTALLATION_ID" | head -1)"

rig_step "a second agent run does nothing"
out="$(rig_run_agent)"
rig_assert_contains "$out" "up to date" "an up-to-date shop is a no-op, not a re-apply"
rig_assert_eq "idle" "$(rig_fleet_field update_status)" "and it says idle rather than staying 'succeeded' forever"

rig_step "PIN the shop backwards — the way you undo a bad release on a fleet"
rig_relay_cli artifacts upload --version 1.0.0 --bundle "$(rig_bundle_path 1.0.0)" >/dev/null
rig_relay_cli fleet pin "$RIG_INSTALLATION_ID" 1.0.0 >/dev/null
rig_load_start /api/ping
rig_run_agent >"${RIG_RUN_DIR}/agent-08-pin.log" 2>&1
pin_rc=$?
rig_load_stop
rig_assert_eq "0" "$pin_rc" "the agent applied the pinned older release"
rig_assert_eq "1.0.0" "$(rig_served_version)" "the shop went BACKWARDS to 1.0.0 — a remote rollback"
rig_assert_eq "0" "$(rig_load_field failed)" "and the downgrade cost the shop nothing"
rig_assert_eq "1.0.0" "$(rig_fleet_field current_version)" "the relay knows it went back"

rig_step "a bundle that arrives corrupted is never applied"
# Corrupt the stored blob so what the relay SERVES no longer matches the sha256
# it recorded at upload. This is the last line of defence between a damaged
# download — or a tampered one — and `docker load` on a shop's machine.
rig_relay_cli fleet unpin "$RIG_INSTALLATION_ID" >/dev/null
rig_relay_cli fleet set-version 1.1.0 --channel stable --rollout all >/dev/null
# Overwrite bytes IN PLACE rather than appending: the store records each
# artifact's size and serves exactly that many bytes, so appending changes
# nothing about what a shop receives. (Worth knowing on its own — a truncated
# upload would be caught by the size, an altered one only by the checksum.)
# The store keeps one bundle per version at <dir>/<version>/bundle.zip, so name
# the version explicitly — picking "some large file under the artifact dir" would
# happily corrupt a DIFFERENT release and the test would pass for the wrong
# reason (which it did, once).
blob="${RIG_RELAY_ARTIFACTS}/1.1.0/bundle.zip"
if [ -f "$blob" ]; then
  rig_log "corrupting the stored bundle in place: $(basename "$blob")"
  printf 'CORRUPTED-BY-THE-REHEARSAL' | dd of="$blob" bs=1 seek=4096 conv=notrunc 2>/dev/null
  rig_load_start /api/ping
  out="$(rig_run_agent 2>&1)"
  corrupt_rc=$?
  rig_load_stop
  rig_assert_ne "0" "$corrupt_rc" "the agent refused the corrupted bundle"
  rig_assert_contains "$out" "sha256 mismatch" "and said exactly why"
  rig_assert_eq "1.0.0" "$(rig_served_version)" "the shop was never touched"
  rig_assert_eq "0" "$(rig_load_field failed)" "and kept trading throughout"

  rig_step "and the fleet view does not claim a version the shop never got"
  # THE ASSERTION THAT DECIDES WHETHER YOU CAN BATCH. If a shop that failed
  # reported the new version, it would vanish from the "still to do" list, the
  # agent would see assigned == current and stop retrying, and the rollout would
  # read as complete with shops silently left behind.
  rig_assert_eq "1.0.0" "$(rig_fleet_field current_version)" \
    "the relay still shows 1.0.0 — the failed release was NOT recorded as installed"
  rig_assert_eq "failed" "$(rig_fleet_field update_status)" "the shop is visibly flagged as failed"
else
  rig_fail "could not find the stored artifact to corrupt"
fi

rig_step "and the shop still takes the next good update"
# Re-upload a clean copy over the corrupted one.
rig_relay_cli artifacts upload --version 1.1.0 --bundle "$(rig_bundle_path 1.1.0)" >/dev/null
rig_run_agent >"${RIG_RUN_DIR}/agent-08-recover.log" 2>&1
rig_assert_eq "0" "$?" "the agent retried and succeeded once the bundle was fixed"
rig_assert_eq "1.1.0" "$(rig_served_version)" "the shop recovered onto 1.1.0 with no site visit"
rig_assert_eq "succeeded" "$(rig_fleet_field update_status)" "and the fleet view caught up"

rig_summary
