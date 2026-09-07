from django.utils import timezone
from rest_framework import serializers

from apps.catalog.models import ProductVariant

from .models import StockBatch, StockItem, StockLedgerEntry, StockMovement, Warehouse
from .valuation_service import post_movement_valuations

# The quantity columns a stock write touches, plus the timestamp that has to
# move with them. Shared by the single-row save and the batched one so the two
# can never write different field sets.
STOCK_QUANTITY_FIELDS = [
    "quantity_on_hand",
    "quantity_committed",
    "quantity_expected",
    "updated_at",
]


def resolve_warehouse_id(warehouse=None):
    """The place a stock write lands, defaulting to the shop's only one.

    Every caller that has not yet learned about warehouses passes nothing and
    gets the default — which is the whole invisibility guarantee in one line: a
    shop with a single location behaves exactly as it did before locations
    existed.
    """
    if warehouse is None:
        return Warehouse.default_id()
    return getattr(warehouse, "pk", warehouse)


def lock_stock_item(*, variant, warehouse=None):
    if variant is None:
        raise serializers.ValidationError({"variant": "Variant is required."})
    stock_item, _ = StockItem.objects.select_for_update().get_or_create(
        variant=variant,
        warehouse_id=resolve_warehouse_id(warehouse),
    )
    return stock_item


def lock_stock_items(variants, *, warehouse=None):
    """Lock a whole document's stock rows in one query, keyed by variant id.

    Locking row-by-row costs a ``SELECT ... FOR UPDATE`` per line on the busiest
    write path in the shop. One ``variant_id__in`` statement does the same work
    once. Two details are load-bearing:

    * ``order_by("variant_id")`` replaces ``StockItem.Meta.ordering``, which
      sorts through ``variant__product__name`` — that would join the catalog
      tables into a ``FOR UPDATE`` and lock their rows too. It also keeps the
      ascending-variant-id lock order the per-row loop established, which is
      what stops two concurrent carts deadlocking on a shared product.
    * A variant that has never held stock has no row yet, so those fall back to
      ``lock_stock_item`` (which creates one) — still ascending, and normally
      not reached at all.

    One call locks one warehouse: a sale leaves the till's location, a receipt
    arrives at one. The sort is on ``(variant_id, warehouse_id)`` even though a
    single-warehouse call cannot need the second column, because the transfer
    document is the first caller that will span two places and the deadlock
    guarantee has to already hold when it arrives.
    """
    variants_by_id = {variant.pk: variant for variant in variants if variant is not None}
    ordered_ids = sorted(variants_by_id)
    if not ordered_ids:
        return {}
    warehouse_id = resolve_warehouse_id(warehouse)
    locked = {
        stock_item.variant_id: stock_item
        for stock_item in StockItem.objects.select_for_update()
        .filter(variant_id__in=ordered_ids, warehouse_id=warehouse_id)
        .order_by("variant_id", "warehouse_id")
    }
    for variant_id in ordered_ids:
        if variant_id not in locked:
            locked[variant_id] = lock_stock_item(
                variant=variants_by_id[variant_id], warehouse=warehouse_id
            )
    return locked


def lock_stock_rows(pairs):
    """Lock a set of ``(variant, warehouse)`` rows in one statement.

    The two-warehouse cousin of ``lock_stock_items``, and the reason its sort
    key grew a second column. A transfer touches the source and the transit
    location in the same transaction, so two transfers running in opposite
    directions between the same pair of places would deadlock if each locked
    "its own" warehouse first. Taking every row a document needs in one
    ascending ``(variant_id, warehouse_id)`` pass makes that impossible.

    Returns ``{(variant_id, warehouse_id): StockItem}``.
    """
    wanted = sorted(
        {
            (getattr(variant, "pk", variant), getattr(warehouse, "pk", warehouse))
            for variant, warehouse in pairs
        }
    )
    if not wanted:
        return {}
    variant_ids = {variant_id for variant_id, _ in wanted}
    warehouse_ids = {warehouse_id for _, warehouse_id in wanted}
    locked = {
        (row.variant_id, row.warehouse_id): row
        for row in StockItem.objects.select_for_update()
        .filter(variant_id__in=variant_ids, warehouse_id__in=warehouse_ids)
        .order_by("variant_id", "warehouse_id")
    }
    # Pairs that have never held stock have no row yet. Created in the same
    # ascending order, so the lock sequence is unchanged.
    for key in wanted:
        if key not in locked:
            variant_id, warehouse_id = key
            locked[key] = lock_stock_item(
                variant=ProductVariant.objects.get(pk=variant_id),
                warehouse=warehouse_id,
            )
    return {key: locked[key] for key in wanted}


def stock_snapshot(stock_item):
    return {
        "on_hand": stock_item.quantity_on_hand,
        "committed": stock_item.quantity_committed,
        "expected": stock_item.quantity_expected,
    }


def save_stock_item_quantities(stock_item):
    stock_item.save(update_fields=STOCK_QUANTITY_FIELDS)


def save_stock_item_quantities_bulk(stock_items):
    """Write a whole document's adjusted stock rows in one UPDATE.

    ``bulk_update`` does not run a field's ``pre_save``, so ``updated_at``
    (``auto_now``) has to be stamped here — otherwise the batched write would
    leave the timestamp stale where the per-row save refreshes it.
    """
    rows = [stock_item for stock_item in stock_items if stock_item is not None]
    if not rows:
        return
    now = timezone.now()
    for stock_item in rows:
        stock_item.updated_at = now
    StockItem.objects.bulk_update(rows, STOCK_QUANTITY_FIELDS)


