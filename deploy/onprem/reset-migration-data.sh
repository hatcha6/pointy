#!/usr/bin/env bash
#
# Reset all legacy-migration-imported data to a clean slate, so migrate-fahd.sh
# can re-import from scratch instead of failing on residual / half-applied data.
# Self-contained: the deletion logic is embedded below and piped into Django.
#
# Run from the deploy directory (next to docker-compose.yml), same place as
# migrate-fahd.sh:
#
#   bash reset-migration-data.sh            # DRY RUN — shows counts, deletes nothing
#   bash reset-migration-data.sh --apply    # backs up the DB, then deletes for real
#
# The dry run deletes inside a transaction and rolls back, so its report is the
# exact set of rows a real run would remove. Read it first. --apply takes a
# compressed pg_dump backup and makes you type "delete" before it commits.
#
# Deletes products, categories, customers, suppliers, purchases, sales — plus
# every record that references them (payments, expenses, stock, print/operations
# jobs, discount redemptions) and the migration identity map (so the re-import
# starts fresh). Preserves users, settings, devices, and all configuration.
set -euo pipefail
cd "$(dirname "$0")" 2>/dev/null || true

err() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

APPLY=0
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) err "Unknown argument: $arg (use --apply to delete; default is a dry run)." ;;
  esac
done

[ -f docker-compose.yml ] || err "docker-compose.yml not found — run this from the Pointy deploy directory."
command -v docker >/dev/null 2>&1 || err "Docker is not installed."
docker compose ps --status running backend --quiet 2>/dev/null | grep -q . \
  || err "The backend container is not running. Start the stack first (bash install.sh)."

if [ "$APPLY" = "1" ]; then
  # Load the DB password so pg_dump authenticates regardless of pg_hba config.
  if [ -f .env ]; then set -a; . ./.env; set +a; fi
  ts="$(date +%Y%m%d-%H%M%S)"
  backup="pointy-db-backup-${ts}.sql.gz"
  echo "==> Backing up the database first → $backup"
  docker compose exec -T -e PGPASSWORD="${POINTY_POSTGRES_PASSWORD:-}" postgres \
    pg_dump -U pointy -d pointy | gzip > "$backup" \
    || { rm -f "$backup"; err "Backup failed — aborting before any delete."; }
  [ "$(wc -c < "$backup")" -gt 500 ] || { rm -f "$backup"; err "Backup looks empty — aborting."; }
  echo "    Saved $(du -h "$backup" | cut -f1) to $(pwd)/$backup"
  echo
  echo "!!  This PERMANENTLY DELETES all imported products, categories, customers,"
  echo "!!  suppliers, purchases and sales (and their payments, expenses, stock,"
  echo "!!  jobs …) and resets the migration identity map. Restore from the backup"
  echo "!!  above if you need to undo it."
  printf '!!  Type exactly "delete" to proceed, or anything else to abort: '
  read -r confirm
  [ "$confirm" = "delete" ] || err "Aborted — you did not type 'delete'. Nothing was deleted."
fi

echo "==> Running reset ($([ "$APPLY" = 1 ] && echo 'APPLY' || echo 'dry run')) …"
# Piped to a non-TTY `manage.py shell`, Django exec()s the script below.
docker compose exec -T -e RESET_APPLY="$APPLY" backend python manage.py shell <<'PYEOF'
import os
from django.apps import apps
from django.db import transaction
from django.db.models import ProtectedError

APPLY = os.environ.get("RESET_APPLY") == "1"

