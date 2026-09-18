"""Reports that only make sense once stock has names.

Four of them, and each answers a question a used-goods trader asks weekly and a
quantity-only system cannot be made to answer at all:

* **Aging / dead stock** — how long each article has been on the shelf, and how
  much capital is standing in each bucket. For a trade where depreciation is
  real and unpriced, this is the single most important report in the system.
* **Per-unit margin** — realised profit per article, because each has its own
  cost and its own price. A model-level average hides the handset that lost
  money behind the one that did well.
* **Unit ledger** — one identifier's whole life. The page a warranty claim, an
  insurance claim or a police question is answered from.
* **Consignment ledger & payables** — what is held, what sold, what is owed and
  what the shop earned, with the per-consignor statement underneath.
"""

from decimal import Decimal

from django.db.models import Q
from django.utils import timezone

from apps.inventory import consignment as consignment_figures
from apps.inventory.models import StockAllocation, StockUnit

from ..sections import (
    Column,
    ColumnType,
    bounded_rows,
    money,
    note,
    report_section,
)

ZERO = Decimal("0.00")

#: Where the buckets cut. Ninety days is the number a phone trader watches: past
#: it, the model has usually moved on and the price has to.
AGE_BUCKETS = ((0, 30), (30, 60), (60, 90), (90, 180), (180, None))


def _bucket_label(low, high):
    return f"{low}-{high}" if high is not None else f"{low}+"


def _when(value):
    """A timestamp as the stored payload can actually hold it.

    A report run is a JSON column, so a ``datetime`` in a row is a 500 at the
    moment the run is saved rather than at the moment it is built — which is
    exactly far enough from the mistake to be annoying.
    """
    return value.isoformat() if value is not None else ""


def _days_held(unit, today):
    since = unit.in_stock_since or unit.acquired_at
    if since is None:
        return 0
    return max((today - timezone.localtime(since).date()).days, 0)


def unit_aging(context):
    """What is standing on the shelf, and for how long.

    Counts what is physically here — consigned articles included, because they
    take up the same space and go just as stale — while the capital column is
    blind to them, because none of it is the shop's money.
    """
    today = context.period.end_date
    units = list(
        StockUnit.objects.filter(status__in=StockUnit.ON_HAND_STATUSES)
        .select_related("variant", "variant__product")
        .order_by("in_stock_since", "id")
    )
    buckets = {
        _bucket_label(low, high): {
            "bucket": _bucket_label(low, high),
            "unit_count": 0,
            "capital": ZERO,
            "consigned_count": 0,
        }
        for low, high in AGE_BUCKETS
    }
    rows = []
    total_capital = ZERO
    oldest = 0
    for unit in units:
        days = _days_held(unit, today)
        oldest = max(oldest, days)
        for low, high in AGE_BUCKETS:
            if days >= low and (high is None or days < high):
                bucket = buckets[_bucket_label(low, high)]
                bucket["unit_count"] += 1
                bucket["capital"] += unit.stock_value
                bucket["consigned_count"] += int(unit.is_consignment)
                break
        total_capital += unit.stock_value
        rows.append(
            {
                "code": unit.code,
                "product_name": unit.variant.full_name,
                "days_held": days,
                "capital": money(unit.stock_value),
                "asking_price": money(unit.list_price or unit.variant.unit_price),
                "is_consignment": unit.is_consignment,
            }
        )

    bucket_rows = [
        {
            "bucket": row["bucket"],
            "unit_count": row["unit_count"],
            "capital": money(row["capital"]),
            "consigned_count": row["consigned_count"],
        }
        for row in buckets.values()
    ]
    stale = sum(
        row["unit_count"]
        for row in buckets.values()
        if row["bucket"] in ("90-180", "180+")
    )
    stale_capital = sum(
        (
            Decimal(row["capital"])
            for row in bucket_rows
            if row["bucket"] in ("90-180", "180+")
        ),
        ZERO,
    )
    figures = {
        "unit_count": len(units),
        "capital_on_shelf": money(total_capital),
        "stale_unit_count": stale,
        "stale_capital": money(stale_capital),
        "oldest_days": oldest,
    }
    bounded = bounded_rows(rows, limit=context.row_limit("aging_units"))
    return {
        "summary": figures,
        "sections": [
            context.metrics(figures),
            report_section(
                "aging_buckets",
                [
                    Column("bucket", ColumnType.LABEL),
                    Column("unit_count", ColumnType.COUNT, total=True),
                    Column("capital", ColumnType.MONEY, total=True),
                    Column("consigned_count", ColumnType.COUNT, total=True),
                ],
                bucket_rows,
            ),
            report_section(
                "aging_units",
                [
                    Column("code"),
                    Column("product_name"),
                    Column("days_held", ColumnType.COUNT),
                    Column("capital", ColumnType.MONEY, total=True),
                    Column("asking_price", ColumnType.MONEY),
                    Column("is_consignment", ColumnType.CHOICE),
                ],
                bounded.rows,
                total_count=bounded.total_count,
                limit=bounded.limit,
            ),
        ],
        "notes": [
            note("aging_counts_consignment"),
            note("aging_capital_excludes_consignment"),
        ],
    }


