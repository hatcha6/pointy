#!/usr/bin/env bash
#
# install.sh's "Starting the Pointy stack" step, run end to end against a fake
# Docker.
#
# The bug this exists for: `compose up -d` gives up the moment the backend's
# healthcheck calls it unhealthy, and a backend still applying a release's
# migrations on a shop's machine looks exactly like that. Docker leaves it
# running, it finishes, and a hand-run `compose up -d` minutes later works —
# but `set -e` had already ended install.sh, so the client installers were
# never published and update.sh rolled a good release back.
#
# Time is faked: `date +%s` reads a clock that the fake `sleep` advances, so a
# twenty-minute wait runs in milliseconds and the timings asserted here are
# exact. The fake Docker derives every container's state from that clock.
. "$(dirname "$0")/harness.sh"

# Scenario knobs, one file each under $PU_TEST_DIR/fake (absent = default):
#
#   backend_ready_at   clock second the backend passes /readyz (absent = never)
#   postgres_ready_at  the same for postgres (absent = healthy from the start)
#   crash_every        the backend dies and is restarted every N seconds
#   backend_status     the backend's container status, when not "running"
#   up_blocks          seconds the FIRST `compose up` waits before failing, as
#                      compose does while a dependency is inside its start period
#   up_always_fails    `compose up` fails whatever the health (a port in use)
#   ftp_port_taken     only the `ftp` service cannot bind: an `up` of every
#                      service fails, an `up` of the others succeeds
_knob() { printf '%s\n' "$2" >"${PU_TEST_DIR}/fake/$1"; }

_fake_stack() {
  mkdir -p "${PU_TEST_DIR}/fake"
  printf '0\n' >"${PU_TEST_DIR}/clock"
  stub_script date <<'EOF'
if [ "${1:-}" = "+%s" ]; then cat "${PU_TEST_DIR}/clock"; exit 0; fi
exec /bin/date "$@"
EOF
  stub_script sleep <<'EOF'
printf '%s\n' $(( $(cat "${PU_TEST_DIR}/clock") + ${1%s} )) >"${PU_TEST_DIR}/clock"
EOF
  stub_script docker <<'EOF'
fake="${PU_TEST_DIR}/fake"
clock() { cat "${PU_TEST_DIR}/clock"; }
knob() { cat "${fake}/$1" 2>/dev/null; }
reached() { [ -n "$1" ] && [ "$(clock)" -ge "$1" ]; }

postgres_ready() { [ -z "$(knob postgres_ready_at)" ] || reached "$(knob postgres_ready_at)"; }
backend_restarts() { local every; every="$(knob crash_every)"; [ -n "$every" ] && echo $(( $(clock) / every )) || echo 0; }
backend_ready() {
  [ -z "$(knob crash_every)" ] && [ -z "$(knob backend_status)" ] && reached "$(knob backend_ready_at)"
}
backend_deps="redis:service_healthy:false,postgres:service_healthy:false,pgbouncer:service_started:false"
backend_line() {
  if ! postgres_ready; then echo "False backend created none 0 ${backend_deps}"
  elif [ -n "$(knob backend_status)" ]; then echo "False backend $(knob backend_status) none 0 ${backend_deps}"
  elif [ -n "$(knob crash_every)" ]; then echo "False backend running starting $(backend_restarts) ${backend_deps}"
  elif backend_ready; then echo "False backend running healthy 0 ${backend_deps}"
  else echo "False backend running unhealthy 0 ${backend_deps}"
  fi
}

# Drop the `compose --env-file .env -f docker-compose.yml` prefix.
if [ "${1:-}" = compose ]; then
  shift
  while [ $# -gt 0 ]; do case "$1" in --env-file|-f) shift 2 ;; *) break ;; esac; done
  set -- compose "$@"
fi

case "$*" in
  "compose config --services")
    printf 'postgres\npgbouncer\nredis\nbackend\ncelery-worker\ncelery-beat\nftp\nconnector\nedge\nweb\n' ;;
  "compose up -d postgres pgbouncer redis backend celery-worker celery-beat connector edge web")
    if [ -n "$(knob ftp_port_taken)" ] && backend_ready; then
      touch "${fake}/up_ok"; echo " Container pointy-celery-worker-1 Started"; exit 0
    fi
    exit 1 ;;
  "compose up -d")
    ups=$(( $(knob ups || echo 0) + 1 )); echo "$ups" >"${fake}/ups"
    if [ "$ups" = 1 ] && [ -n "$(knob up_blocks)" ]; then
      echo $(( $(clock) + $(knob up_blocks) )) >"${PU_TEST_DIR}/clock"
    fi
    if [ -n "$(knob up_always_fails)" ]; then
      echo "Error response from daemon: Bind for 0.0.0.0:80 failed: port is already allocated" >&2; exit 1
    fi
    if [ -n "$(knob ftp_port_taken)" ] && backend_ready; then
      echo "Error response from daemon: Bind for 0.0.0.0:21 failed: port is already allocated" >&2; exit 1
    fi
    if ! postgres_ready; then
      echo "dependency failed to start: container pointy-postgres-1 is unhealthy" >&2; exit 1
    fi
    if ! backend_ready; then
      echo "dependency failed to start: container pointy-backend-1 is unhealthy" >&2; exit 1
    fi
    touch "${fake}/up_ok"; echo " Container pointy-celery-worker-1 Started"; exit 0 ;;
  "compose ps -aq backend") echo id-backend ;;
  # Two containers that must never keep the wait going: a one-off `compose run`
  # backend (listed first, so it is what a careless reader would find), and a
  # web front door that is permanently unhealthy but that nothing waits on.
  "compose ps -aq") printf 'id-standby\nid-postgres\nid-backend\nid-worker\nid-web\n' ;;
  "inspect -f "*)
    shift 3
    for id in "$@"; do
      case "$id" in
        id-standby) echo "True backend running starting 0 ${backend_deps}" ;;
        id-postgres) postgres_ready && echo "False postgres running healthy 0 " || echo "False postgres running starting 0 " ;;
        id-backend) backend_line ;;
        id-worker) [ -f "${fake}/up_ok" ] \
          && echo "False celery-worker running healthy 0 backend:service_healthy:false" \
          || echo "False celery-worker created none 0 backend:service_healthy:false" ;;
        id-web) echo "False web running unhealthy 0 edge:service_started:false" ;;
      esac
    done ;;
  "logs --tail "*)
    if [ -n "$(knob crash_every)" ]; then
      echo "django.db.utils.ProgrammingError: column \"currency\" does not exist"
    else
      echo "  Applying sales.0041_backfill_payment_currency... OK"
    fi ;;