# (app_label, ModelName) in deletion order: any model that PROTECT-references a
# target is listed BEFORE that target. Missing models are skipped. CASCADE
# children and M2M through-rows are removed automatically by Django.
DELETE_ORDER = [
    ("payments", "Payment"),
    ("printing", "PrintJob"),
    ("operations", "JobStageEvent"),
    ("operations", "JobMaterial"),
    ("operations", "JobAsset"),
    ("operations", "Job"),
    ("expenses", "Expense"),
    ("discounts", "DiscountRedemption"),
    ("discounts", "AppliedDiscount"),
    ("sales", "OrderExchange"),
    ("sales", "OrderAdjustmentLine"),
    ("sales", "OrderAdjustment"),
    ("sales", "StockReservation"),
    ("sales", "OrderLineModifier"),
    ("sales", "OrderLine"),
    ("sales", "Order"),
    ("sales", "RegisterCashMovement"),
    ("sales", "RegisterSession"),
    ("inventory", "StockCountLine"),
    ("inventory", "StockCount"),
    ("inventory", "StockBatch"),
    ("inventory", "StockMovement"),
    ("inventory", "StockItem"),
    ("purchasing", "SupplierCredit"),
    ("purchasing", "SupplierPayment"),
    ("purchasing", "PurchaseReceiptLine"),
    ("purchasing", "PurchaseReceipt"),
    ("purchasing", "PurchaseOrderAdjustmentReplacementLine"),
    ("purchasing", "PurchaseOrderAdjustmentLine"),
    ("purchasing", "PurchaseOrderAdjustment"),
    ("purchasing", "PurchaseLine"),
    ("purchasing", "PurchaseOrderLandedCostEntry"),
    ("purchasing", "PurchaseOrderAuditEvent"),
    ("purchasing", "PurchaseOrder"),
    ("purchasing", "Supplier"),
    ("crm", "ConsentEvent"),
    ("crm", "CampaignRecipient"),
    ("customers", "PaymentCard"),
    ("customers", "Asset"),
    ("customers", "Customer"),
    ("catalog", "BomLine"),
    ("catalog", "BillOfMaterials"),
    ("catalog", "ProductModifierGroup"),
    ("catalog", "ProductUnit"),
    ("catalog", "ProductAlias"),
    ("catalog", "ProductVariant"),
    ("catalog", "Product"),
    ("migration", "MigrationIdentityMap"),
    ("migration", "MigrationIssue"),
    ("migration", "MigrationRun"),
]

counts = {}

def record(per):
    for label, n in per.items():
        counts[label] = counts.get(label, 0) + n

def get(app_label, name):
    try:
        return apps.get_model(app_label, name)
    except LookupError:
        return None

class DryRunRollback(Exception):
    pass

print("=" * 64)
print("  Legacy-migration data reset")
print("  MODE:", "APPLY - rows WILL be deleted" if APPLY else "DRY RUN - nothing will be deleted")
print("=" * 64)

try:
    with transaction.atomic():
        for app_label, name in DELETE_ORDER:
            model = get(app_label, name)
            if model is not None:
                record(model.objects.all().delete()[1])

        # ProductCategory.parent is a self-referential PROTECT FK, so delete
        # leaf categories (no children) and repeat up the tree.
        category = get("catalog", "ProductCategory")
        if category is not None:
            while category.objects.exists():
                deleted, per = category.objects.filter(children__isnull=True).delete()
                if not deleted:
                    break
                record(per)

        print("")
        print("Rows deleted, by table:")
        if counts:
            for label in sorted(counts):
                print("  %-48s %9d" % (label, counts[label]))
            print("  %-48s %9d" % ("TOTAL", sum(counts.values())))
        else:
            print("  (nothing to delete - the database is already clean)")

        if not APPLY:
            raise DryRunRollback()
        print("")
        print("APPLIED - the transaction was committed.")
except DryRunRollback:
    print("")
    print("DRY RUN complete - the transaction was rolled back; NOTHING was deleted.")
    print("If the counts look right, re-run with:  bash reset-migration-data.sh --apply")
except ProtectedError as exc:
    print("")
    print("BLOCKED by a PROTECT foreign key - NOTHING was deleted:")
    print("  ", exc)
    print("Send this line to the developer so the deletion order can be extended.")
    raise
PYEOF

echo
if [ "$APPLY" = "1" ]; then
  echo "Done. Now re-run the migration from the freshly cleaned database:"
  echo "  bash migrate-fahd.sh /path/to/fahd_migration.sqlite            # dry run"
  echo "  bash migrate-fahd.sh /path/to/fahd_migration.sqlite --import   # real import"
else
  echo "Dry run finished — nothing was deleted. If the counts look right, run:"
  echo "  bash reset-migration-data.sh --apply"
fi
