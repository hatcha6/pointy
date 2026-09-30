#!/usr/bin/env bash
#
# Pointy on-prem remote update agent (Linux / macOS hosts).
#
# Polls the relay for the version this installation should run and, when a newer
# one is assigned, downloads the bundle FROM THE RELAY (shops never need GitHub or
# a registry), verifies it, backs up the database, applies it, health-checks the
# result, and rolls back automatically on failure — so we update a shop without
# visiting it.
#
# It applies updates LIVE by default (see update-lib.sh): the new backend is
# brought up beside the running one and only takes traffic once it has answered
# /readyz, so a shop can be updated in the middle of the trading day without a
# till noticing. That matters most here — this agent fires on a timer, and
# before it could do that safely the only responsible schedule was "after
# hours". Releases that cannot be applied that way say so in the bundle and get
# a full restart instead.
#
# It runs as a host timer next to watchdog.sh and is deliberately independent of
# the backend it updates: even an update that breaks the backend leaves this
# agent able to fetch a rollback target from the relay and re-apply.
#
# Run it manually with --check to see what it WOULD do without applying:
#     bash update-agent.sh --check
#
set -uo pipefail
# Everything below is relative to the deploy directory, including a few rm -rf.
cd "$(dirname "$0")" || exit 1

# Self-update first: older bundles staged the new agent as update-agent.sh.new
# (they rewrote scripts in place, so a running one could not be replaced
# safely). Promote it and re-exec. Current bundles install scripts by atomic
# rename instead, which leaves this running process on its own inode.
if [ -f update-agent.sh.new ] && [ "${POINTY_AGENT_PROMOTED:-}" != "1" ]; then
  mv -f update-agent.sh.new update-agent.sh
  chmod +x update-agent.sh 2>/dev/null || true
  export POINTY_AGENT_PROMOTED=1
  exec bash ./update-agent.sh "$@"
fi

POINTY_LOG_TAG="pointy-update-agent"
# shellcheck source=update-lib.sh
. ./update-lib.sh

AGENT_VERSION="pointy-update-agent/2"
DRY_RUN=0
MODE=auto
for arg in "$@"; do
  case "$arg" in
    --check) DRY_RUN=1 ;;
    --restart) MODE=restart ;;
    --live) MODE=live ;;
  esac
done

fail() { pu_log "ERROR: $*"; exit 1; }

command -v docker >/dev/null 2>&1 || fail "docker not found on PATH"
[ -f .env ] || fail ".env not found next to this script"
if ! command -v jq >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
  fail "need jq or python3 to parse relay responses"
fi

