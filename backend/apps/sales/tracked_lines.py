"""What a sale line moved, when the goods had names.

A receipt for a handset is a warranty document, and a receipt for a medicine is
a traceability record that a pharmacy is required to be able to produce. Both
are the same question — *which articles left on this line* — and both are
answered from rows the sale already wrote, never from a text field somebody
remembered to fill in.

The two sources are deliberately different, because the two modes are:

* a **serialized** line names its own units, which carry the sale line on
  ``StockUnit.sold_order_line``;
* a **lot-tracked** line names the cohorts the FEFO pick drew from, which live
  on the ledger's allocations — and there may be two of them for one line, when
  a sale of ten packs emptied one lot and spilled into the next.
"""

from __future__ import annotations

from apps.catalog.models import Product


def order_line_identifiers(line) -> list:
    """``[{kind, code, expiry_date, quantity}]`` for one sale line.

    Empty — and free — for a line of anything untracked: the mode is read off
    the product the line already carries, and neither query below runs.
    """
    variant = getattr(line, "variant", None)
    product = getattr(variant, "product", None) if variant is not None else None
    if product is None or product.tracking_mode == Product.TrackingMode.QUANTITY:
        return []

    rows = []
    if product.tracks_units:
        for unit in _units_of(line):
            rows.append(
                {
                    "kind": "unit",
                    "code": unit.code,
                    "identifier_kind": unit.identifier_kind,
                    "batch_code": unit.batch.display_code if unit.batch_id else "",
                    "expiry_date": (
                        unit.batch.expiry_date.isoformat()
                        if unit.batch_id and unit.batch.expiry_date
                        else ""
                    ),
                    "quantity": "1",
                    # So the returns desk can ask the one question it has to ask
                    # before taking a consigned article back: its owner has
                    # already been paid, and somebody has to decide whether the
                    # shop keeps what it paid for (§5.8).
                    "is_consignment": unit.is_consignment,
                    "consignor_paid": unit.consignor_paid_at is not None,
                }
            )
        return rows

    for allocation in _allocations_of(line):
        batch = allocation.batch
        rows.append(
            {
                "kind": "batch",
                "code": batch.display_code if batch is not None else "",
                "identifier_kind": "lot",
                "batch_code": batch.display_code if batch is not None else "",
                "expiry_date": (
                    batch.expiry_date.isoformat()
                    if batch is not None and batch.expiry_date
                    else ""
                ),
                "quantity": str(allocation.quantity),
            }
        )
    return rows


def _units_of(line):
    from apps.inventory.models import StockUnit

    prefetched = getattr(line, "_prefetched_objects_cache", None)
    if prefetched is not None and "stock_units" in prefetched:
        return line.stock_units.all()
    return StockUnit.objects.filter(sold_order_line=line).select_related("batch")


#: Where one order's ``out`` allocations are cached while its lines serialize.
#: A lot allocation has no per-line foreign key — it belongs to the *movement*,
#: one per variant per sale — so it cannot be prefetched the way units are.
#: Fetching the order's allocations once and grouping them in Python turns a
#: query per tracked line into a query per order.
_ALLOCATIONS_ATTR = "_pointy_sale_allocations"


def _allocations_of(line):
    """The ``out`` allocations this line's sale wrote for this variant.

    Scoped by voucher and variant rather than by line, because an allocation
    belongs to the *movement* — one per variant per sale — and a sale that put
    the same variant on two lines issued its lots once. A pharmacy printing two
    lines for one drug would rather see the lots on both than on neither.
    """
    from apps.inventory.models import StockAllocation, StockLedgerEntry

    order_id = getattr(line, "order_id", None)
    if order_id is None:
        return []

    order = getattr(line, "order", None)
    cached = getattr(order, _ALLOCATIONS_ATTR, None) if order is not None else None
    if cached is None:
        rows = (
            StockAllocation.objects.filter(
                voucher_type=StockLedgerEntry.VoucherType.SALE,
                voucher_id=order_id,
                direction=StockAllocation.Direction.OUT,
            )
            .select_related("batch")
            .order_by("id")
        )
        cached = {}
        for row in rows:
            cached.setdefault(row.variant_id, []).append(row)
        if order is not None:
            setattr(order, _ALLOCATIONS_ATTR, cached)
    return cached.get(line.variant_id, [])


__all__ = ["order_line_identifiers"]
