#!/usr/bin/env bash
#
# .env reading, the backend port, and the update lock the watchdog respects.
. "$(dirname "$0")/harness.sh"

# ---------------------------------------------------------------------------
# pu_env_value
# ---------------------------------------------------------------------------

test_env_value_reads_a_plain_key() {
  write_env 'POINTY_BACKEND_PORT=8080'
  assert_eq '8080' "$(pu_env_value POINTY_BACKEND_PORT)"
}

test_env_value_is_empty_for_a_missing_key() {
  write_env 'SOMETHING_ELSE=1'
  assert_eq '' "$(pu_env_value POINTY_BACKEND_PORT)"
}

test_env_value_is_empty_when_env_is_missing_entirely() {
  rm -f .env
  assert_eq '' "$(pu_env_value POINTY_BACKEND_PORT)"
}

test_env_value_keeps_equals_signs_inside_the_value() {
  # Base64 secrets end in '=' padding; cutting on the first '=' only would
  # silently truncate them.
  write_env 'POSTGRES_PASSWORD=c2VjcmV0cGFzcw=='
  assert_eq 'c2VjcmV0cGFzcw==' "$(pu_env_value POSTGRES_PASSWORD)"
}

test_env_value_strips_surrounding_quotes() {
  write_env 'POINTY_RELAY_PUBLIC_API_URL="https://relay.example.test"'
  assert_eq 'https://relay.example.test' "$(pu_env_value POINTY_RELAY_PUBLIC_API_URL)"
}

test_env_value_strips_carriage_returns_from_a_windows_edited_env() {
  # A shop's .env gets opened in Notepad more often than anyone would like, and
  # a trailing \r turns a port into a URL that curl cannot parse.
  printf 'POINTY_BACKEND_PORT=8080\r\n' >.env
  assert_eq '8080' "$(pu_env_value POINTY_BACKEND_PORT)"
}

test_env_value_ignores_a_key_that_is_only_a_prefix() {
  write_env 'POINTY_BACKEND_PORT_INTERNAL=9999' 'POINTY_BACKEND_PORT=8080'
  assert_eq '8080' "$(pu_env_value POINTY_BACKEND_PORT)"
}

test_env_value_ignores_commented_out_keys() {
  write_env '#POINTY_BACKEND_PORT=9999' 'POINTY_BACKEND_PORT=8080'
  assert_eq '8080' "$(pu_env_value POINTY_BACKEND_PORT)"
}

test_env_value_never_evaluates_shell_metacharacters_in_a_value() {
  # The whole reason this is grep+cut rather than `source .env`: a password is
  # allowed to contain $(...) and must never be executed.
  write_env 'POSTGRES_PASSWORD=$(touch pwned)`touch pwned2`'
  local value; value="$(pu_env_value POSTGRES_PASSWORD)"
  assert_no_file pwned
  assert_no_file pwned2
  assert_contains "$value" 'touch pwned'
}

test_env_value_takes_the_FIRST_of_duplicate_keys() {
  # DOCUMENTED DIVERGENCE, not an endorsement: `head -1` takes the first, while
  # docker compose --env-file takes the LAST. A shop whose .env carries the key
  # twice would have the engine probing one port while the stack publishes the
  # other. Pinned here so the divergence cannot change unnoticed.
  write_env 'POINTY_BACKEND_PORT=8080' 'POINTY_BACKEND_PORT=9090'
  assert_eq '8080' "$(pu_env_value POINTY_BACKEND_PORT)"
}

# ---------------------------------------------------------------------------
# pu_set_env_var
# ---------------------------------------------------------------------------

