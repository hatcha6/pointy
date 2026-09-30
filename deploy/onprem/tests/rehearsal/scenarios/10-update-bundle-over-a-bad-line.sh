#!/usr/bin/env bash
#
# The fleet's actual update path, on the kind of line a Libyan shop has.
#
# On 2026-09-30 a shop sat on "applying" for six hours: the agent downloaded a
# 1.1 GB bundle into a fresh temp dir every run, so nothing a dropped connection
# had delivered was ever kept, and the bundle carried half a gigabyte a running
# shop never uses. This rehearses the fix end to end, against a real installed
# shop on real Docker:
#
#   * the relay serves the UPDATE bundle (make-update-bundle.sh): no WSL pieces,
#     no infrastructure images — does a real live update still work without them?
#   * the agent is stopped mid-download, as a reboot or a sleeping PC would —
#     does the next run continue the same file rather than start over?
#   * does `fleet status` show the download instead of an "applying" that says
#     nothing, and is the update lock left alone while it downloads?
#   * a shop that lacks an infrastructure image the update bundle does not carry
#     — is it refused before anything changes, and does it then go through
#     without downloading the bundle again?
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. ./lib.sh
RIG_SCENARIO="10-update-bundle-over-a-bad-line"
rig_setup >/dev/null || exit 1
trap 'rig_teardown_shop; rig_relay_stop' EXIT

rig_step "standing up a relay and a shop on 1.0.0"
rig_relay_start || { rig_summary; exit 1; }
rig_relay_provision || { rig_summary; exit 1; }
rig_install_shop 1.0.0 || { rig_summary; exit 1; }

rig_step "deriving the fleet update bundle from the full 1.1.0 bundle"
full_zip="$(rig_bundle_path 1.1.0)"
update_zip="${RIG_RUN_DIR}/pointy-update-1.1.0.zip"
bash "${RIG_ONPREM_DIR}/make-update-bundle.sh" "$full_zip" "$update_zip" >"${RIG_RUN_DIR}/make-update.log" 2>&1
rig_assert_eq "0" "$?" "make-update-bundle.sh built it"
infra_left="$(unzip -Z1 "$update_zip" | grep -cE '/images/(postgres|redis|pgbouncer|pointy-edge)\.tar$')"
rig_assert_eq "0" "$infra_left" "it carries no infrastructure image"
full_bytes="$(wc -c <"$full_zip" | tr -d ' ')"
update_bytes="$(wc -c <"$update_zip" | tr -d ' ')"
rig_log "full bundle ${full_bytes} bytes, update bundle ${update_bytes} bytes"
rig_assert_le "$update_bytes" "$(( full_bytes * 3 / 4 ))" "and is much smaller than the full bundle"

rig_relay_cli artifacts upload --version 1.1.0 --bundle "$update_zip" >/dev/null
rig_relay_cli fleet set-version 1.1.0 --channel stable --rollout all >/dev/null

infra_before=""
for service in postgres redis pgbouncer edge; do
  infra_before="${infra_before} ${service}=$(rig_container_id "$service")"
done

rig_step "the agent is stopped mid-download, as a reboot would stop it"
# Slow enough that the download is still going when the agent is stopped.
rate=$(( update_bytes / 12 )); [ "$rate" -ge 20000 ] || rate=20000
# exec, so the pid is the agent's own and the signal reaches the agent — not a
# subshell that would die and leave the agent downloading behind it.
( cd "$RIG_SHOP" && POINTY_UPDATE_RATE_LIMIT="$rate" exec bash update-agent.sh ) \
  >"${RIG_RUN_DIR}/agent-10-cut.log" 2>&1 &
agent_pid=$!
sleep 4
rig_assert_no_file "${RIG_SHOP}/.update.lock" "the update lock is not held while downloading"
kill -TERM "$agent_pid" 2>/dev/null
wait "$agent_pid" 2>/dev/null
partial="$(ls "${RIG_SHOP}"/downloads/bundle-*.zip.part 2>/dev/null | head -1)"
partial_bytes=0; [ -n "$partial" ] && partial_bytes="$(wc -c <"$partial" | tr -d ' ')"
rig_log "stopped with ${partial_bytes} of ${update_bytes} bytes downloaded"
rig_assert_ge "$partial_bytes" 1 "what was downloaded is kept on disk"
rig_assert_le "$partial_bytes" "$(( update_bytes - 1 ))" "and it really was cut short"
rig_assert_eq "" "$(pgrep -f "curl.*${RIG_RELAY_HTTP_PORT}/v1/agent/artifacts" || true)" \
  "stopping the agent stopped its download"
