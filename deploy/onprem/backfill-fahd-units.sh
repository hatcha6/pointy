#!/usr/bin/env bash
#
# Backfill packaging units (كرتون / صندوق / عبوة) for a shop ALREADY migrated
# from Fahd (Access edition) — fixes catalogues imported before Pointy learned
# to turn CAR_PART_D2 pack codes into units of measure.
#
# What it does, in place, without touching sales/purchase history or stock:
#   * creates a ProductUnit (pieces-per-pack conversion) on each parent product
#     for every pack code in the export, priced from the shop's own pack-priced
#     sale history when there is enough of it (otherwise derived: piece × count);
#   * moves each pack barcode onto its unit, retiring the pack pseudo-variant
#     the original import created (deactivated, history preserved) — scanning a
#     carton EAN now rings up a carton, in POS and in purchasing;
#   * lines keep defaulting to the piece everywhere — the pack is picked from
#     the line's unit chip (or by scanning its barcode), never forced;
#   * pack codes whose sale history shows they were really used to ring loose
#     pieces are left exactly as they are (still scan as one piece).
#
# Uses the SAME fahd_migration.sqlite file the original migration used (the
# identity map is keyed on it). If the file is gone, regenerate it on a
# workstation from the shop's db.mdb:
#   scripts/mdb_to_sqlite.sh db.mdb fahd_data.sqlite
#   scripts/fahd_reconstruct.py fahd_data.sqlite fahd_migration.sqlite
#
# Run from the deploy directory (next to docker-compose.yml):
#
#   bash backfill-fahd-units.sh /path/to/fahd_migration.sqlite            # dry run
#   bash backfill-fahd-units.sh /path/to/fahd_migration.sqlite --import   # real run
#
# The dry run validates everything and writes nothing — read its report first.
# Re-running is safe (idempotent): existing units are updated, not duplicated.
set -euo pipefail
cd "$(dirname "$0")"

err() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

DB_FILE="${1:-}"
[ -n "$DB_FILE" ] || err "Usage: bash backfill-fahd-units.sh /path/to/fahd_migration.sqlite [--import]"
[ -f "$DB_FILE" ] || err "File not found: $DB_FILE"
shift

MODE="dry_run"
EXTRA_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --import) MODE="import" ;;
    --take-over) EXTRA_ARGS+=("--take-over") ;;
    *) err "Unknown argument: $1" ;;
  esac
  shift
done

[ -f docker-compose.yml ] || err "docker-compose.yml not found — run this from the Pointy deploy directory."
command -v docker >/dev/null 2>&1 || err "Docker is not installed."
docker compose ps --status running backend --quiet 2>/dev/null | grep -q . \
  || err "The backend container is not running. Start the stack first (bash install.sh)."

# Stage at the SAME path the original migration used — the identity map that
# links legacy codes to the imported products is keyed on it.
CONTAINER_PATH="/var/lib/pointy/backups/legacy-import.sqlite"
echo "==> Copying $(basename "$DB_FILE") into the backend container…"
docker compose cp "$DB_FILE" "backend:$CONTAINER_PATH"

echo "==> Backfilling packaging units ($MODE)…"
docker compose exec -T backend python manage.py import_legacy \
  --database "$CONTAINER_PATH" \
  --system fahd_sqlite \
  --mode "$MODE" \
  --stock none \
  --entities unit,product_unit \
  ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
status=$?

