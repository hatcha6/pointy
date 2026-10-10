#!/usr/bin/env bash
# Runs a throwaway local relay with the operator console at
# http://localhost:8191/console/ — its own Postgres database and Redis db, so
# it never touches a relay another developer is running on 8091. Suppliers run
# in test mode and alerts go nowhere, whatever relay/.env holds.
#
#   make relay-console-preview          build the app, then run this
#   scripts/dev-relay.sh invite NAME    print a one-time invite link
set -euo pipefail
cd "$(dirname "$0")/../.."   # relay/

PORT="${CONSOLE_DEV_PORT:-8191}"
DB="${CONSOLE_DEV_DB:-relay_console_dev}"
PG="${CONSOLE_DEV_PG:-postgres://postgres:postgres@127.0.0.1:5432}"
TOKEN_FILE="console-ui/.dev-admin-token"
[ -s "$TOKEN_FILE" ] || go run ./cmd/pointy-relay gen-token > "$TOKEN_FILE"
TOKEN="$(tr -d '\n' < "$TOKEN_FILE")"

if [ "${1:-}" = "invite" ]; then
  POINTY_RELAY_CONTROL_URL="http://127.0.0.1:$PORT" POINTY_RELAY_ADMIN_TOKEN="$TOKEN" \
    POINTY_RELAY_ALLOW_INSECURE_CONTROL=true go run ./cmd/pointy-relay console invite --name "${2:?name}"
  exit
fi

sql() {
  if command -v psql >/dev/null; then psql "$PG/postgres" "$@"; else docker exec -i pointy-postgres-1 psql -U postgres "$@"; fi
}
sql -tAc "SELECT 1 FROM pg_database WHERE datname = '$DB'" | grep -q 1 || sql -qc "CREATE DATABASE $DB"

exec env \
  POINTY_RELAY_HTTP_ADDR="127.0.0.1:$PORT" \
  POINTY_RELAY_CONNECTOR_ADDR="127.0.0.1:$((PORT + 1))" \
  POINTY_RELAY_ALLOW_INSECURE_HTTP=true \
  POINTY_RELAY_DATABASE_URL="$PG/$DB?sslmode=disable" \
  POINTY_RELAY_REDIS_URL="${CONSOLE_DEV_REDIS:-redis://127.0.0.1:6379/7}" \
  POINTY_RELAY_AUTO_MIGRATE=true \
  POINTY_RELAY_ARTIFACT_DIR="${CONSOLE_DEV_ARTIFACTS:-$PWD/console-ui/.dev-artifacts}" \
  POINTY_RELAY_ADMIN_TOKEN="$TOKEN" \
  POINTY_RELAY_CONSOLE_ORIGIN="${CONSOLE_DEV_ORIGIN:-http://localhost:$PORT}" \
  POINTY_RELAY_VOUCHERS_TEST_MODE=true \
  POINTY_RELAY_RELOADLY_SANDBOX=true \
  POINTY_RELAY_NTFY_SERVER=http://127.0.0.1:9 \
  go run ./cmd/pointy-relay server