def unit_margin(context):
    """Realised profit per article sold in the period.

    Each article carries its own cost — what it was bought for plus what was
    spent refurbishing it, or, for a consignment, what its owner was owed — so
    this is a subtraction rather than an allocation, and it is right down to the
    handset.
    """
    period = context.period
    units = list(
        StockUnit.objects.filter(
            status=StockUnit.Status.SOLD,
            sold_at__date__gte=period.start_date,
            sold_at__date__lte=period.end_date,
        )
        .select_related("variant", "variant__product")
        .order_by("-sold_at", "-id")
    )
    rows = []
    revenue = ZERO
    cost = ZERO
    loss_makers = 0
    for unit in units:
        sold_price = Decimal(unit.sold_price or 0)
        # What it cost the shop, whoever owned it: the payout for a consignment
        # (stamped at the sale), landed cost plus refurbishment for its own
        # stock. One definition, on the model, for both.
        unit_cost = unit.acquisition_cost
        profit = sold_price - unit_cost
        revenue += sold_price
        cost += unit_cost
        loss_makers += int(profit < 0)
        rows.append(
            {
                "code": unit.code,
                "product_name": unit.variant.full_name,
                "sold_at": _when(unit.sold_at),
                "sold_price": money(sold_price),
                "unit_cost": money(unit_cost),
                "refurb_cost": money(unit.refurb_cost),
                "profit": money(profit),
                "is_consignment": unit.is_consignment,
            }
        )
    figures = {
        "units_sold": len(units),
        "revenue": money(revenue),
        "cost": money(cost),
        "gross_profit": money(revenue - cost),
        "loss_making_units": loss_makers,
    }
    bounded = bounded_rows(rows, limit=context.row_limit("unit_margin"))
    return {
        "summary": figures,
        "sections": [
            context.metrics(figures),
            report_section(
                "unit_margin",
                [
                    Column("code"),
                    Column("product_name"),
                    Column("sold_at", ColumnType.DATETIME),
                    Column("sold_price", ColumnType.MONEY, total=True),
                    Column("unit_cost", ColumnType.MONEY, total=True),
                    Column("refurb_cost", ColumnType.MONEY, total=True),
                    Column("profit", ColumnType.MONEY, total=True),
                    Column("is_consignment", ColumnType.CHOICE),
                ],
                bounded.rows,
                total_count=bounded.total_count,
                limit=bounded.limit,
            ),
        ],
        "notes": [note("unit_margin_cost_includes_refurb")],
    }


def unit_ledger(context):
    """One identifier's whole life, in the order it happened.

    Takes a ``code`` parameter and refuses without one: this is a report about a
    thing, and there is no useful version of it that covers all of them.
    """
    code = str(context.params.get("code") or "").strip()
    if not code:
        from ..registry import ReportValidationError

        raise ReportValidationError("code")
    from apps.inventory.identity import normalize_identifier

    normalized = normalize_identifier(code)
    units = list(
        StockUnit.objects.filter(
            Q(code_normalized=normalized) | Q(secondary_code_normalized=normalized)
        ).select_related("variant", "variant__product", "customer", "supplier")
        .order_by("id")
    )
    allocations = list(
        StockAllocation.objects.filter(unit__in=units)
        .select_related("warehouse", "batch")
        .order_by("posting_at", "id")
    )
    rows = [
        {
            "posting_at": _when(allocation.posting_at),
            "voucher_type": allocation.voucher_type,
            "direction": allocation.direction,
            "warehouse": allocation.warehouse.name if allocation.warehouse_id else "",
            "batch": allocation.batch.display_code if allocation.batch_id else "",
            "rate": money(allocation.rate),
        }
        for allocation in allocations
    ]
    current = units[-1] if units else None
    figures = {
        "spell_count": len(units),
        "event_count": len(allocations),
        "status": current.status if current is not None else "",
        "cost": money(current.stock_value) if current is not None else money(ZERO),
    }
    return {
        "summary": figures,
        "sections": [
            context.metrics(figures),
            report_section(
                "unit_ledger",
                [
                    Column("posting_at", ColumnType.DATETIME),
                    Column("voucher_type", ColumnType.LABEL),
                    Column("direction", ColumnType.LABEL),
                    Column("warehouse"),
                    Column("batch"),
                    Column("rate", ColumnType.MONEY),
                ],
                rows,
            ),
        ],
        "notes": [note("unit_ledger_is_one_article")],
    }


