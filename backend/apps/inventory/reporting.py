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
"""

from decimal import Decimal

from django.db.models import DecimalField, Sum, Value
from django.db.models.functions import Coalesce

from apps.core.money_dates import day_range_end, day_range_start

from .models import StockLedgerEntry, StockValuationBin

MONEY_FIELD = DecimalField(max_digits=18, decimal_places=6)
MONEY_PLACES = Decimal("0.01")
ZERO = Decimal("0.00")

# Stock events that are neither a sale nor a purchase: what a count found, and
# what somebody adjusted by hand. Their value change is the shop getting richer
# or poorer without trading, which is exactly what shrinkage is.
SHRINKAGE_VOUCHER_TYPES = (
    StockLedgerEntry.VoucherType.STOCK_COUNT,
    StockLedgerEntry.VoucherType.ADJUSTMENT,
)


def stock_cost_value() -> Decimal:
    """What the goods on hand actually cost — the ledger's own stock value."""
    total = StockValuationBin.objects.aggregate(
        total=Coalesce(Sum("stock_value"), Value(ZERO), output_field=MONEY_FIELD),
    )["total"]
    return (total or ZERO).quantize(MONEY_PLACES)


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


__all__ = ["SHRINKAGE_VOUCHER_TYPES", "shrinkage_value", "stock_cost_value"]