def build_stock_movement(
    *,
    stock_item,
    movement_type,
    quantity,
    note,
    created_by,
    before,
    variant=None,
    unit_cost=None,
):
    """The unsaved ledger row for one stock change, or ``None`` for a no-op.

    ``create_stock_movement`` saves it immediately; a multi-line document
    collects the instances instead and inserts them with
    ``create_stock_movements``. Both build the row here, so a batched write and
    a single one can never record different history.
    """
    variant = variant or stock_item.variant
    if variant is None:
        raise serializers.ValidationError({"variant": "Variant is required."})
    if stock_item.variant_id != variant.pk:
        raise serializers.ValidationError(
            {"variant": "Variant must match the locked stock item."}
        )
    if quantity <= 0:
        return None
    movement = StockMovement(
        variant=variant,
        stock_item=stock_item,
        # Set here rather than in ``save`` because a multi-line document builds
        # its movements unsaved and inserts them with ``bulk_create``, which
        # never calls ``save``.
        warehouse_id=stock_item.warehouse_id,
        movement_type=movement_type,
        quantity=quantity,
        note=note,
        created_by=created_by,
        on_hand_before=before["on_hand"],
        on_hand_after=stock_item.quantity_on_hand,
        committed_before=before["committed"],
        committed_after=stock_item.quantity_committed,
        expected_before=before["expected"],
        expected_after=stock_item.quantity_expected,
    )
    # Carried on the instance rather than in a side dictionary so a document
    # with the same variant on two lines at two different costs values each
    # line at what it actually cost.
    movement.valuation_unit_cost = unit_cost
    return movement


def create_stock_movement(
    *,
    voucher_type=StockLedgerEntry.VoucherType.ADJUSTMENT,
    voucher_id=None,
    unit_cost=None,
    posting_at=None,
    **kwargs,
):
    """Save one movement and value it.

    ``unit_cost`` is the cost per base unit of stock coming *in* — what a
    receipt paid, or what a returned sale line originally cost. Stock going
    *out* never takes a cost from the caller: the valuation engine decides it
    from what is actually on the shelf, which is the whole point of the ledger.
    """
    movement = build_stock_movement(unit_cost=unit_cost, **kwargs)
    if movement is None:
        return None
    movement.save()
    post_movement_valuations(
        [movement],
        voucher_type=voucher_type,
        voucher_id=voucher_id,
        posting_at=posting_at,
    )
    return movement


def create_stock_movements(
    movements,
    *,
    voucher_type=StockLedgerEntry.VoucherType.ADJUSTMENT,
    voucher_id=None,
    unit_costs=None,
    posting_at=None,
):
    """Insert a batch of built movements in one statement, then value them.

    Each returned movement carries ``valuation_rate_applied`` — the cost per
    base unit the ledger settled on — so a document can stamp what it really
    cost onto its own lines without a second query.
    """
    rows = [movement for movement in movements if movement is not None]
    if not rows:
        return []
    created = StockMovement.objects.bulk_create(rows)
    post_movement_valuations(
        created,
        voucher_type=voucher_type,
        voucher_id=voucher_id,
        posting_at=posting_at,
        unit_costs=unit_costs,
    )
    return created


def create_expiring_stock_batch(*, receipt_line, expiry_date, quantity):
    if expiry_date is None or quantity <= 0:
        return None
    variant = receipt_line.variant
    if not getattr(variant.product, "tracks_expiry", False):
        return None
    batch, _ = StockBatch.objects.get_or_create(
        source_receipt_line=receipt_line,
        defaults={
            "variant": variant,
            "expiry_date": expiry_date,
            "received_quantity": quantity,
            "remaining_quantity": quantity,
        },
    )
    return batch


def stock_count_needs_review(*, expected, counted, min_units, percent):
    """Decide whether a counted line should surface the variance prompt.

    Flags only when the gap is at least ``min_units`` AND at least ``percent``
    of the expected quantity, so neither tiny shops nor high-volume SKUs get
    noisy. When ``expected`` is 0 (e.g. first count of a new item) the percent
    rule can't apply, so the absolute floor alone decides.
    """
    gap = abs(counted - expected)
    if gap == 0:
        return False
    if gap < min_units:
        return False
    if expected == 0:
        return True
    gap_fraction_pct = (gap / abs(expected)) * 100
    return gap_fraction_pct >= percent


def consume_expiring_stock_batches(*, variant, quantity):
    if quantity <= 0 or not getattr(variant.product, "tracks_expiry", False):
        return 0

    remaining = quantity
    consumed = 0
    batches = (
        StockBatch.objects.select_for_update()
        .filter(variant=variant, remaining_quantity__gt=0)
        .order_by("expiry_date", "created_at", "id")
    )
    for batch in batches:
        if remaining <= 0:
            break
        used = min(batch.remaining_quantity, remaining)
        batch.remaining_quantity -= used
        batch.save(update_fields=["remaining_quantity", "updated_at"])
        remaining -= used
        consumed += used
    return consumed
