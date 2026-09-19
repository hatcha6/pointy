"""What the valued stock ledger knows that the reports never asked it.

Two numbers have existed, correct and maintained, since the valuation engine
landed — and nothing outside this app ever read them:

* **What the stock cost.** Every report states stock at *retail*
  (``quantity_on_hand × unit_price``), which is an unrealisable number carrying
  margin the shop has not earned. ``StockValuationBin.stock_value`` is what the
  goods actually cost, and it is the figure that answers "how much of my money
  is sitting on the shelf".

* **What the shop lost.** A stock count that writes off missing goods records
  the money in ``StockLedgerEntry.value_change`` — and gross profit, computed
  from sold lines only, never moved. Theft and spoilage were free. This module
  makes them a line in the profit report.

A third was missing entirely: **what the stock was worth on a past day.** Year
end has exactly one non-negotiable number — the value of goods on hand at the
close of the last day of the year — and until now the only stock value the
product could produce was "right now". On 15 January, 31 December's stock was
already unrecoverable.

It was never unrecoverable in the data. ``StockLedgerEntry`` is append-only and
every row carries the running ``balance_quantity`` / ``balance_value`` for its
variant after that event, so the position on any past day is the last entry at
or before it, per variant. That is what ``*_as_of`` reads.

Why the last *entry* rather than the sum of ``value_change``: both are correct
arithmetic, but each row quantizes independently, so a running sum drifts from
the balance the engine actually holds. Reading the balance guarantees that
``stock_cost_value(as_of=today)`` equals ``stock_cost_value()`` to the fils,
which is the property a year-end tie-out depends on.
"""

from decimal import Decimal

from django.db.models import DecimalField, F, Sum, Value, Window
from django.db.models.functions import Coalesce, RowNumber

from apps.core.money_dates import day_range_end, day_range_start

from .models import StockLedgerEntry, StockValuationBin

MONEY_FIELD = DecimalField(max_digits=18, decimal_places=6)
MONEY_PLACES = Decimal("0.01")
QUANTITY_PLACES = Decimal("0.001")
ZERO = Decimal("0.00")

# Stock events that are neither a sale nor a purchase: what a count found, and
# what somebody adjusted by hand. Their value change is the shop getting richer
# or poorer without trading, which is exactly what shrinkage is.
SHRINKAGE_VOUCHER_TYPES = (
    StockLedgerEntry.VoucherType.STOCK_COUNT,
    StockLedgerEntry.VoucherType.ADJUSTMENT,
)


def stock_cost_value(as_of=None) -> Decimal:
    """What the goods on hand cost — now, or at the close of ``as_of``."""
    if as_of is None:
        total = StockValuationBin.objects.aggregate(
            total=Coalesce(Sum("stock_value"), Value(ZERO), output_field=MONEY_FIELD),
        )["total"]
        return (total or ZERO).quantize(MONEY_PLACES)

    total = sum(
        (entry.balance_value for entry in _balances_as_of(as_of)),
        Decimal("0"),
    )
    return total.quantize(MONEY_PLACES)


def stock_position_by_variant(as_of=None):
    """``{variant_id: (quantity, cost_value)}`` — now, or at ``as_of``.

    The per-line half of ``stock_cost_value``. A stock schedule that states a
    cost total has to show the cost of each line that makes it up, or it is not
    a schedule: nobody can test a total they cannot add up.
    """
    if as_of is None:
        # Summed across warehouses, not read row by row. A valuation bin is per
        # (variant, warehouse), so keying a dict on the variant alone made the
        # second warehouse's row *replace* the first's rather than add to it —
        # a schedule that silently reported one location's stock as the shop's.
        # Invisible while every shop had one warehouse, which is exactly when it
        # had to be fixed. The ``as_of`` branch below already accumulates.
        return {
            row["variant_id"]: (
                Decimal(row["quantity"]).quantize(QUANTITY_PLACES),
                Decimal(row["stock_value"]).quantize(MONEY_PLACES),
            )
            for row in StockValuationBin.objects.values("variant_id").annotate(
                quantity=Sum("quantity"), stock_value=Sum("stock_value")
            )
        }

    position = {}
    for entry in _balances_as_of(as_of):
        quantity, value = position.get(entry.variant_id, (ZERO, ZERO))
        position[entry.variant_id] = (
            quantity + Decimal(entry.balance_quantity),
            value + Decimal(entry.balance_value),
        )
    return {
        variant_id: (
            quantity.quantize(QUANTITY_PLACES),
            value.quantize(MONEY_PLACES),
        )
        for variant_id, (quantity, value) in position.items()
    }


def _balances_as_of(as_of):
    """The last ledger entry per variant and warehouse at the close of ``as_of``.

    One query. The window ranks each variant's entries newest-first on the same
    ``(posting_at, id)`` order the ledger itself is ordered by — not on ``id``
    alone, because a backdated correction is appended with a higher id and an
    earlier posting date, and ranking by id would read it as the latest
    position.
    """
    return (
        StockLedgerEntry.objects.filter(posting_at__lt=day_range_end(as_of))
        .annotate(
            recency=Window(
                expression=RowNumber(),
                partition_by=[F("variant_id"), F("warehouse_id")],
                order_by=[F("posting_at").desc(), F("id").desc()],
            )
        )
        .filter(recency=1)
        .only("variant_id", "balance_quantity", "balance_value")
    )


