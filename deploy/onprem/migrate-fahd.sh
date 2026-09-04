#!/usr/bin/env bash
#
# One-shot legacy-data migration for a shop coming from Fahd (Access edition).
#
# Normally you don't need this: the shop's owner uploads their db.mdb from
# Shop Settings → نقل البيانات and watches it happen. This is the same
# pipeline for an operator standing at the machine with the file on a USB
# stick. The .mdb is converted, its audit log replayed and its system
# identified server-side — hand it the raw file.
#
# Run from the deploy directory (next to docker-compose.yml):
#
#   bash migrate-fahd.sh /path/to/db.mdb            # dry run
#   bash migrate-fahd.sh /path/to/db.mdb --import   # real import
#
# The dry run validates everything and writes nothing — read its report first.
# Stock quantities are intentionally NOT transferred (--stock none): the shop
# does a fresh stock count in Pointy afterwards. Re-running is safe (idempotent).
set -euo pipefail
cd "$(dirname "$0")"

err() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

DB_FILE="${1:-}"
[ -n "$DB_FILE" ] || err "Usage: bash migrate-fahd.sh /path/to/db.mdb [--import] [--stock none|snapshot|reconstruct]"
[ -f "$DB_FILE" ] || err "File not found: $DB_FILE"
shift

MODE="dry_run"
STOCK="none"
EXTRA_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --import) MODE="import" ;;
    --stock) STOCK="${2:-none}"; shift ;;
    --take-over) EXTRA_ARGS+=("--take-over") ;;
    *) err "Unknown argument: $1" ;;
  esac
  shift
done

[ -f docker-compose.yml ] || err "docker-compose.yml not found — run this from the Pointy deploy directory."
command -v docker >/dev/null 2>&1 || err "Docker is not installed."
docker compose ps --status running backend --quiet 2>/dev/null | grep -q . \
  || err "The backend container is not running. Start the stack first (bash install.sh)."

# Stage the file on a real volume, NOT /tmp: the backend's /tmp is a small
# tmpfs (64 MB) and a real export easily exceeds it. /var/lib/pointy/backups is
# a persistent volume with room to spare and is cleaned up afterwards.
CONTAINER_PATH="/var/lib/pointy/migration/legacy-import-source"
echo "==> Copying $(basename "$DB_FILE") into the backend container…"
docker compose cp "$DB_FILE" "backend:$CONTAINER_PATH"

echo "==> Running migration ($MODE, stock=$STOCK)…"
docker compose exec -T backend python manage.py import_legacy \
  --file "$CONTAINER_PATH" \
  --mode "$MODE" \
  --stock "$STOCK" \
  ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
status=$?

# Only remove the staged copy after a real import; keep it between a dry run
# and the import so the second run doesn't re-copy the large file.
if [ "$MODE" = "import" ]; then
  docker compose exec -T backend rm -f "$CONTAINER_PATH" >/dev/null 2>&1 || true
fi

echo
if [ "$status" -ne 0 ]; then
  err "Migration command failed (exit $status). Nothing was left half-applied — the import is transactional per record; re-run once the cause is fixed."
fi
if [ "$MODE" = "dry_run" ]; then
  echo "Dry run finished. If the report looks right, run again with --import:"
  echo "  bash migrate-fahd.sh $DB_FILE --import"
else
  echo "Import finished. Next steps:"
  echo "  1. Open the app and scan a few known barcodes (including carton/pack codes)."
  echo "  2. Spot-check a couple of old invoices and purchase bills."
  echo "  3. Run a stock count in Pointy — quantities were intentionally not transferred."
fi