# jget <json-file> <dotted.path> — extract a field with jq, else python3.
jget() {
  local file="$1" path="$2"
  if command -v jq >/dev/null 2>&1; then
    jq -r "${path} // empty" "$file" 2>/dev/null
    return
  fi
  python3 - "$file" "$path" <<'PY'
import sys, json
path = sys.argv[2].lstrip('.').split('.')
try:
    with open(sys.argv[1]) as handle:
        value = json.load(handle)
    for key in path:
        value = value[key]
    print('' if value is None else value)
except Exception:
    print('')
PY
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

RELAY_URL="$(pu_env_value POINTY_RELAY_PUBLIC_API_URL)"
RELAY_URL="${RELAY_URL%/}"
[ -n "$RELAY_URL" ] || fail "POINTY_RELAY_PUBLIC_API_URL is not set in .env"

CURRENT_VERSION="$(pu_current_version)"

# Read this installation's connector token from the connector container. `docker
# cp` reads the container filesystem directly, so it works even though the
# connector image is `scratch` (no shell to exec into).
STATE_FILE="$(mktemp)"
# The trap has to be armed before the lock is taken, so that an early exit still
# cleans up STATE_FILE. That means cleanup runs on paths where this process
# never owned the lock — including the one where it stood down BECAUSE another
# update holds it — so releasing unconditionally would unlink the other
# updater's lock, let the watchdog reconcile the stack mid-flip, and leave the
# next timer tick free to start a second concurrent update.
LOCK_HELD=0
DOWNLOAD_LOCK_HELD=0
CURL_PID=""
cleanup() {
  rm -f "$STATE_FILE"
  # A stopped agent (systemd stop, a reboot) must not leave curl writing on.
  # What it downloaded so far stays in ./downloads for the next run.
  [ -n "$CURL_PID" ] && kill "$CURL_PID" 2>/dev/null
  rm -f "${DOWNLOAD_DIR:-downloads}/.http-code"
  # Everything unpacked out of the bundle carries the same image archives as
  # ./images, so it goes the same way rather than merely unlinked.
  if [ -n "${POINTY_BUNDLE_STAGING:-}" ]; then
    pu_shred_staged_archives "$POINTY_BUNDLE_STAGING"
    rm -rf "$POINTY_BUNDLE_STAGING"
  fi
  [ "$LOCK_HELD" = 1 ] && pu_release_lock
  [ "$DOWNLOAD_LOCK_HELD" = 1 ] && rm -f "$DOWNLOAD_LOCK"
  return 0
}
trap cleanup EXIT
trap 'exit 143' TERM INT

if ! pu_compose cp connector:/var/lib/pointy/relay-connector.json "$STATE_FILE" >/dev/null 2>&1; then
  pu_log "connector state unavailable yet (still bootstrapping?); retrying next run"
  exit 0
fi
CONNECTOR_TOKEN="$(jget "$STATE_FILE" .connector_token)"
[ -n "$CONNECTOR_TOKEN" ] || fail "connector token not found in connector state"

auth_header="X-Pointy-Connector-Token: ${CONNECTOR_TOKEN}"

report_status() { # report_status <current_version> <status> <error>
  curl -fsS -X POST \
    -H "$auth_header" \
    -H "Content-Type: application/json" \
    -d "{\"current_version\":\"$1\",\"agent_version\":\"${AGENT_VERSION}\",\"update_status\":\"$2\",\"update_error\":\"$3\"}" \
    "${RELAY_URL}/v1/agent/status" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Release signature verification.
#
# The sha256 in the manifest proves the download was not corrupted; it proves
# nothing about WHO produced it, because the same relay serves both. A relay
# compromise or a leaked agent token is otherwise remote code execution on every
# shop, with no second gate. The signature is that second gate: it is made with a
# key that never touches the relay.
#
# We sign the 64-char sha256 hex, not the multi-GB zip — same binding, trivial
# verification cost. Empty key = verification disabled (the pre-signing state);
# once POINTY_RELEASE_PUBKEY is filled in, an unsigned or badly-signed bundle is
# REFUSED. See deploy/onprem/SIGNING.md.
# ---------------------------------------------------------------------------
POINTY_RELEASE_PUBKEY="${POINTY_RELEASE_PUBKEY:-}"

verify_bundle_signature() {
  local digest="$1" signature_b64="$2" key sig msg rc

  if [ -z "$POINTY_RELEASE_PUBKEY" ]; then
    pu_log "WARNING: no release public key configured — bundle authenticity NOT verified."
    return 0
  fi
  command -v openssl >/dev/null 2>&1 \
    || fail "openssl is required to verify the release signature but is not installed"
  [ -n "$signature_b64" ] \
    || fail "bundle carries no signature but a release key is configured — refusing to apply"

  key="$(mktemp)"; sig="$(mktemp)"; msg="$(mktemp)"
  printf '%s\n' "$POINTY_RELEASE_PUBKEY" >"$key"
  printf '%s' "$digest" >"$msg"
  if ! printf '%s' "$signature_b64" | base64 -d >"$sig" 2>/dev/null; then
    rm -f "$key" "$sig" "$msg"
    fail "release signature is not valid base64 — refusing to apply"
  fi
  openssl pkeyutl -verify -pubin -inkey "$key" -rawin -in "$msg" -sigfile "$sig" >/dev/null 2>&1
  rc=$?
  rm -f "$key" "$sig" "$msg"
  if [ "$rc" -ne 0 ]; then
    return 1
  fi
  pu_log "release signature verified"
  return 0
}

# ---------------------------------------------------------------------------
# Downloading.
#
# A bundle is hundreds of MB, and a Libyan shop line moves that in hours and
# rarely without a break: the line drops, the PC sleeps, WSL stops the distro.
# So the download is built to finish across many attempts, not in one:
#
#   * it lives in ./downloads under a name taken from the bundle's sha256 — not
#     a temp dir — so every run continues the same file (curl -C -);
#   * within a run, a dropped or stalled connection (--speed-limit) is retried
#     in place, with backoff;
#   * a run stops after POINTY_UPDATE_DOWNLOAD_BUDGET seconds and exits 0; the
#     next timer run resumes, and sees any change to the rollout meanwhile;
#   * progress is reported to the relay, so `fleet status` shows
#     "downloading 43%" instead of an "applying" that says nothing;
#   * a verified download is kept until the shop runs that version, so a failed
#     apply is retried without downloading again. A different assignment
#     discards it.
#
# POINTY_UPDATE_RATE_LIMIT (curl syntax, e.g. 200k) caps the speed, for a shop
# whose line should stay free for the tills while the update trickles in.
# ---------------------------------------------------------------------------
DOWNLOAD_DIR="downloads"
DOWNLOAD_LOCK="${DOWNLOAD_DIR}/.lock"

agent_setting() { # agent_setting <KEY> <default> — environment, then .env
  local value="${!1:-}"
  [ -n "$value" ] || value="$(pu_env_value "$1")"
  printf '%s' "${value:-$2}"
}
DOWNLOAD_BUDGET="$(agent_setting POINTY_UPDATE_DOWNLOAD_BUDGET 3600)"
DOWNLOAD_ATTEMPTS="$(agent_setting POINTY_UPDATE_DOWNLOAD_ATTEMPTS 40)"
PROGRESS_INTERVAL="$(agent_setting POINTY_UPDATE_PROGRESS_INTERVAL 300)"
RATE_LIMIT="$(agent_setting POINTY_UPDATE_RATE_LIMIT '')"
LAST_PROGRESS_REPORT=$SECONDS

# A wait a stop signal cuts short. Bash runs a trap only once the foreground
# command returns, so a plain `sleep 120` would hold a `systemctl stop` (or a
# shutdown) for two minutes; `wait` returns at once.
pause() { sleep "$1" & wait $!; }

file_bytes() {
  [ -f "$1" ] || { printf '0'; return; }
  stat -c %s "$1" 2>/dev/null || stat -f %z "$1" 2>/dev/null || printf '0'
}

mb() { printf '%d' $(( ($1 + 524288) / 1048576 )); }

progress_text() { # progress_text <bytes> — "480 of 1130 MB"
  if [ "$BUNDLE_SIZE" -gt 0 ]; then
    printf '%s of %s MB' "$(mb "$1")" "$(mb "$BUNDLE_SIZE")"
  else
    printf '%s MB' "$(mb "$1")"
  fi
}

downloading_status() {
  local have; have="$(file_bytes "${BUNDLE_FILE}.part")"
  if [ "$BUNDLE_SIZE" -gt 0 ]; then
    printf 'downloading %d%%' $(( have * 100 / BUNDLE_SIZE ))
  else
    printf 'downloading %s MB' "$(mb "$have")"
  fi
}

# One agent downloads at a time. A pid, not an age: a download legitimately
# runs for hours, and a dead holder (killed run, reboot) must not block the next.
acquire_download_lock() { # acquire_download_lock [quiet]
  local pid
  if [ -f "$DOWNLOAD_LOCK" ]; then
    pid="$(sed -n 's/^pid=\([0-9][0-9]*\).*/\1/p' "$DOWNLOAD_LOCK" 2>/dev/null)"
    if [ -n "$pid" ] && [ "$pid" != "$$" ] && kill -0 "$pid" 2>/dev/null; then
      [ "${1:-}" = quiet ] || pu_log "another agent run is already downloading (pid ${pid}); nothing to do"
      return 1
    fi
  fi
  printf 'pid=%s started=%s\n' "$$" "$(date '+%Y-%m-%dT%H:%M:%S')" >"$DOWNLOAD_LOCK"
}

# prune_downloads <keep> — discard every download but <keep> (and its .part).
prune_downloads() {
  local file
  for file in "${DOWNLOAD_DIR}"/bundle-*; do
    [ -f "$file" ] || continue
    [ -n "$1" ] && { [ "$file" = "$1" ] || [ "$file" = "$1.part" ]; } && continue
    pu_log "discarding $(basename "$file")"
    pu_shred_file "$file"
  done
}

# run_curl <part> — one resumable attempt. Reports progress while it runs and
# leaves the HTTP status in CURL_HTTP_CODE.
run_curl() {
  local part="$1" code_file="${DOWNLOAD_DIR}/.http-code" rc
  local args=(-fsSL -C - --connect-timeout 30
              --speed-limit 1000 --speed-time 120
              -H "$auth_header" -w '%{http_code}' -o "$part")
  [ -n "$RATE_LIMIT" ] && args+=(--limit-rate "$RATE_LIMIT")
  : >"$code_file"
  curl "${args[@]}" "${RELAY_URL}${BUNDLE_PATH}" >"$code_file" &
  CURL_PID=$!
  while kill -0 "$CURL_PID" 2>/dev/null; do
    if [ $(( SECONDS - LAST_PROGRESS_REPORT )) -ge "$PROGRESS_INTERVAL" ]; then
      report_status "$CURRENT_VERSION" "$(downloading_status)" ""
      LAST_PROGRESS_REPORT=$SECONDS
    fi
    pause 5
  done
  wait "$CURL_PID"; rc=$?
  CURL_PID=""
  CURL_HTTP_CODE="$(cat "$code_file" 2>/dev/null)"
  rm -f "$code_file"
  return "$rc"
}

# download_bundle — leaves a verified bundle at $BUNDLE_FILE and its digest in
# ACTUAL_SHA. Returns 0 done, 1 failed (reported), 2 incomplete (reported; the
# next run resumes).
download_bundle() {
  local part="${BUNDLE_FILE}.part" have rc attempt=0 deadline
  if [ -f "$BUNDLE_FILE" ]; then
    ACTUAL_SHA="$(sha256_of "$BUNDLE_FILE")"
    if [ -z "$BUNDLE_SHA" ] || [ "$ACTUAL_SHA" = "$BUNDLE_SHA" ]; then
      pu_log "bundle already downloaded; not downloading it again"
      return 0
    fi
    pu_warn "the kept download no longer matches its checksum; downloading it again"
    pu_shred_file "$BUNDLE_FILE"
  fi

  report_status "$CURRENT_VERSION" "$(downloading_status)" ""
  LAST_PROGRESS_REPORT=$SECONDS
  deadline=$(( SECONDS + DOWNLOAD_BUDGET ))
  while :; do
    have="$(file_bytes "$part")"
    if [ "$BUNDLE_SIZE" -gt 0 ] && [ "$have" -gt "$BUNDLE_SIZE" ]; then
      pu_warn "the partial download is larger than the bundle; starting over"
      rm -f "$part"; have=0
    fi
    rc=0; CURL_HTTP_CODE=""
    if [ "$BUNDLE_SIZE" -eq 0 ] || [ "$have" -lt "$BUNDLE_SIZE" ]; then
      if [ "$have" -gt 0 ]; then
        pu_log "resuming the download at $(progress_text "$have")"
      else
        if [ "$BUNDLE_SIZE" -gt 0 ]; then
          pu_log "downloading bundle ($(mb "$BUNDLE_SIZE") MB)…"
        else
          pu_log "downloading bundle…"
        fi
      fi
      run_curl "$part"; rc=$?
    fi

    if [ "$rc" = 0 ]; then
      have="$(file_bytes "$part")"
      if [ "$BUNDLE_SIZE" -gt 0 ] && [ "$have" -ne "$BUNDLE_SIZE" ]; then
        rc=18  # the connection closed early without curl noticing
      else
        ACTUAL_SHA="$(sha256_of "$part")"
        if [ -n "$BUNDLE_SHA" ] && [ "$ACTUAL_SHA" != "$BUNDLE_SHA" ]; then
          # Kept, it would be "resumed" into the same wrong file forever.
          pu_shred_file "$part"
          report_status "$CURRENT_VERSION" "failed" "sha256 mismatch"
          pu_log "ERROR: sha256 mismatch (want ${BUNDLE_SHA}, got ${ACTUAL_SHA})"
          return 1
        fi
        mv -f "$part" "$BUNDLE_FILE"
        pu_log "bundle downloaded and verified"
        return 0
      fi
    fi

    # A 4xx will not fix itself by retrying (expired token, version withdrawn);
    # timeouts, rate limits, 5xx and dropped connections might.
    case "$CURL_HTTP_CODE" in
      408|429) ;;
      416) rm -f "$part" ;;
      4??)
        report_status "$CURRENT_VERSION" "failed" "bundle download failed (HTTP ${CURL_HTTP_CODE})"
        pu_log "ERROR: bundle download failed (HTTP ${CURL_HTTP_CODE})"
        return 1 ;;
    esac
    if [ "$rc" = 33 ]; then
      pu_warn "the relay would not resume the download; starting over"
      rm -f "$part"
    fi

    attempt=$(( attempt + 1 ))
    if [ "$attempt" -ge "$DOWNLOAD_ATTEMPTS" ] || [ "$SECONDS" -ge "$deadline" ]; then
      report_status "$CURRENT_VERSION" "$(downloading_status)" "connection lost; resuming next run"
      pu_log "download incomplete at $(progress_text "$(file_bytes "$part")"); the next run resumes it"
      return 2
    fi
    pu_log "download interrupted (curl exit ${rc}); retrying…"
    pause $(( attempt < 8 ? attempt * 15 : 120 ))
  done
}

