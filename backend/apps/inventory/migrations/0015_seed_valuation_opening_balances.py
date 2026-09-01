"""Open the valuation ledger for a shop that is already trading.

The shops running today have stock on the shelf that predates the ledger, so
the ledger has to start with an honest opening balance rather than with zero —
otherwise the first sale of every product would consume from an empty queue and
report a cost of nothing.

The opening rate is the last known purchase cost, which is exactly what those
shops were already using as their cost basis. So this migration changes no
reported number: it writes down what the shop was already assuming, and every
sale *after* it is valued properly.
"""

from decimal import Decimal

from django.db import migrations


def seed_opening_balances(apps, schema_editor):
    Warehouse = apps.get_model("inventory", "Warehouse")
    StockItem = apps.get_model("inventory", "StockItem")
    StockLedgerEntry = apps.get_model("inventory", "StockLedgerEntry")
    StockValuationBin = apps.get_model("inventory", "StockValuationBin")
    PurchaseLine = apps.get_model("purchasing", "PurchaseLine")
    ShopSettings = apps.get_model("core", "ShopSettings")

    warehouse, _ = Warehouse.objects.get_or_create(
        code="main",
        defaults={"name": "المخزن الرئيسي", "is_default": True},
    )
    if not warehouse.is_default:
        warehouse.is_default = True
        warehouse.save(update_fields=["is_default"])

    settings_row = ShopSettings.objects.first()
    method = (
        settings_row.inventory_valuation_method if settings_row else "moving_average"
    )

    stock_items = list(
        StockItem.objects.filter(quantity_on_hand__gt=0).values(
            "variant_id", "quantity_on_hand", "updated_at"
        )
    )
    if not stock_items:
        return

    variant_ids = [row["variant_id"] for row in stock_items]

    # Last non-cancelled purchase cost per variant, newest first — the same rule
    # the pre-ledger cost path used, so the opening value matches what the shop
    # already believed its stock was worth.
    costs = {}
    lines = (
        PurchaseLine.objects.filter(variant_id__in=variant_ids)
        # The literal, not ``PurchaseOrder.Status.CANCELLED``: a historical
        # model rebuilt from migration state carries only fields, managers and
        # Meta — never the nested TextChoices class. Reaching for it here raised
        # AttributeError on every shop that actually had stock to open with (an
        # empty database returns above, which is why the suite never saw it).
        .exclude(purchase_order__status="cancelled")
        .order_by("variant_id", "-created_at", "-id")
        .values("variant_id", "unit_cost", "unit_factor")
    )
    for line in lines.iterator():
        if line["variant_id"] in costs:
            continue
        factor = Decimal(line["unit_factor"] or 1)
        if factor <= 0:
            factor = Decimal(1)
        costs[line["variant_id"]] = Decimal(line["unit_cost"] or 0) / factor

    entries = []
    bins = []
    for row in stock_items:
        variant_id = row["variant_id"]
        quantity = Decimal(row["quantity_on_hand"])
        rate = costs.get(variant_id, Decimal("0"))
        value = (quantity * rate).quantize(Decimal("0.000001"))
        state = [[str(quantity), str(rate)]]
        entries.append(
            StockLedgerEntry(
                variant_id=variant_id,
                warehouse_id=warehouse.pk,
                posting_at=row["updated_at"],
                quantity_change=quantity,
                valuation_rate=rate.quantize(Decimal("0.000001")),
                value_change=value,
                balance_quantity=quantity,
                balance_value=value,
                state=state,
                method=method,
                voucher_type="opening",
                note="رصيد افتتاحي",
            )
        )
        bins.append(
            StockValuationBin(
                variant_id=variant_id,
                warehouse_id=warehouse.pk,
                quantity=quantity,
                valuation_rate=rate.quantize(Decimal("0.000001")),
                stock_value=value,
                state=state,
                method=method,
            )
        )

    StockLedgerEntry.objects.bulk_create(entries, batch_size=500)
    StockValuationBin.objects.bulk_create(bins, batch_size=500)


def drop_opening_balances(apps, schema_editor):
    StockLedgerEntry = apps.get_model("inventory", "StockLedgerEntry")
    StockValuationBin = apps.get_model("inventory", "StockValuationBin")
    StockLedgerEntry.objects.filter(voucher_type="opening").delete()
    StockValuationBin.objects.all().delete()


class Migration(migrations.Migration):
    dependencies = [
        ("inventory", "0014_warehouse_stockvaluationbin_stockledgerentry"),
        ("purchasing", "0001_initial"),
        ("core", "0023_shopsettings_inventory_valuation_method"),
    ]

    operations = [
        migrations.RunPython(seed_opening_balances, drop_opening_balances),
    ]