rig_assert_contains "$(rig_fleet_field update_status)" "downloading" \
  "fleet status shows the download, not a bare 'applying'"
rig_assert_eq "1.0.0" "$(rig_served_version)" "the shop is untouched"

rig_step "the next run resumes the same file and applies it live, tills trading"
rig_load_start /api/ping
rig_run_agent >"${RIG_RUN_DIR}/agent-10.log" 2>&1
agent_rc=$?
rig_load_stop
rig_log "$(printf '%s requests, %s failed, largest gap %sms' \
  "$(rig_load_field total)" "$(rig_load_field failed)" "$(rig_load_field max_gap_ms)")"
rig_assert_eq "0" "$agent_rc" "the agent reported success"
rig_assert_contains "$(cat "${RIG_RUN_DIR}/agent-10.log")" "resuming the download at" \
  "it continued the interrupted download instead of starting over"
rig_assert_eq "0" "$(rig_load_field failed)" "the update cost the tills nothing"
rig_assert_eq "1.1.0" "$(rig_served_version)" "the shop serves 1.1.0 from the update bundle"
infra_after=""
for service in postgres redis pgbouncer edge; do
  infra_after="${infra_after} ${service}=$(rig_container_id "$service")"
done
rig_assert_eq "$infra_before" "$infra_after" \
  "postgres, redis, pgbouncer and the front door are the same containers"
rig_assert_eq "" "$(ls "${RIG_SHOP}/downloads" 2>/dev/null | grep -v '^\.' || true)" \
  "the download is cleaned up once the shop runs the version"
rig_assert_eq "succeeded" "$(rig_fleet_field update_status)" "and the relay was told"

rig_step "a shop missing an infrastructure image the update bundle does not carry"
update_zip_12="${RIG_RUN_DIR}/pointy-update-1.2.0.zip"
bash "${RIG_ONPREM_DIR}/make-update-bundle.sh" "$(rig_bundle_path 1.2.0)" "$update_zip_12" >/dev/null 2>&1
rig_relay_cli artifacts upload --version 1.2.0 --bundle "$update_zip_12" >/dev/null
rig_relay_cli fleet set-version 1.2.0 --channel stable --rollout all >/dev/null
# As if a release had bumped the front door and this shop skipped it.
cp "${RIG_SHOP}/.env" "${RIG_RUN_DIR}/env.before-refusal"
sed -i.bak 's|^POINTY_EDGE_IMAGE=.*|POINTY_EDGE_IMAGE=pointy-edge:0-not-on-this-machine|' "${RIG_SHOP}/.env"
rm -f "${RIG_SHOP}/.env.bak"
backups_before="$(ls "${RIG_SHOP}/backups" 2>/dev/null | wc -l | tr -d ' ')"
out="$(rig_run_agent)"
refused_rc=$?
rig_assert_ne "0" "$refused_rc" "the update is refused"
rig_assert_contains "$out" "pointy-onprem-1.2.0.zip" "and the operator is told to send the full bundle"
rig_assert_contains "$(rig_fleet_field update_error)" "needs the full bundle: missing pointy-edge:0-not-on-this-machine" \
  "fleet status says exactly what is missing"
rig_assert_eq "1.1.0" "$(rig_served_version)" "the shop was never touched"
rig_assert_eq "1.1.0" "$(rig_installed_version)" "VERSION.txt did not move"
rig_assert_eq "$backups_before" "$(ls "${RIG_SHOP}/backups" 2>/dev/null | wc -l | tr -d ' ')" \
  "it was refused before even the database backup"

rig_step "once the image is there, the retry costs the shop no second download"
cp "${RIG_RUN_DIR}/env.before-refusal" "${RIG_SHOP}/.env"
rig_load_start /api/ping
rig_run_agent >"${RIG_RUN_DIR}/agent-10-retry.log" 2>&1
retry_rc=$?
rig_load_stop
rig_assert_eq "0" "$retry_rc" "the retry succeeded"
rig_assert_contains "$(cat "${RIG_RUN_DIR}/agent-10-retry.log")" "already downloaded" \
  "from the download it had already verified"
rig_assert_eq "1.2.0" "$(rig_served_version)" "the shop serves 1.2.0"
rig_assert_eq "0" "$(rig_load_field failed)" "with the tills trading throughout"

rig_summary