def consignment_ledger(context):
    """الأمانات: what is held, what sold, what is owed, what the shop earned."""
    period = context.period
    from apps.core.money_dates import day_range_end, day_range_start

    start = day_range_start(period.start_date)
    end = day_range_end(period.end_date)
    position = consignment_figures.consignment_position(
        start=start, end=end, as_of=end
    )
    payables = list(
        consignment_figures.payable_units(as_of=end)
        .select_related("variant", "consignor", "sold_order_line__order")
        .order_by("sold_at", "id")
    )
    sold = list(
        StockUnit.objects.filter(
            is_consignment=True,
            status=StockUnit.Status.SOLD,
            sold_at__gte=start,
            sold_at__lte=end,
        )
        .select_related("variant", "consignor")
        .order_by("-sold_at", "-id")
    )
    today = period.end_date
    payable_rows = [
        {
            "consignor": unit.consignor.full_name if unit.consignor_id else "",
            "code": unit.code,
            "product_name": unit.variant.full_name,
            "sold_at": _when(unit.sold_at),
            "payout_due": money(consignment_figures.consignor_payout_due(unit)),
            "days_waiting": (
                (today - timezone.localtime(unit.sold_at).date()).days
                if unit.sold_at
                else 0
            ),
        }
        for unit in payables
    ]
    sold_rows = [
        {
            "consignor": unit.consignor.full_name if unit.consignor_id else "",
            "code": unit.code,
            "product_name": unit.variant.full_name,
            "sold_at": _when(unit.sold_at),
            "sold_price": money(unit.sold_price),
            "payout": money(consignment_figures.consignor_payout_due(unit)),
            "commission": money(
                Decimal(unit.sold_price or 0)
                - consignment_figures.consignor_payout_due(unit)
            ),
            "paid": unit.consignor_paid_at is not None,
        }
        for unit in sold
    ]
    figures = {
        # ≡ 0 by construction, and printed anyway: a consignment page that did
        # not say "the goods are worth nothing to this shop" would be read as
        # having forgotten to.
        "consignment_stock_value": money(position["stock_value"]),
        "consignor_payable": money(position["consignor_payable"]),
        "shop_commission": money(position["shop_commission"]),
        "custody_unit_count": position["custody"]["unit_count"],
        "custody_declared_value": money(position["custody"]["declared_value"]),
    }
    return {
        "summary": figures,
        "sections": [
            context.metrics(figures),
            report_section(
                "consignment_payables",
                [
                    Column("consignor"),
                    Column("code"),
                    Column("product_name"),
                    Column("sold_at", ColumnType.DATETIME),
                    Column("payout_due", ColumnType.MONEY, total=True),
                    Column("days_waiting", ColumnType.COUNT),
                ],
                payable_rows,
            ),
            report_section(
                "consignment_sales",
                [
                    Column("consignor"),
                    Column("code"),
                    Column("product_name"),
                    Column("sold_at", ColumnType.DATETIME),
                    Column("sold_price", ColumnType.MONEY, total=True),
                    Column("payout", ColumnType.MONEY, total=True),
                    Column("commission", ColumnType.MONEY, total=True),
                    Column("paid", ColumnType.CHOICE),
                ],
                sold_rows,
            ),
        ],
        "notes": [
            note("consignment_stock_value_is_zero"),
            note("consignment_payable_counts_credit_sales"),
        ],
    }


__all__ = ["consignment_ledger", "unit_aging", "unit_ledger", "unit_margin"]