esac
exit 0
EOF
}

# A deploy directory as a bundle unpacks it, with the images already loaded.
_seed_deploy() {
  cp "${PU_ONPREM_DIR}/install.sh" "${PU_ONPREM_DIR}/docker-compose.yml" \
     "${PU_ONPREM_DIR}/.env.example" .
  mkdir -p clients
  printf '{"version":"1.1.0"}\n' >clients/manifest.json
  _fake_stack
}

_install() { bash install.sh >"${PU_TEST_DIR}/out" 2>&1; }
_out() { cat "${PU_TEST_DIR}/out"; }
_clock() { cat "${PU_TEST_DIR}/clock"; }
_ups() { assert_call_count docker 'compose * up -d' "$1"; }

# ---------------------------------------------------------------------------
# The stack that comes up the first time is left alone
# ---------------------------------------------------------------------------

test_a_stack_that_comes_up_first_time_is_started_once() {
  _seed_deploy
  _knob backend_ready_at 0
  assert_ok _install
  _ups 1
  assert_not_contains "$(_out)" "Compose stopped waiting"
  assert_eq "0" "$(_clock)" "nothing waited on a stack that was already up"
}

test_the_client_installers_are_published_once_the_stack_is_up() {
  _seed_deploy
  _knob backend_ready_at 0
  assert_ok _install
  assert_called docker 'compose * cp clients/. backend:/var/lib/pointy/clients/'
}

# ---------------------------------------------------------------------------
# The field failure: compose gives up on a backend that is only migrating
# ---------------------------------------------------------------------------

test_a_backend_still_migrating_when_compose_gives_up_is_waited_for() {
  # Four minutes: what 0.4.7 -> 0.5.1 took on Sufian's 2011 OptiPlex.
  _seed_deploy
  _knob backend_ready_at 240
  assert_ok _install
  assert_contains "$(_out)" "dependency failed to start: container pointy-backend-1 is unhealthy"
  assert_contains "$(_out)" "Compose stopped waiting"
  assert_contains "$(_out)" "==> The stack is up, 4m00s after starting it"
  assert_eq "240" "$(_clock)" "it went on as soon as the backend was up, not a poll later"
}

