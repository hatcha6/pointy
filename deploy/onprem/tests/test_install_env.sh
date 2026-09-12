#!/usr/bin/env bash
#
# install.sh's .env contract.
#
# This is the step a failed install is most likely to die in, and the one whose
# failure is worst: compose refuses to start on a `${VAR:?}` it cannot resolve,
# so the shop gets no till and the operator gets a wall of variable names.
#
# The rules being pinned here:
#   * every variable compose hard-requires ends up with a real value;
#   * "real" excludes the template's own `replace-with-...` placeholders, which
#     are non-empty and would otherwise pass for configuration - that would ship
#     every shop the same DJANGO_SECRET_KEY out of our git history;
#   * secrets are generated per shop and NEVER rotate on a re-run;
#   * the app talks to Postgres through PgBouncer, migrations go direct.
. "$(dirname "$0")/harness.sh"

# A deploy directory holding the three files the env pass reads.
seed_deploy() {
  cp "${PU_ONPREM_DIR}/install.sh" \
     "${PU_ONPREM_DIR}/docker-compose.yml" \
     "${PU_ONPREM_DIR}/.env.example" .
}

env_only() { bash install.sh --env-only >/dev/null 2>&1; }
val() { grep -E "^$1=" .env 2>/dev/null | head -1 | cut -d= -f2-; }

# Read straight out of compose so this can never drift from what is enforced.
required_keys() {
  grep -oE '\$\{[A-Z_][A-Z0-9_]*:\?' docker-compose.yml | sed 's/^\${//; s/:?$//' | sort -u
}

test_a_fresh_install_fills_every_variable_compose_demands() {
  seed_deploy
  assert_ok env_only
  local key
  for key in $(required_keys); do
    [ -n "$(val "$key")" ] || { printf 'required key %s has no value\n' "$key" >&2; exit 1; }
  done
}

test_no_required_variable_is_left_holding_a_template_placeholder() {
  # The bug this exists for: `replace-with-at-least-50-random-characters` is a
  # non-empty string, so a naive "fill it if it is empty" leaves it in place and
  # the shop runs on a secret key that is public.
  seed_deploy
  assert_ok env_only
  local key value
  for key in $(required_keys); do
    value="$(val "$key")"
    case "$value" in
      *replace-with-*) printf '%s still holds a placeholder: %s\n' "$key" "$value" >&2; exit 1 ;;
    esac
  done
}

test_each_shop_gets_its_own_secrets() {
  seed_deploy; assert_ok env_only
  local first_key first_pw
  first_key="$(val DJANGO_SECRET_KEY)"; first_pw="$(val POINTY_POSTGRES_PASSWORD)"
  rm -f .env; assert_ok env_only
  [ "$first_key" != "$(val DJANGO_SECRET_KEY)" ] || { echo "two installs shared a DJANGO_SECRET_KEY" >&2; exit 1; }
  [ "$first_pw" != "$(val POINTY_POSTGRES_PASSWORD)" ] || { echo "two installs shared a db password" >&2; exit 1; }
}

test_generated_secrets_are_long_enough_to_be_worth_generating() {
  seed_deploy; assert_ok env_only
  local key; key="$(val DJANGO_SECRET_KEY)"
  [ "${#key}" -ge 50 ] || { printf 'DJANGO_SECRET_KEY is only %s chars\n' "${#key}" >&2; exit 1; }
  local pw; pw="$(val POINTY_POSTGRES_PASSWORD)"
  [ "${#pw}" -ge 24 ] || { printf 'db password is only %s chars\n' "${#pw}" >&2; exit 1; }
}

test_rerunning_the_installer_never_rotates_a_secret() {
  # Rotating either of these on a re-run is silent data loss: a new password
  # cannot open the existing database, and a new secret key logs every till out.
  seed_deploy; assert_ok env_only
  local key pw; key="$(val DJANGO_SECRET_KEY)"; pw="$(val POINTY_POSTGRES_PASSWORD)"
  assert_ok env_only
  assert_eq "$key" "$(val DJANGO_SECRET_KEY)" "DJANGO_SECRET_KEY was rotated by a re-run"
  assert_eq "$pw" "$(val POINTY_POSTGRES_PASSWORD)" "the database password was rotated by a re-run"
}

test_a_half_written_env_is_repaired_rather_than_rejected() {
  # The state a shop is left in when an install dies part way through.
  seed_deploy
  printf 'POINTY_POSTGRES_PASSWORD=keepme\n' > .env
  assert_ok env_only
  assert_eq "keepme" "$(val POINTY_POSTGRES_PASSWORD)" "the existing database password was not preserved"
  local key
  for key in $(required_keys); do
    [ -n "$(val "$key")" ] || { printf 'repair left %s empty\n' "$key" >&2; exit 1; }
  done
}

test_the_app_reaches_postgres_through_the_pooler() {
  seed_deploy; assert_ok env_only
  assert_contains "$(val POINTY_DATABASE_URL)" "@pgbouncer:" "the app URL bypasses PgBouncer"
  assert_contains "$(val POINTY_DATABASE_DIRECT_URL)" "@postgres:" "migrations must go straight at Postgres"
}