# 1. Ask the relay what to run.
MANIFEST_FILE="$(mktemp)"
if ! curl -fsS -H "$auth_header" "${RELAY_URL}/v1/agent/manifest" -o "$MANIFEST_FILE"; then
  rm -f "$MANIFEST_FILE"
  pu_log "manifest fetch failed; retrying next run"
  exit 0
fi
DIRECTIVE="$(jget "$MANIFEST_FILE" .directive)"
ASSIGNED="$(jget "$MANIFEST_FILE" .assigned_version)"
BUNDLE_PATH="$(jget "$MANIFEST_FILE" .bundle.path)"
BUNDLE_SHA="$(jget "$MANIFEST_FILE" .bundle.sha256)"
BUNDLE_SIG="$(jget "$MANIFEST_FILE" .bundle.signature)"
BUNDLE_SIZE="$(jget "$MANIFEST_FILE" .bundle.size)"
rm -f "$MANIFEST_FILE"
case "$BUNDLE_SIZE" in ''|*[!0-9]*) BUNDLE_SIZE=0 ;; esac

if [ "$DIRECTIVE" != "apply" ] || [ -z "$ASSIGNED" ] || [ "$ASSIGNED" = "$CURRENT_VERSION" ]; then
  pu_log "up to date (current=${CURRENT_VERSION}, directive=${DIRECTIVE}, assigned=${ASSIGNED:-none})"
  # A paused rollout (hold) keeps a half-finished download: resuming the
  # rollout must not cost the shop those hours again. Only once the shop RUNS
  # the assigned version is what is left over garbage.
  if [ "$DRY_RUN" = 0 ] && [ -n "$ASSIGNED" ] && [ "$ASSIGNED" = "$CURRENT_VERSION" ] \
     && [ -d "$DOWNLOAD_DIR" ] && acquire_download_lock quiet; then
    DOWNLOAD_LOCK_HELD=1
    prune_downloads ""
  fi
  report_status "$CURRENT_VERSION" "idle" ""
  exit 0
