"""Turn today's anonymous expiry cohorts into lot identities with balances.

Until now a ``StockBatch`` was a quantity keyed one-to-one to a receipt line: no
code, no place, and its quantity welded to the row that should have been its
identity. Splitting it is the one decision in this feature that is cheap before
there is lot data on the table and structural surgery afterwards, which is why
it lands in the first phase whether or not a pharmacy has signed.

Each existing row becomes:

* **one identity** — with a deterministic internal code (``RL-<receipt line>``)
  marked ``code_is_generated``, so the unique constraint has something real to
  constrain and the UI can honestly render «بدون رقم دفعة» rather than a number
  nobody printed; and the supplier lifted off the receipt line it came from,
  which is where a fact about a factory run belongs;
* **one balance** in the shop's default warehouse — which is the only warehouse
  most shops have, and is exactly where that stock already implicitly was;
* **one ``in`` allocation** written from the receipt line the batch pointed at,
  so the provenance that column used to hold survives its removal. Provenance is
  the allocations from here on: a lot arriving in three deliveries has three of
  them, where a column could only ever hold one and would be read as though it
  held all three.

Nothing about what is on a shelf changes. ``remaining_quantity`` moves from the
lot to its balance unchanged, the expiry date is copied, and the incoming rate
is taken from the receipt line's landed cost per base unit so the new
batch-wise valuation starts from the same number the bin already holds. The
upgrade-rehearsal harness asserts exactly that: every bin, every stock value and
every past sale's COGS identical before and after.
"""

from decimal import Decimal

from django.db import migrations

#: Mirrors ``apps.inventory.identity.normalize_identifier`` closely enough for
#: the codes this migration generates, which are ASCII by construction. The real
#: one is not imported: a migration must keep working when the function it was
#: written against changes shape.
def _normalize(value):
    return "".join(
        char for char in str(value or "").strip() if char not in {" ", "-", ".", "_"}
    ).upper()


def _default_warehouse_id(apps):
    Warehouse = apps.get_model("inventory", "Warehouse")
    row = Warehouse.objects.order_by("id").values_list("id", flat=True).first()
    return row


def _landed_rate(receipt_line):
    """What this delivery paid per base unit, or zero when it cannot be known.

    The same expression ``PurchaseLine.effective_base_unit_cost`` evaluates —
    written out here rather than imported because a migration must survive the
    model changing underneath it, and re-stated with the same
    ``uom-cost-normalization`` division that every base-unit read in this
    codebase pays: a 162-per-carton line is 0.45 per egg.
    """
    if receipt_line is None:
        return Decimal("0")
    line = getattr(receipt_line, "purchase_line", None)
    if line is None:
        return Decimal("0")
    cost = Decimal(getattr(line, "effective_unit_cost", 0) or 0)
    factor = Decimal(getattr(line, "unit_factor", 1) or 1)
    if factor <= 0:
        return cost
    return (cost / factor).quantize(Decimal("0.000001"))


def split_batches(apps, schema_editor):
    StockBatch = apps.get_model("inventory", "StockBatch")
    StockBatchBalance = apps.get_model("inventory", "StockBatchBalance")
    StockAllocation = apps.get_model("inventory", "StockAllocation")

    batches = list(
        StockBatch.objects.select_related(
            "source_receipt_line",
            "source_receipt_line__purchase_line",
            "source_receipt_line__receipt",
        ).order_by("id")
    )
    if not batches:
        return
    warehouse_id = _default_warehouse_id(apps)
    if warehouse_id is None:
        # No warehouse means no stock has ever moved, so there is nothing these
        # rows could be describing. Leave them for the constraint to reject
        # loudly rather than inventing a place to put them.
        return

    balances = []
    allocations = []
    for batch in batches:
        receipt_line = batch.source_receipt_line
        code = f"RL-{receipt_line.pk}" if receipt_line else f"LOT-{batch.pk}"
        batch.code = code
        batch.code_normalized = _normalize(code)
        batch.code_is_generated = True
        batch.status = "active"
        if receipt_line is not None:
            purchase_line = getattr(receipt_line, "purchase_line", None)
            order = getattr(
                getattr(receipt_line, "receipt", None), "purchase_order_id", None
            )
            if purchase_line is not None and order is not None:
                batch.supplier_id = _supplier_of(apps, order)
        received = Decimal(batch.received_quantity or 0)
        remaining = Decimal(batch.remaining_quantity or 0)
        rate = _landed_rate(receipt_line)
        balances.append(
            StockBatchBalance(
                batch=batch,
                warehouse_id=warehouse_id,
                variant_id=batch.variant_id,
                received_quantity=received,
                remaining_quantity=remaining,
                incoming_rate=rate,
                first_received_at=batch.created_at,
                expiry_date=batch.expiry_date,
                is_sellable=True,
            )
        )
        if received > 0:
            allocations.append(
                StockAllocation(
                    unit=None,
                    batch=batch,
                    variant_id=batch.variant_id,
                    warehouse_id=warehouse_id,
                    direction="in",
                    quantity=received,
                    rate=rate,
                    value_change=(received * rate).quantize(Decimal("0.000001")),
                    voucher_type="purchase_receipt",
                    voucher_id=(
                        getattr(
                            getattr(receipt_line, "receipt", None),
                            "purchase_order_id",
                            None,
                        )
                        if receipt_line
                        else None
                    ),
                    posting_at=batch.created_at,
                    note="ترحيل الدفعات إلى الهوية والرصيد",
                )
            )

    StockBatch.objects.bulk_update(
        batches,
        ["code", "code_normalized", "code_is_generated", "status", "supplier"],
        batch_size=500,
    )
    StockBatchBalance.objects.bulk_create(balances, batch_size=500)
    if allocations:
        StockAllocation.objects.bulk_create(allocations, batch_size=500)


_SUPPLIER_CACHE = {}


def _supplier_of(apps, purchase_order_id):
    if purchase_order_id in _SUPPLIER_CACHE:
        return _SUPPLIER_CACHE[purchase_order_id]
    PurchaseOrder = apps.get_model("purchasing", "PurchaseOrder")
    supplier_id = (
        PurchaseOrder.objects.filter(pk=purchase_order_id)
        .values_list("supplier_id", flat=True)
        .first()
    )
    _SUPPLIER_CACHE[purchase_order_id] = supplier_id
    return supplier_id


def unsplit_batches(apps, schema_editor):
    """Put the quantities back on the lots and drop what the split created.

    Reversible because the forward direction only ever *copied*: the quantity
    columns are still there at this point in the sequence (0027 removes them),
    so nothing has to be reconstructed.
    """
    StockBatchBalance = apps.get_model("inventory", "StockBatchBalance")
    StockAllocation = apps.get_model("inventory", "StockAllocation")
    StockAllocation.objects.filter(
        note="ترحيل الدفعات إلى الهوية والرصيد"
    ).delete()
    StockBatchBalance.objects.all().delete()


class Migration(migrations.Migration):
    dependencies = [
        ("inventory", "0025_identified_stock"),
        ("purchasing", "0034_seed_order_number_series"),
    ]

    operations = [
        migrations.RunPython(split_batches, unsplit_batches),
    ]
