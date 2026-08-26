#!/usr/bin/env bash
#
# The headline claim: a shop can be updated in the middle of the trading day and
# no till notices.
#
# "No till notices" is not a before/after check. It means: not one request
# refused, not one 5xx, no gap long enough for a cashier to see a spinner, a
# request already in flight when the front door reloads still completes, and the
# hand-over happens exactly once rather than flapping. It also means the things
# that must NOT move — the database, the cache, the pooler, the front door
# itself — were not touched, because recreating any of them IS the outage this
# whole design exists to avoid.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. ./lib.sh
RIG_SCENARIO="01-live-update-under-load"
rig_setup >/dev/null || exit 1
trap 'rig_teardown_shop' EXIT

rig_step "installing a shop on 1.0.0"
rig_install_shop 1.0.0 || { rig_summary; exit 1; }

# Everything that must survive the update untouched. Container IDs, not names:
# a recreate keeps the name and changes the ID, which is exactly what we are
# watching for.
infra_before=""
for service in postgres redis pgbouncer edge; do
  infra_before="${infra_before}${service}=$(rig_container_id "$service") "
done
edge_started_before="$(docker inspect -f '{{.State.StartedAt}}' "$(rig_container_id edge)" 2>/dev/null)"
edge_restarts_before="$(docker inspect -f '{{.RestartCount}}' "$(rig_container_id edge)" 2>/dev/null)"

rig_assert_eq "1.0.0" "$(rig_served_version)" "the shop is serving 1.0.0 before the update"
rig_assert_eq "backend" "$(rig_upstream)" "the front door points at the managed backend"

rig_step "putting a till's worth of traffic through the front door"
rig_load_start /api/ping

# A request deliberately still in flight when nginx is reloaded. A graceful
# reload must finish it on the old worker; anything less and a cashier loses a
# sale mid-checkout.
slow_out="${RIG_RUN_DIR}/slow-request.txt"
( curl -sS --max-time 60 "$(rig_url '/slow?ms=9000')" >"$slow_out" 2>&1; printf '%s' "$?" >"${slow_out}.rc" ) &
slow_pid=$!
sleep 1

rig_step "updating 1.0.0 -> 1.1.0 live"
update_log="${RIG_RUN_DIR}/update-01.log"
started="$(date +%s)"
( cd "$RIG_SHOP" && bash update.sh "$(rig_bundle_path 1.1.0)" ) >"$update_log" 2>&1
update_rc=$?
elapsed=$(( $(date +%s) - started ))
rig_log "update finished in ${elapsed}s (exit ${update_rc})"

wait "$slow_pid" 2>/dev/null
rig_load_stop

# ---------------------------------------------------------------------------
# Did a till notice?
# ---------------------------------------------------------------------------
rig_step "what the tills saw"
total="$(rig_load_field total)"
failed="$(rig_load_field failed)"
refused="$(rig_load_field connection_refused)"
streak="$(rig_load_field longest_failure_streak)"
gap="$(rig_load_field max_gap_ms)"
rig_log "$(printf '%s requests, %s failed, %s refused, longest failure streak %s, largest gap %sms' \
  "$total" "$failed" "$refused" "$streak" "$gap")"
rig_log "$(rig_load_breakdown)"
rig_log "hand-over: $(rig_load_transitions)"

rig_assert_eq "0" "$update_rc" "update.sh reported success"
rig_assert_ge "${total:-0}" 200 "enough traffic went through to mean anything"
rig_assert_eq "0" "${failed:-1}" "not one request failed during the update"
rig_assert_eq "0" "${refused:-1}" "not one connection was refused"
rig_assert_eq "0" "${streak:-1}" "there was never a moment with no healthy backend"
# A till polls a few times a second. A gap it could actually perceive is the
# thing to catch, not a millisecond of jitter.
rig_assert_le "${gap:-99999}" 2000 "no gap a cashier could see (<=2s between successful responses)"
RIG_MAX_GAP_MS=2000 rig_assert_shop_never_went_down "during a live update"

# THE hand-over question.
#
# Not "exactly three transitions": an nginx reload is graceful, so several
# keep-alive workers legitimately see the old upstream and the new one
# interleaved until the old connections retire. What must be true is that the
# shop only ever served these two releases, in this order, from these two
# containers — and that it ENDED on the managed backend, because the standby is
# a one-off container with no restart policy that would not survive the night.
rig_assert_eq "1.0.0 1.1.0" "$(rig_load_versions_seen)" \
  "the shop served exactly two releases, old then new — it never went back"
rig_assert_eq "backend pointy-backend-standby" "$(rig_load_upstreams_seen)" \
  "traffic only ever came from the managed backend and the standby"
rig_assert_eq "backend" "$(rig_load_final_upstream)" \
  "the last request was served by the managed backend, not the temporary standby"
rig_assert_eq "1.1.0" "$(rig_load_final_version)" "the last request was served by the new release"

# The window where two releases answered at once. This is the expand/contract
# window in the flesh — for this long, two app versions share one database — so
# report the number rather than assume it is small, and fail if it is not.
overlap="$(rig_load_overlap_ms 1.0.0 1.1.0)"
rig_log "two releases answered at once for ${overlap}ms (the expand/contract window)"
rig_assert_ge "${overlap:--1}" 0 "the overlap window was measurable"
rig_assert_le "${overlap:-99999}" 5000 \
  "the two-versions-at-once window stayed short (<=5s of shared-database time)"