fi

# Named after what the relay says the bundle is; filtered, because a path built
# from a server's answer must not be able to leave ./downloads.
download_key="$(printf '%s' "${BUNDLE_SHA:-v${ASSIGNED}}" | tr -cd 'A-Za-z0-9._+-' | sed 's/\.\.*/./g')"
BUNDLE_FILE="${DOWNLOAD_DIR}/bundle-${download_key}.zip"

pu_log "update available: ${CURRENT_VERSION} -> ${ASSIGNED}"
if [ "$DRY_RUN" = 1 ]; then
  already=""
  if [ -f "$BUNDLE_FILE" ]; then
    already=", already downloaded"
  elif [ -f "${BUNDLE_FILE}.part" ]; then
    already=", $(progress_text "$(file_bytes "${BUNDLE_FILE}.part")") already downloaded"
  fi
  pu_log "--check: would download ${RELAY_URL}${BUNDLE_PATH} (sha256=${BUNDLE_SHA}${already}) and apply ${ASSIGNED}"
  exit 0
fi
[ -n "$BUNDLE_PATH" ] || fail "manifest is missing the bundle path"

# 2. Download the bundle — resumably, and without holding the update lock.
mkdir -p "$DOWNLOAD_DIR" && chmod 700 "$DOWNLOAD_DIR" 2>/dev/null
acquire_download_lock || exit 0
DOWNLOAD_LOCK_HELD=1
prune_downloads "$BUNDLE_FILE"