def stock_movement_values(start, end):
    """What stock was worth coming in and going out over a period.

    The three numbers a closing-stock schedule is tested against: opening plus
    received less issued equals closing. Signed by the ledger, split here so a
    reader sees purchases and cost of sales separately rather than one net
    figure that hides both.
    """
    rows = (
        StockLedgerEntry.objects.filter(
            posting_at__gte=day_range_start(start),
            posting_at__lt=day_range_end(end),
        )
        .values("voucher_type")
        .annotate(
            value=Coalesce(
                Sum("value_change"), Value(ZERO), output_field=MONEY_FIELD
            ),
            quantity=Coalesce(
                Sum("quantity_change"),
                Value(Decimal("0")),
                output_field=DecimalField(max_digits=14, decimal_places=3),
            ),
        )
    )
    received = ZERO
    issued = ZERO
    by_type = {}
    for row in rows:
        value = Decimal(row["value"] or ZERO)
        by_type[row["voucher_type"]] = {
            "value": value.quantize(MONEY_PLACES),
            "quantity": Decimal(row["quantity"] or 0).quantize(QUANTITY_PLACES),
        }
        if value >= 0:
            received += value
        else:
            issued += -value
    return {
        "received_value": received.quantize(MONEY_PLACES),
        "issued_value": issued.quantize(MONEY_PLACES),
        "by_voucher_type": by_type,
    }


def shrinkage_value(start, end) -> Decimal:
    """Money lost to counts and adjustments over a period, as a positive cost.

    The ledger signs a write-off negative and a write-up positive, so the sign
    is flipped here: callers are asking "what did this cost me", and a count
    that *found* stock returns a negative cost, correctly reducing the loss.
    """
    total = StockLedgerEntry.objects.filter(
        voucher_type__in=SHRINKAGE_VOUCHER_TYPES,
        posting_at__gte=day_range_start(start),
        posting_at__lt=day_range_end(end),
    ).aggregate(
        total=Coalesce(Sum("value_change"), Value(ZERO), output_field=MONEY_FIELD),
    )["total"]
    return (-(total or ZERO)).quantize(MONEY_PLACES)


__all__ = [
    "SHRINKAGE_VOUCHER_TYPES",
    "shrinkage_value",
    "stock_cost_value",
    "stock_movement_values",
    "stock_position_by_variant",
]


# ---------------------------------------------------------------------------
# Goods that will expire before they sell
# ---------------------------------------------------------------------------

#: How hard to cut, by how close the date is. A shop that discounts a week
#: before expiry has already lost the sale; one that discounts ninety days out
#: has given away margin it did not need to.
MARKDOWN_LADDER = (
    (7, Decimal("0.50")),
    (14, Decimal("0.35")),
    (30, Decimal("0.20")),
    (60, Decimal("0.10")),
)


def expiry_markdown_suggestions(batches):
    """``{batch_id: suggestion}`` — what to cut, and what it saves.

    Advice, never an action. Two things bound it and both matter:

    * **The floor is cost.** Selling below what the goods cost turns a
      write-off into a smaller write-off plus a customer who now expects that
      price; the ladder is clamped so the suggested price never goes under the
      lot's own incoming rate.
    * **The saving is the write-off avoided**, not the discount given. What
      the shop is comparing is *sell it at 6 or bin it at 10*, and a report
      that showed the discount as a loss would argue for doing nothing.
    """
    from django.utils import timezone

    today = timezone.localdate()
    suggestions = {}
    for batch in batches:
        if batch.expiry_date is None:
            continue
        remaining = sum(
            (balance.remaining_quantity for balance in batch.balances.all()),
            Decimal("0"),
        )
        if remaining <= 0:
            continue
        days_left = (batch.expiry_date - today).days
        cut = next(
            (
                fraction
                for horizon, fraction in MARKDOWN_LADDER
                if days_left <= horizon
            ),
            None,
        )
        if cut is None:
            continue
        price = Decimal(batch.variant.unit_price or 0)
        cost = max(
            (balance.incoming_rate for balance in batch.balances.all()),
            default=Decimal("0"),
        )
        suggested = (price * (Decimal("1") - cut)).quantize(Decimal("0.01"))
        floored = max(suggested, Decimal(cost).quantize(Decimal("0.01")))
        suggestions[batch.pk] = {
            "days_left": days_left,
            "discount_pct": float(cut * 100),
            "current_price": price,
            "suggested_price": floored,
            "at_cost_floor": floored > suggested,
            "quantity": remaining,
            # Sell it at the suggested price or bin it at cost: this is what
            # the second outcome costs, which is the number worth acting on.
            "write_off_avoided": (Decimal(cost) * remaining).quantize(
                Decimal("0.01")
            ),
        }
    return suggestions