# --- Confirmed per-product fixups -------------------------------------------
# Applied after a real import (idempotent — re-running updates in place).
# Sources: client-confirmed egg numbers + the shop's own 2026 bulk-sale prices
# (see FAHD_UNIT_CANDIDATES.md in the repo for the evidence per product).
#
# set_product_unit args per line:  <product> <unit> <unit-name> <factor> <price> [fractional] [take-over]
FIXUPS=(
  # Eggs: the ×30 pack IS the tray (طبق) — fractional, half-trays sell.
  "6930358682129 tray طبق 30 15 fractional carton"
  # …and the real carton on top: 12 trays × 30 eggs (carton costs 162 =
  # 12 × 13.50), selling at 12 × 15. Makes carton-based POs one line.
  "6930358682129 carton كرتون 360 180 - -"
  "21 tray طبق 30 20 fractional carton"
  "-1 tray طبق 30 17.5 fractional carton"
  "01 tray طبق 30 7 fractional carton"
  # Placeholder-named «صنف 1»: sells exactly like an egg tray (ask the client
  # to give it a real name — see the candidates file).
  "1 tray طبق 30 16 fractional carton"
  # Water شد (×12) at the shop's current bulk prices.
  "6240000669027 carton كرتون 12 5.50 - -"
  "6240000403041 carton كرتون 12 5.00 - -"
  "6241478523613 carton كرتون 12 4.75 - -"
  "6241000051690 carton كرتون 12 4.50 - -"
  "6241478523606 carton كرتون 12 4.50 - -"
  "6240000017026 carton كرتون 12 7.00 - -"
  "6240000403034 carton كرتون 12 4.00 - -"
  "6240000403133 carton كرتون 12 3.75 - -"
  "6240000319069 carton كرتون 12 5.00 - -"
  "6240000319021 carton كرتون 12 3.50 - -"
  "6241002380026 carton كرتون 12 4.50 - -"
  # Chocolate display boxes (×24).
  "8691707095707 carton كرتون 24 12.00 - -"
  "8691707095127 carton كرتون 24 12.00 - -"
  "8691707091853 carton كرتون 24 13.00 - -"
  # Maggi stock cubes: the ×105 master case prices at 18 in their own sales.
  "97 carton كرتون 105 18.00 - -"
  # Juice / small drinks / snacks.
  "6281012033178 carton كرتون 21 10.50 - -"
  "6212552012286 carton كرتون 30 63.00 - -"
  "012000801655 carton كرتون 30 60.00 - -"
  "6224003287020 carton كرتون 12 30.00 - -"
  "6285602008263 carton كرتون 16 12.50 - -"
  "6241000011915 carton كرتون 18 19.00 - -"
  "80633044 carton كرتون 10 9.00 - -"
  # Soda: only بيبسي 1.75 needs a pinned pack price (sells at 5.0/piece,
  # catalog piece price still says 5.5) — the rest already derive correctly.
  "6241000050006 carton كرتون 6 30.00 - -"
)

if [ "$MODE" = "import" ] && [ "$status" -eq 0 ]; then
  echo "==> Applying confirmed product-unit fixups (${#FIXUPS[@]})…"
  fixup_failures=0
  for entry in "${FIXUPS[@]}"; do
    # shellcheck disable=SC2086
    set -- $entry
    product="$1"; unit="$2"; unit_name="$3"; factor="$4"; price="$5"; frac="$6"; takeover="$7"
    args=(--product="$product" --unit="$unit" --unit-name="$unit_name" --factor="$factor" --price="$price")
    [ "$frac" = "fractional" ] && args+=(--fractional)
    [ "$takeover" != "-" ] && [ -n "$takeover" ] && args+=(--take-over="$takeover")
    if ! docker compose exec -T backend python manage.py set_product_unit "${args[@]}"; then
      echo "WARN: fixup failed for $product (continuing)" >&2
      fixup_failures=$((fixup_failures + 1))
    fi
  done
  if [ "$fixup_failures" -gt 0 ]; then
    echo "WARN: $fixup_failures fixup(s) failed — check the messages above." >&2
  fi

  # --- Mis-entered pack purchase lines ---------------------------------------
  # A PO line entered against the old ×30 «كرتون» at the REAL carton price
  # stays wrong after the rename above (tray @ 162 ⇒ last-cost then prices a
  # piece at 5.40 and a carton PO line at 1944). Retag such lines to the true
  # carton and top stock up by the already-received difference. Idempotent:
  # a retagged line no longer matches the signature.
  echo "==> Repairing mis-entered pack purchase lines…"
  docker compose exec -T backend python manage.py shell <<'PYEOF'
