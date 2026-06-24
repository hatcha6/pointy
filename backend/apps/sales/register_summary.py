"""Per-session register summary used by the manager session view and the
printable Z-Report (thermal + PDF).

This is the single source of truth for a register session's end-of-shift
picture across **all** payment methods (not just cash). The on-screen summary
and both print formats render the same payload returned by
``build_register_session_summary`` so they can never disagree.

Attribution mirrors the model's drawer accounting:

* **Sales / categories** come from the orders the session *issued*
  (``Order.register_session``), restricted to recognized sales
  (``OrderQuerySet.committed_sales``: standard-paid + credit-issued, excluding
  quotations and voids).
* **Payment methods** come from the payments the session *collected*
  (``Payment.register_session``) — the same basis as
  ``RegisterSession.cash_sales_total`` — so a debt invoice settled in a later
  shift lands in the collecting drawer.
* **Cash reconciliation** reuses the ``RegisterSession`` model properties
  verbatim; the cash refund figure is the exact drawer hit (``cash_amount``),
  while the per-method refund rows group by ``refund_method`` over ``amount``.
"""

from collections import OrderedDict
from decimal import Decimal

from django.db.models import Count, Sum

from apps.expenses.models import Expense
from apps.payments.models import Payment

from .models import Order, OrderAdjustment, RegisterSession

MONEY = Decimal("0.01")
QTY = Decimal("0.001")
UNCATEGORIZED = "__uncategorized__"


def _money(value) -> str:
    """Render money as a fixed 2dp string, matching the rest of the API
    (DRF ``DecimalField`` serialises money to strings)."""
    return str((value or Decimal("0")).quantize(MONEY))


def _qty(value) -> str:
    """Render a quantity as a trimmed decimal string (e.g. ``"3"`` or
    ``"1.5"``) so whole units don't show needless zeros on the report."""
    quantized = (value or Decimal("0")).quantize(QTY)
    normalized = quantized.normalize()
    # ``normalize`` can yield scientific notation for integers (e.g. 1E+1);
    # format through ``f`` to force plain notation, then trim.
    text = f"{normalized:f}"
    if "." in text:
        text = text.rstrip("0").rstrip(".")
    return text or "0"


def _primary_category(product):
    """The single category a product's sales are reported under. Picks the
    lowest ``display_order`` (then name/id) so a product in several categories
    is counted once — avoids the double counting an M2M ``GROUP BY`` causes.
    Returns ``None`` for an uncategorized product."""
    categories = list(product.categories.all())
    if not categories:
        return None
    categories.sort(key=lambda c: (c.display_order, c.name, c.id))
    return categories[0]


def build_register_session_summary(session: RegisterSession) -> dict:
    """Aggregate everything a manager needs to review/print a shift."""
    sales, categories = _sales_and_categories(session)
    refunds, refund_by_method = _refunds(session)
    payment_methods, payment_totals = _payment_methods(session, refund_by_method)
    return {
        "session": _session_header(session),
        "sales": {**sales, "net_sales": _money(_dec(sales["net_sales"]) - refunds["refund_total_dec"])},
        "refunds": {
            "refund_total": _money(refunds["refund_total_dec"]),
            "return_count": refunds["return_count"],
            "cash_refund_total": _money(session.cash_refund_total),
        },
        "payment_methods": payment_methods,
        "payment_totals": payment_totals,
        "categories": categories,
        "cash": _cash_reconciliation(session),
        "expenses": _expenses(session),
    }


def _session_header(session: RegisterSession) -> dict:
    owner = session.owner
    owner_name = ""
    if owner is not None:
        owner_name = owner.get_full_name() or owner.get_username()
    return {
        "id": session.pk,
        "session_number": session.session_number,
        "status": session.status,
        "owner_name": owner_name,
        "opened_at": session.opened_at.isoformat() if session.opened_at else None,
        "closed_at": session.closed_at.isoformat() if session.closed_at else None,
    }