test_every_step_after_the_start_still_runs_after_a_slow_boot() {
  # The whole point: these are what `set -e` used to skip.
  _seed_deploy
  _knob backend_ready_at 240
  assert_ok _install
  assert_called docker 'compose * cp clients/. backend:/var/lib/pointy/clients/'
  assert_called docker 'compose * exec -u 0 -T backend chmod -R a+rX /var/lib/pointy/clients'
  assert_contains "$(_out)" "Done. Useful follow-ups"
}

test_the_installers_are_published_only_after_compose_has_succeeded() {
  # Publishing into a backend compose has not finished bringing up is how you
  # get a till offered a client its server cannot talk to yet.
  _seed_deploy
  _knob backend_ready_at 240
  assert_ok _install
  local calls up cp
  calls="$(calls_of docker)"
  up="$(printf '%s\n' "$calls" | grep -n 'up -d' | tail -1 | cut -d: -f1)"
  cp="$(printf '%s\n' "$calls" | grep -n ' cp clients/' | head -1 | cut -d: -f1)"
  [ "$up" -lt "$cp" ] || _fail "the installers were published before the last compose up" "$calls"
}

test_the_wait_shows_the_migration_it_is_waiting_on() {
  # An operator watching a till-less shop needs to see progress, not a hang.
  _seed_deploy
  _knob backend_ready_at 240
  assert_ok _install
  assert_contains "$(_out)" "still coming up after 1m00s: backend (unhealthy)"
  assert_contains "$(_out)" "backend:   Applying sales.0041_backfill_payment_currency... OK"
}

test_the_wait_counts_the_time_compose_itself_spent_waiting() {
  # compose's own wait (the backend's whole start period, when it is slow) is
  # part of the same budget: the timeout is wall clock from the first `up`.
  _seed_deploy
  _knob up_blocks 690
  _knob backend_ready_at 800
  assert_ok _install
  assert_contains "$(_out)" "==> The stack is up, 13m20s after starting it"
}

test_a_slow_database_is_waited_for_the_same_way() {
  # Postgres replaying its WAL after a power cut gates the backend just as a
  # migration gates the workers. Nothing here knows which service was slow.
  _seed_deploy
  _knob postgres_ready_at 150
  _knob backend_ready_at 200
  assert_ok _install
  assert_contains "$(_out)" "dependency failed to start: container pointy-postgres-1 is unhealthy"
  assert_contains "$(_out)" "postgres (starting)"
  assert_contains "$(_out)" "==> The stack is up"
}

# ---------------------------------------------------------------------------
# Failing, when waiting cannot help
# ---------------------------------------------------------------------------

test_a_backend_that_never_comes_up_gives_up_at_the_timeout() {
  _seed_deploy
  export POINTY_STACK_START_TIMEOUT=300
  local rc; _install; rc=$?
  assert_eq "1" "$rc"
  assert_contains "$(_out)" "the stack was still not up after 5m00s (POINTY_STACK_START_TIMEOUT=300)"
  local clock; clock="$(_clock)"
  [ "$clock" -ge 300 ] && [ "$clock" -le 310 ] || _fail "gave up at ${clock}s, not at the 300s timeout"
}

test_the_default_timeout_is_twenty_minutes() {
  _seed_deploy
  _knob backend_ready_at 30
  assert_ok _install
  assert_contains "$(_out)" "trying again (for up to 20m00s)"
}

test_the_timeout_can_be_set_in_the_env_file() {
  # The update agent runs from a systemd timer; .env is the one place an
  # operator can reach it.
  _seed_deploy
  cp .env.example .env
  printf 'POINTY_STACK_START_TIMEOUT=120\n' >>.env
  local rc; _install; rc=$?
  assert_eq "1" "$rc"
  assert_contains "$(_out)" "the stack was still not up after 2m00s (POINTY_STACK_START_TIMEOUT=120)"
}

test_a_nonsense_timeout_falls_back_to_the_default() {
  _seed_deploy
  _knob backend_ready_at 30
  export POINTY_STACK_START_TIMEOUT=soon
  assert_ok _install
  assert_contains "$(_out)" "trying again (for up to 20m00s)"
}