test_set_env_var_replaces_a_value_and_leaves_every_other_line_alone() {
  write_env '# relay' 'POINTY_RELAY_ENROLLMENT_TOKEN=pte1.old' \
    'POINTY_DATABASE_URL=postgres://pointy:c2Vj==@pgbouncer:5432/pointy?a=1&b=2'
  assert_ok pu_set_env_var POINTY_RELAY_ENROLLMENT_TOKEN pte1.new
  assert_file_eq .env "$(printf '%s\n' '# relay' 'POINTY_RELAY_ENROLLMENT_TOKEN=pte1.new' \
    'POINTY_DATABASE_URL=postgres://pointy:c2Vj==@pgbouncer:5432/pointy?a=1&b=2')"
}

test_set_env_var_appends_a_missing_key() {
  write_env 'COMPOSE_PROJECT_NAME=pointy'
  assert_ok pu_set_env_var POINTY_RELAY_ENROLLMENT_TOKEN pte1.new
  assert_file_eq .env "$(printf '%s\n' 'COMPOSE_PROJECT_NAME=pointy' 'POINTY_RELAY_ENROLLMENT_TOKEN=pte1.new')"
}

test_set_env_var_appends_on_its_own_line_when_env_lacks_a_final_newline() {
  printf 'COMPOSE_PROJECT_NAME=pointy' >.env
  assert_ok pu_set_env_var POINTY_RELAY_ENROLLMENT_TOKEN pte1.new
  assert_eq 'pointy' "$(pu_env_value COMPOSE_PROJECT_NAME)"
  assert_eq 'pte1.new' "$(pu_env_value POINTY_RELAY_ENROLLMENT_TOKEN)"
}

test_set_env_var_writes_the_value_literally() {
  # awk -v would turn \t into a tab; & and $() must not mean anything either.
  write_env 'SECRET=old'
  assert_ok pu_set_env_var SECRET 'a\tb&c$(touch pwned)=d'
  assert_eq 'a\tb&c$(touch pwned)=d' "$(pu_env_value SECRET)"
  assert_no_file pwned
}

test_set_env_var_ignores_a_key_that_is_only_a_prefix() {
  write_env 'POINTY_BACKEND_PORT_INTERNAL=9999' 'POINTY_BACKEND_PORT=8080'
  assert_ok pu_set_env_var POINTY_BACKEND_PORT 8000
  assert_eq '9999' "$(pu_env_value POINTY_BACKEND_PORT_INTERNAL)"
  assert_eq '8000' "$(pu_env_value POINTY_BACKEND_PORT)"
}

test_set_env_var_sets_every_copy_of_a_duplicated_key() {
  # pu_env_value reads the first copy and compose the last; after a write they
  # must agree, whichever one a reader takes.
  write_env 'POINTY_RELAY_ENROLLMENT_TOKEN=pte1.a' 'POINTY_RELAY_ENROLLMENT_TOKEN=pte1.b'
  assert_ok pu_set_env_var POINTY_RELAY_ENROLLMENT_TOKEN pte1.new
  assert_eq 2 "$(grep -c '^POINTY_RELAY_ENROLLMENT_TOKEN=pte1.new$' .env)"
}

test_set_env_var_keeps_the_mode_of_env_and_leaves_no_temp_file() {
  # .env holds the database password; a write must not widen who can read it.
  write_env 'SECRET=old'
  chmod 600 .env
  assert_ok pu_set_env_var SECRET new
  assert_eq '600' "$(stat -c %a .env 2>/dev/null || stat -f %Lp .env)"
  assert_eq '' "$(find . -maxdepth 1 -name '.env.*' -print)"
}

# ---------------------------------------------------------------------------
# pu_backend_port
# ---------------------------------------------------------------------------

test_backend_port_defaults_to_8000_when_unset() {
  write_env 'SOMETHING_ELSE=1'
  assert_eq '8000' "$(pu_backend_port)"
}

test_backend_port_defaults_to_8000_when_set_but_empty() {
  write_env 'POINTY_BACKEND_PORT='
  assert_eq '8000' "$(pu_backend_port)"
}