def _sales_and_categories(session: RegisterSession):
    """Single pass over the session's recognized orders for both the sales
    totals and the per-category breakdown."""
    orders = (
        Order.objects.committed_sales()
        .filter(register_session=session)
        .prefetch_related("lines__variant__product__categories")
    )

    gross = Decimal("0.00")
    discount = Decimal("0.00")
    order_total = Decimal("0.00")
    items = Decimal("0.000")
    order_count = 0
    buckets: "OrderedDict[object, dict]" = OrderedDict()

    for order in orders:
        order_count += 1
        gross += order.subtotal
        discount += order.discount_total
        order_total += order.total
        for line in order.lines.all():
            items += line.quantity
            category = _primary_category(line.variant.product)
            key = category.id if category is not None else UNCATEGORIZED
            bucket = buckets.get(key)
            if bucket is None:
                bucket = {
                    "name": category.name if category is not None else None,
                    "quantity": Decimal("0.000"),
                    "net": Decimal("0.00"),
                }
                buckets[key] = bucket
            bucket["quantity"] += line.quantity
            bucket["net"] += line.line_total

    void_count = (
        Order.objects.filter(
            register_session=session,
            status=Order.Status.VOID,
        )
        .exclude(sale_type=Order.SaleType.QUOTATION)
        .count()
    )

    categories = [
        {
            "category": bucket["name"],
            "quantity": _qty(bucket["quantity"]),
            "net": _money(bucket["net"]),
        }
        for bucket in sorted(
            buckets.values(),
            key=lambda b: b["net"],
            reverse=True,
        )
    ]

    sales = {
        "gross_sales": _money(gross),
        "discount_total": _money(discount),
        # ``net_sales`` is finalised in the caller once refunds are known.
        "net_sales": _money(order_total),
        "order_count": order_count,
        "void_count": void_count,
        "items_sold": _qty(items),
    }
    return sales, categories


def _refunds(session: RegisterSession):
    adjustments = session.order_adjustments.all()
    refund_total = adjustments.aggregate(total=Sum("amount"))["total"] or Decimal("0.00")
    return_count = adjustments.filter(
        adjustment_type=OrderAdjustment.AdjustmentType.RETURN
    ).count()
    by_method = {
        row["refund_method"]: row["total"] or Decimal("0.00")
        for row in adjustments.values("refund_method").annotate(total=Sum("amount"))
    }
    return (
        {"refund_total_dec": refund_total, "return_count": return_count},
        by_method,
    )


def _payment_methods(session: RegisterSession, refund_by_method: dict):
    """Per-method collected / commission / refund / net, one row per method in
    a stable order. Gross counts positive tenders only (mirrors
    ``cash_sales_total``); refunds group by ``refund_method`` so the per-method
    figures sum to the overall refund total."""
    collected = {
        row["method"]: row
        for row in (
            Payment.objects.filter(register_session=session, amount__gt=0)
            .values("method")
            .annotate(
                gross=Sum("amount"),
                commission=Sum("commission_amount"),
                count=Count("id"),
            )
        )
    }

    rows = []
    totals = {
        "gross": Decimal("0.00"),
        "commission": Decimal("0.00"),
        "refund": Decimal("0.00"),
        "net": Decimal("0.00"),
        "count": 0,
    }
    for method, _label in Payment.Method.choices:
        row = collected.get(method, {})
        gross = row.get("gross") or Decimal("0.00")
        commission = row.get("commission") or Decimal("0.00")
        count = row.get("count") or 0
        refund = refund_by_method.get(method, Decimal("0.00"))
        net = gross - refund
        rows.append(
            {
                "method": method,
                "gross": _money(gross),
                "commission": _money(commission),
                "refund": _money(refund),
                "net": _money(net),
                "count": count,
            }
        )
        totals["gross"] += gross
        totals["commission"] += commission
        totals["refund"] += refund
        totals["net"] += net
        totals["count"] += count

    payment_totals = {
        "gross": _money(totals["gross"]),
        "commission": _money(totals["commission"]),
        "refund": _money(totals["refund"]),
        "net": _money(totals["net"]),
        "count": totals["count"],
    }
    return rows, payment_totals


def _cash_reconciliation(session: RegisterSession) -> dict:
    closing = session.closing_cash
    variance = session.cash_variance
    return {
        "opening_cash": _money(session.opening_cash),
        "cash_sales_total": _money(session.cash_sales_total),
        "pay_in_total": _money(session.pay_in_total),
        "pay_out_total": _money(session.pay_out_total),
        "cash_refund_total": _money(session.cash_refund_total),
        "expected_cash": _money(session.expected_cash),
        "closing_cash": None if closing is None else _money(closing),
        "cash_variance": None if variance is None else _money(variance),
        "has_cash_variance": session.has_cash_variance,
        "denomination_total": _money(session.denomination_total),
        "denominations": [
            {"value": "0.25", "count": session.count_025},
            {"value": "0.50", "count": session.count_050},
            {"value": "0.75", "count": session.count_075},
            {"value": "1.00", "count": session.count_100},
        ],
    }


def _expenses(session: RegisterSession) -> dict:
    aggregate = session.expenses.aggregate(total=Sum("amount"), count=Count("id"))
    return {
        "total": _money(aggregate["total"] or Decimal("0.00")),
        "count": aggregate["count"] or 0,
    }


def _dec(value) -> Decimal:
    return Decimal(str(value))