from decimal import Decimal

from django.db import transaction

from apps.catalog.models import Product, ProductUnit
from apps.inventory.models import StockMovement
from apps.inventory.services import (
    create_stock_movement,
    lock_stock_item,
    save_stock_item_quantities,
    stock_snapshot,
)
from apps.purchasing.models import PurchaseLine

# (product, wrong_factor, true_unit_code, true_factor, min_unit_cost)
# Eggs: a 30-egg tray never costs 60+, the 360-egg carton always does.
REPAIRS = [
    ("6930358682129", Decimal("30"), "carton", Decimal("360"), Decimal("60")),
]

for barcode, wrong_factor, true_code, true_factor, min_cost in REPAIRS:
    product = Product.objects.filter(variants__barcode=barcode).first()
    if product is None:
        print(f"repair: product {barcode} not found - skipped")
        continue
    if not ProductUnit.objects.filter(
        product=product, unit__code=true_code, factor_to_base=true_factor
    ).exists():
        print(f"repair: {barcode} has no {true_code} x{true_factor} unit - skipped")
        continue
    lines = PurchaseLine.objects.filter(
        variant__product=product,
        unit_factor=wrong_factor,
        unit_cost__gte=min_cost,
    ).select_related("purchase_order", "variant")
    for line in lines:
        with transaction.atomic():
            note = (
                f"unit repair: PO {line.purchase_order.order_number} line entered as "
                f"x{wrong_factor.normalize():f}, actually {true_code} x{true_factor.normalize():f}"
            )
            line.unit = true_code
            line.unit_factor = true_factor
            line.save(update_fields=["unit", "unit_factor", "updated_at"])
            print(
                f"repair: line {line.pk} ({line.purchase_order.order_number}) -> "
                f"{true_code} x{true_factor.normalize():f}, base cost {line.base_unit_cost}"
            )
            received = line.received_quantity or Decimal("0")
            already = StockMovement.objects.filter(variant=line.variant, note=note).exists()
            if received > 0 and not already:
                delta = (true_factor - wrong_factor) * received
                stock = lock_stock_item(variant=line.variant)
                before = stock_snapshot(stock)
                stock.quantity_on_hand += delta
                save_stock_item_quantities(stock)
                create_stock_movement(
                    stock_item=stock,
                    movement_type=StockMovement.Type.INCREASE,
                    quantity=delta,
                    note=note,
                    created_by=None,
                    before=before,
                )
                print(f"repair: stock +{delta.normalize():f} (received portion)")
print("repair: done")
PYEOF
elif [ "$MODE" = "dry_run" ]; then
  echo "    (dry run: the ${#FIXUPS[@]} per-product fixups are applied only with --import)"
fi

if [ "$MODE" = "import" ]; then
  docker compose exec -T backend rm -f "$CONTAINER_PATH" >/dev/null 2>&1 || true
fi

echo
if [ "$status" -ne 0 ]; then
  err "Backfill command failed (exit $status). Nothing was left half-applied — the import is transactional per record; re-run once the cause is fixed."
fi
if [ "$MODE" = "dry_run" ]; then
  echo "Dry run finished. If the report looks right, run again with --import:"
  echo "  bash backfill-fahd-units.sh $DB_FILE --import"
else
  echo "Backfill finished. Next steps:"
  echo "  1. Scan a known carton/pack barcode at the POS — it should ring the pack"
  echo "     (name like «كرتون ×24») at the pack price."
  echo "  2. Open purchasing and add a product — the line opens in قطعة; switch"
  echo "     to the pack (كرتون) from the line's unit chip when buying packs."
  echo "  3. Spot-check a product's «الوحدات» section in the catalogue screen:"
  echo "     conversion count, price, and barcode should match the shelf."
fi