download_bundle
case $? in
  0) ;;
  2) exit 0 ;;  # incomplete; reported, and the next run resumes it
  *) exit 1 ;;  # reported by download_bundle
esac

# Authenticity, not just integrity — checked BEFORE a single byte is unpacked.
if ! verify_bundle_signature "$ACTUAL_SHA" "$BUNDLE_SIG"; then
  report_status "$CURRENT_VERSION" "failed" "release signature invalid"
  pu_shred_file "$BUNDLE_FILE"
  fail "release signature INVALID for ${ASSIGNED} — refusing to apply"
fi

# 3. Only the apply takes the update lock: it tells the watchdog to keep its
# hands off the stack, which is right for the minutes an apply takes and wrong
# for the hours a download can.
pu_acquire_lock || exit 0
LOCK_HELD=1

report_status "$CURRENT_VERSION" "applying" ""

if ! pu_stage_bundle "$BUNDLE_FILE"; then
  # A verified zip that will not unpack is not worth keeping for a retry.
  pu_shred_file "$BUNDLE_FILE"
  report_status "$CURRENT_VERSION" "failed" "bundle could not be staged"
  fail "bundle could not be staged"
fi

# 4. Apply (backup, adopt, live flip or restart, rollback on failure). A failed
# apply keeps the verified download, so the retry costs the shop no bandwidth.
if pu_apply_bundle "$POINTY_BUNDLE_DIR" "$CURRENT_VERSION" "$ASSIGNED" "$MODE"; then
  prune_downloads ""
  report_status "$ASSIGNED" "succeeded" ""
  exit 0
fi
report_status "$(pu_current_version)" "failed" "${POINTY_APPLY_ERROR:-update to ${ASSIGNED} failed}"
exit 1