rig_assert_eq "0" "$(cat "${slow_out}.rc" 2>/dev/null || echo 1)" \
  "a request already in flight when the front door reloaded still completed"
rig_assert_contains "$(cat "$slow_out" 2>/dev/null)" "end " \
  "the in-flight request received its full response body"

# ---------------------------------------------------------------------------
# Did the update actually take effect?
# ---------------------------------------------------------------------------
rig_step "is the new release really the one serving?"
rig_assert_eq "1.1.0" "$(rig_served_version)" "the shop now serves 1.1.0"
rig_assert_eq "backend" "$(rig_upstream)" "traffic is back on the managed backend, not the standby"
rig_assert_eq "1.1.0" "$(rig_installed_version)" "VERSION.txt records 1.1.0"

# The .env pin is a `sed` that only substitutes an EXISTING line, so it can
# silently do nothing. Asking the running container what image it is on is the
# only answer that cannot be faked by a successful-looking log.
rig_assert_eq "pointy-backend:1.1.0" \
  "$(docker inspect -f '{{.Config.Image}}' "$(rig_container_id backend)" 2>/dev/null)" \
  "the backend container is actually running the 1.1.0 image"
rig_assert_eq "pointy-relay:1.1.0" \
  "$(docker inspect -f '{{.Config.Image}}' "$(rig_container_id connector)" 2>/dev/null)" \
  "the connector was moved to 1.1.0 too"
rig_assert_eq "pointy-web:1.1.0" \
  "$(docker inspect -f '{{.Config.Image}}' "$(rig_container_id web)" 2>/dev/null)" \
  "the web app was moved to 1.1.0 too"
rig_assert_eq "pointy-backend:1.1.0" \
  "$(docker inspect -f '{{.Config.Image}}' "$(rig_container_id celery-worker)" 2>/dev/null)" \
  "the background workers were moved to 1.1.0 too"
rig_assert_eq "pointy-backend:1.1.0" "$(rig_env_value POINTY_BACKEND_IMAGE)" \
  ".env pins the new backend image"

# ---------------------------------------------------------------------------
# Was anything touched that must never be touched?
# ---------------------------------------------------------------------------
rig_step "did the infrastructure survive untouched?"
infra_after=""
for service in postgres redis pgbouncer edge; do
  infra_after="${infra_after}${service}=$(rig_container_id "$service") "
done
rig_assert_eq "$infra_before" "$infra_after" \
  "postgres, redis, pgbouncer and the front door are the SAME containers (never recreated)"
rig_assert_eq "$edge_started_before" \
  "$(docker inspect -f '{{.State.StartedAt}}' "$(rig_container_id edge)" 2>/dev/null)" \
  "the front door was never restarted — it held the LAN port throughout"
rig_assert_eq "$edge_restarts_before" \
  "$(docker inspect -f '{{.RestartCount}}' "$(rig_container_id edge)" 2>/dev/null)" \
  "the front door never crashed and restarted"

rig_step "housekeeping"
rig_assert_no_file "${RIG_SHOP}/.update.lock" "the update lock was released"
rig_assert_eq "" "$(docker ps -aq -f name=pointy-backend-standby 2>/dev/null)" \
  "the temporary standby container was removed"
rig_assert_file "${RIG_SHOP}/backups/pre-update-1.0.0-to-1.1.0.sql" \
  "a database backup was taken before the migrations ran"

# Application archives are destroyed once Docker has them; third-party ones are
# left for the next maintenance restart.
rig_assert_eq "" "$(ls "${RIG_SHOP}/images/"pointy-backend-*.tar 2>/dev/null)" \
  "the new release's backend archive was shredded after loading"
rig_assert_file "${RIG_SHOP}/images/redis.tar" "the redis archive is staged for the next restart"
rig_assert_file "${RIG_SHOP}/images/pointy-edge.tar" "the front door archive is staged, never loaded live"
rig_assert_contains "$(cat "$update_log")" "staged for the next maintenance restart" \
  "the operator was told which infrastructure is waiting"

# Does the prune actually prune? `docker image rm` is deliberately not forced, so
# it refuses while ANY container still references the image — including a stopped
# one. If that were the normal outcome, a shop would quietly accumulate every
# release it has ever run, and the function meant to stop that would be doing
# nothing while logging that it had. On a till with a small disk that is a real
# way to die, months later, for no visible reason.
rig_assert_contains "$(cat "$update_log")" "removed the superseded image pointy-backend:1.0.0" \
  "the superseded backend image was really removed, not merely 'kept'"
rig_assert_eq "" "$(docker image inspect pointy-backend:1.0.0 --format '{{.Id}}' 2>/dev/null)" \
  "and it is genuinely gone from Docker's store"
rig_assert_eq "" "$(docker image inspect pointy-web:1.0.0 --format '{{.Id}}' 2>/dev/null)" \
  "so is the superseded web image"
# The front door's image is shared across releases and hand-bumped; pruning it
# would destroy the container holding the LAN port.
rig_assert_ne "" "$(docker image inspect "$RIG_EDGE_IMAGE" --format '{{.Id}}' 2>/dev/null)" \
  "the front door's image was left alone"

# The front door's own report and the file on disk have to agree; the watchdog
# recovers a half-finished update by parsing this file.
rig_assert_contains "$(cat "${RIG_SHOP}/edge/active/upstream.conf")" 'set $pointy_upstream_name "backend";' \
  "the on-disk upstream pointer agrees with what the front door reports"

rig_summary