test_backend_port_uses_the_configured_port() {
  write_env 'POINTY_BACKEND_PORT=18000'
  assert_eq '18000' "$(pu_backend_port)"
}

# ---------------------------------------------------------------------------
# pu_acquire_lock / pu_release_lock
# ---------------------------------------------------------------------------

test_acquire_lock_creates_a_lock_carrying_pid_and_timestamp() {
  assert_ok pu_acquire_lock
  assert_file .update.lock
  assert_file_contains .update.lock "pid=$$"
  assert_file_contains .update.lock 'started='
}

test_release_lock_removes_it() {
  pu_acquire_lock
  pu_release_lock
  assert_no_file .update.lock
}

test_release_lock_is_safe_when_no_lock_exists() {
  assert_ok pu_release_lock
}

test_acquire_lock_refuses_while_a_fresh_lock_is_held() {
  printf 'pid=4242 started=now\n' >.update.lock
  assert_fail pu_acquire_lock
}

test_acquire_lock_does_not_clobber_the_holders_lock() {
  # If a refused acquire overwrote the file it would reset the age, and two
  # updaters could ping-pong forever without either detecting the other.
  printf 'pid=4242 started=now\n' >.update.lock
  pu_acquire_lock
  assert_file_contains .update.lock 'pid=4242'
}

test_acquire_lock_reports_who_holds_it() {
  printf 'pid=4242 started=2026-01-01T00:00:00\n' >.update.lock
  local out; out="$(pu_acquire_lock 2>&1)"
  assert_contains "$out" 'another update is already running'
  assert_contains "$out" 'pid=4242'
}

test_acquire_lock_takes_over_a_stale_lock() {
  # The holder can die with the host — a power cut mid-update must not disable
  # every future update.
  printf 'pid=4242 started=long-ago\n' >.update.lock
  touch -t 200001010000 .update.lock
  local out; out="$(pu_acquire_lock 2>&1)"
  assert_contains "$out" 'clearing a stale update lock'
  assert_file_contains .update.lock "pid=$$"
}

test_acquire_lock_honours_a_custom_max_age() {
  printf 'pid=4242 started=recent\n' >.update.lock
  # Two minutes old, with a one-minute ceiling: stale.
  touch -t "$(date -v-2M '+%Y%m%d%H%M' 2>/dev/null || date -d '2 minutes ago' '+%Y%m%d%H%M')" .update.lock
  POINTY_UPDATE_LOCK_MAX_AGE=60 assert_ok pu_acquire_lock
  assert_file_contains .update.lock "pid=$$"
}

test_acquire_lock_treats_an_unreadable_mtime_as_stale() {
  # pu_file_mtime falls back to 0, which makes the age enormous. Failing OPEN
  # here is the right call: refusing forever would strand the shop.
  printf 'pid=4242\n' >.update.lock
  pu_file_mtime() { echo 0; }
  assert_ok pu_acquire_lock
}

test_acquire_lock_refuses_when_the_clock_jumped_backwards() {
  # DOCUMENTED SHARP EDGE: a lock stamped in the future yields a negative age,
  # which reads as "fresh" and blocks updates until wall-clock catches up. Shops
  # run on machines whose RTC drifts across power cuts, so this is reachable.
  printf 'pid=4242 started=the-future\n' >.update.lock
  touch -t 209901010000 .update.lock
  assert_fail pu_acquire_lock
}

test_file_mtime_returns_a_number_for_a_real_file() {
  printf 'x\n' >somefile
  local mtime; mtime="$(pu_file_mtime somefile)"
  case "$mtime" in ''|*[!0-9]*) _fail "expected a numeric mtime, got [$mtime]" ;; esac
  [ "$mtime" -gt 0 ] || _fail "expected a positive mtime, got [$mtime]"
}

test_file_mtime_returns_zero_for_a_missing_file() {
  assert_eq '0' "$(pu_file_mtime does-not-exist)"
}

pu_run_tests "$@"