test_an_install_that_bypassed_the_pooler_is_moved_onto_it() {
  seed_deploy
  printf 'POINTY_POSTGRES_PASSWORD=pw\nPOINTY_DATABASE_URL=postgres://pointy:pw@postgres:5432/pointy\n' > .env
  assert_ok env_only
  assert_contains "$(val POINTY_DATABASE_URL)" "@pgbouncer:" "an existing direct-to-Postgres URL was left bypassing the pooler"
  assert_eq "pw" "$(val POINTY_POSTGRES_PASSWORD)" "moving onto the pooler must not change the password"
}

test_a_url_the_operator_pointed_elsewhere_is_left_alone() {
  seed_deploy
  printf 'POINTY_POSTGRES_PASSWORD=pw\nPOINTY_DATABASE_URL=postgres://pointy:pw@db.example.test:5432/pointy\n' > .env
  assert_ok env_only
  assert_eq "postgres://pointy:pw@db.example.test:5432/pointy" "$(val POINTY_DATABASE_URL)" \
    "a deliberately-pointed database URL was rewritten"
}

test_worker_recycling_is_forced_off() {
  # This was fix-backend-outages.sh. POINTY_ASGI_MAX_REQUESTS>0 makes every ASGI
  # worker self-terminate after N requests; steady till polling drives them all
  # there together, so the API dies on a timer for the length of a cold start.
  seed_deploy
  printf 'POINTY_ASGI_MAX_REQUESTS=1000\nPOINTY_ASGI_MAX_REQUESTS_JITTER=50\n' > .env
  assert_ok env_only
  assert_eq "0" "$(val POINTY_ASGI_MAX_REQUESTS)" "worker recycling was left on"
  assert_eq "0" "$(val POINTY_ASGI_MAX_REQUESTS_JITTER)" "recycle jitter was left on"
}

test_a_key_that_cannot_be_filled_stops_the_install_by_name() {
  # Better a refusal that names the variables than compose failing on them one
  # at a time after the operator thinks the install succeeded.
  seed_deploy
  rm -f .env.example
  printf 'POINTY_POSTGRES_PASSWORD=pw\n' > .env
  local out
  out="$(bash install.sh --env-only 2>&1)" && { echo "the gate passed an incomplete .env" >&2; exit 1; }
  assert_contains "$out" "POINTY_RELAY_CONNECTOR_ADDR" "the failure did not name the missing variable"
}

test_the_shipped_template_can_satisfy_every_required_variable() {
  # A release that adds a `${VAR:?}` to compose without adding it to
  # .env.example would install fine here and fail in a shop. Catch it in CI.
  seed_deploy
  local key missing=""
  for key in $(required_keys); do
    grep -qE "^${key}=" .env.example || missing="${missing} ${key}"
  done
  assert_eq "" "$missing" "these compose-required keys are absent from .env.example:${missing}"
}

test_an_env_that_predates_a_key_inherits_it() {
  # The class the required-variable gate does NOT cover: a key with a compose
  # `:-` fallback. It starts, so nothing complains, and the shop runs on the
  # fallback instead of the value the template already knows.
  # POINTY_RELAY_CONNECTOR_TLS_SERVER_NAME is the live example: empty makes the
  # connector recover the name from its bootstrap exchange or derive it from the
  # relay address, rather than simply being told it.
  seed_deploy
  printf 'POINTY_POSTGRES_PASSWORD=keepme\n' > .env
  assert_ok env_only
  assert_eq "$(grep -E '^POINTY_RELAY_CONNECTOR_TLS_SERVER_NAME=' .env.example | cut -d= -f2-)" \
            "$(val POINTY_RELAY_CONNECTOR_TLS_SERVER_NAME)" \
            "a key this .env predated was not inherited from the template"
}

test_a_value_the_operator_chose_is_never_overwritten() {
  seed_deploy
  printf 'POINTY_POSTGRES_PASSWORD=pw\nPOINTY_RELAY_ALLOW_INSECURE_CONNECTOR=true\n' > .env
  assert_ok env_only
  assert_eq "true" "$(val POINTY_RELAY_ALLOW_INSECURE_CONNECTOR)" \
    "the operator's own value was replaced by the template's"
}

test_an_empty_key_is_left_empty_because_someone_meant_it() {
  # Present-but-empty is a decision. Only ABSENT keys are inherited.
  seed_deploy
  printf 'POINTY_POSTGRES_PASSWORD=pw\nPOINTY_RELAY_CONNECTOR_TLS_SERVER_NAME=\n' > .env
  assert_ok env_only
  assert_eq "" "$(val POINTY_RELAY_CONNECTOR_TLS_SERVER_NAME)" \
    "a deliberately-emptied key was refilled from the template"
}

test_every_relay_and_connector_variable_ends_up_set() {
  # What the operator actually asked for: not just the four the stack refuses to
  # boot without, but the whole relay/connector family.
  seed_deploy; assert_ok env_only
  local key
  for key in POINTY_RELAY_CONTROL_URL POINTY_RELAY_PUBLIC_API_URL \
             POINTY_RELAY_CONNECTOR_ADDR POINTY_RELAY_CONNECTOR_SETUP_TOKEN \
             POINTY_RELAY_CONNECTOR_TLS_SERVER_NAME \
             POINTY_RELAY_ALLOW_INSECURE_CONTROL POINTY_RELAY_ALLOW_INSECURE_CONNECTOR; do
    [ -n "$(val "$key")" ] || { printf '%s is empty after a fresh install\n' "$key" >&2; exit 1; }
  done
}

pu_run_tests "$@"