test_a_crash_looping_backend_fails_fast_instead_of_waiting_out_the_timeout() {
  # A release whose migration raises: every restart dies the same way. Waiting
  # twenty minutes on it would be twenty minutes of dark tills on a restart
  # update, before the rollback could even begin.
  _seed_deploy
  _knob crash_every 20
  local rc; _install; rc=$?
  assert_eq "1" "$rc"
  assert_contains "$(_out)" "the backend keeps crashing"
  local clock; clock="$(_clock)"
  [ "$clock" -le 120 ] || _fail "took ${clock}s to notice a crash loop"
}

test_a_failure_shows_the_backends_own_last_words() {
  _seed_deploy
  _knob crash_every 20
  _install
  assert_contains "$(_out)" 'column "currency" does not exist'
  assert_called docker 'logs --tail 40 id-backend'
}

test_a_failure_that_nothing_is_starting_for_is_not_retried_for_twenty_minutes() {
  # A port in use: the backend is healthy, the retry can only fail the same way.
  # The fake also carries a one-off backend forever "starting" and a web front
  # door forever "unhealthy"; were either counted as the stack still coming up,
  # this would wait out the whole timeout instead.
  _seed_deploy
  _knob backend_ready_at 0
  _knob up_always_fails 1
  local rc; _install; rc=$?
  assert_eq "1" "$rc"
  assert_contains "$(_out)" "nothing is still starting that it could be waiting for"
  assert_contains "$(_out)" "port is already allocated"
  local clock; clock="$(_clock)"
  [ "$clock" -le 60 ] || _fail "retried for ${clock}s with nothing coming up"
}

test_a_taken_ftp_port_does_not_fail_the_install() {
  # Port 21 held by some other program on the shop's machine: compose fails
  # the whole `up` for the one container that cannot bind. The shop can trade
  # without FTP uploads; it cannot trade without the rest.
  _seed_deploy
  _knob backend_ready_at 0
  _knob ftp_port_taken 1
  assert_ok _install
  assert_contains "$(_out)" "everything is up except the FTP upload server"
  # The range compose publishes, not the one it had before it moved below
  # Hyper-V's reserved blocks.
  assert_contains "$(_out)" "passive range 30000-30019"
  assert_called docker 'compose * up -d postgres pgbouncer redis backend celery-worker celery-beat connector edge web'
  assert_called docker 'compose * cp clients/*'
}

test_a_taken_ftp_port_still_waits_for_a_migrating_backend() {
  # Without the FTP fallback telling the two apart, a slow migration and a
  # taken port 21 would look alike; the backend must still be waited for.
  _seed_deploy
  _knob backend_ready_at 300
  _knob ftp_port_taken 1
  assert_ok _install
  assert_contains "$(_out)" "Compose stopped waiting"
  assert_contains "$(_out)" "everything is up except the FTP upload server"
  local clock; clock="$(_clock)"
  [ "$clock" -ge 300 ] || _fail "gave up waiting at ${clock}s, before the backend was ready"
}

test_a_backend_that_is_gone_is_not_waited_for() {
  _seed_deploy
  _knob backend_status exited
  local rc; _install; rc=$?
  assert_eq "1" "$rc"
  assert_contains "$(_out)" "nothing is still starting"
}

test_nothing_after_the_start_runs_when_the_stack_did_not_come_up() {
  # A failed install ends in update.sh's rollback. Publishing this release's
  # installers first would leave the tills offered a client for a server the
  # shop is no longer running.
  _seed_deploy
  _knob crash_every 20
  local rc; _install; rc=$?
  assert_eq "1" "$rc"
  assert_not_called docker 'compose * cp clients/*'
  assert_contains "$(_out)" "were not published and the watchdog was not registered"
}

# ---------------------------------------------------------------------------
# The compose file gives a migrating backend room before any of this is needed
# ---------------------------------------------------------------------------

test_the_backend_healthcheck_leaves_room_for_a_slow_migration() {
  # At 90s, 0.4.7 -> 0.5.1 on a 2011 OptiPlex (~4 minutes) was declared
  # unhealthy mid-migration. Anything under ten minutes brings that back.
  local period
  period="$(sed -n 's/^ *start_period: \${POINTY_BACKEND_START_PERIOD:-\([0-9]*\)s}.*/\1/p' \
    "${PU_ONPREM_DIR}/docker-compose.yml")"
  [ -n "$period" ] || _fail "the backend's start_period is no longer \${POINTY_BACKEND_START_PERIOD:-<n>s}"
  [ "$period" -ge 600 ] || _fail "the backend's start_period default is ${period}s; a migrating backend needs 600s"
}

pu_run_tests "$@"
