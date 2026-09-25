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
* **Provider services** (top-ups and cards resold for HD Box, LNET, Qareeb)
  come from the orders the session issued, voids included, because a sale
  refunded after the provider performed it is exactly the money a shift review
  has to be able to see. ``apps.integrations.session_breakdown`` owns what
  those lines mean.
"""

from collections import OrderedDict
from decimal import Decimal

from django.conf import settings
from django.core.cache import cache
from django.db.models import Count, Sum
from django.db.models.fields.json import KeyTextTransform

from apps.catalog.models import Product
from apps.expenses.models import Expense
from apps.integrations.session_breakdown import build_integration_breakdown
from apps.payments.models import Payment

from .models import (
    Order,
    OrderAdjustment,
    OrderLine,
    RegisterSession,
    prime_register_session_cash_totals,
)

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


def cached_register_session_summary(session: RegisterSession) -> dict:
    """``build_register_session_summary`` behind a short Redis cache.

    A shift review opens the summary, prints it thermally, and often exports
    the PDF within seconds — one compute serves all three. The TTL is short
    because a closed session is *not* strictly immutable (a manager can void
    one of its invoices from history); 30s staleness is invisible at the desk.
    Keyed on the session row's updated_at so reopening/closing recomputes
    immediately. Fail-open on Redis trouble.

    An OPEN drawer is never cached. That burst-of-three is a *closing* ritual;
    a session that is still selling changes with every sale, and nothing in the
    key moves when one lands (a sale does not touch the session row), so a
    cached payload would hold totals that omit the last half-minute of takings
    — including right after the reviewer pressed refresh to see them.
    """
    ttl = int(getattr(settings, "POINTY_REGISTER_SUMMARY_CACHE_TTL", 0))
    if ttl <= 0 or session.status == RegisterSession.Status.OPEN:
        return build_register_session_summary(session)
    stamp = session.updated_at.timestamp() if session.updated_at else 0
    key = f"pointy:sales:register-summary:{session.pk}:{session.status}:{stamp}"
    try:
        cached = cache.get(key)
    except Exception:  # noqa: BLE001 — redis down: compute live
        cached = None
    if cached is not None:
        return cached
    summary = build_register_session_summary(session)
    try:
        cache.set(key, summary, ttl)
    except Exception:  # noqa: BLE001
        pass
    return summary


def build_register_session_summary(session: RegisterSession) -> dict:
    """Aggregate everything a manager needs to review/print a shift."""
    # The Z-report reads every drawer total plus all three composites, so batch
    # the four aggregates once up front: 3 queries instead of 16.
    prime_register_session_cash_totals([session])
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
        "card_receipts": _card_receipt_verification(session),
        "categories": categories,
        "cash": _cash_reconciliation(session),
        "expenses": _expenses(session),
        "drawer_purchases": _drawer_purchases(session),
        "integrations": build_integration_breakdown(
            Order.objects.transactional().filter(register_session=session)
        ),
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
    """Sales totals + per-category breakdown for the session's recognized
    orders.

    Order-level money lives in real columns, so those sums happen in SQL. The
    per-line net deliberately stays in Python over a lean 4-column tuple scan:
    ``line_total`` quantizes per line with Decimal's half-even rounding, which
    SQL ``ROUND`` (half-up) would diverge from on fractional quantities — but
    nothing heavier than the tuples is materialized (the old version loaded
    every order with a lines→variant→product→categories prefetch)."""
    orders = Order.objects.committed_sales().filter(register_session=session)
    totals = orders.aggregate(
        gross=Sum("subtotal"),
        discount=Sum("discount_total"),
        total=Sum("total"),
        count=Count("id"),
    )

    items = Decimal("0.000")
    product_rollups: dict[object, dict] = {}
    lines = OrderLine.objects.filter(order__in=orders).values_list(
        "quantity", "unit_price", "discount_total", "variant__product_id"
    )
    for quantity, unit_price, discount_total, product_id in lines:
        items += quantity
        line_net = (unit_price * quantity).quantize(MONEY) - (
            discount_total or Decimal("0.00")
        )
        rollup = product_rollups.get(product_id)
        if rollup is None:
            rollup = {"quantity": Decimal("0.000"), "net": Decimal("0.00")}
            product_rollups[product_id] = rollup
        rollup["quantity"] += quantity
        rollup["net"] += line_net.quantize(MONEY)

    # One query resolves the primary category of every distinct product sold
    # this shift — bounded by the assortment, not the line count.
    products_by_id = {
        product.id: product
        for product in Product.objects.filter(
            id__in=[pid for pid in product_rollups if pid is not None]
        ).prefetch_related("categories")
    }
    buckets: "OrderedDict[object, dict]" = OrderedDict()
    for product_id, rollup in product_rollups.items():
        product = products_by_id.get(product_id)
        category = _primary_category(product) if product is not None else None
        key = category.id if category is not None else UNCATEGORIZED
        bucket = buckets.get(key)
        if bucket is None:
            bucket = {
                "name": category.name if category is not None else None,
                "quantity": Decimal("0.000"),
                "net": Decimal("0.00"),
            }
            buckets[key] = bucket
        bucket["quantity"] += rollup["quantity"]
        bucket["net"] += rollup["net"]

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
        "gross_sales": _money(totals["gross"]),
        "discount_total": _money(totals["discount"]),
        # ``net_sales`` is finalised in the caller once refunds are known.
        "net_sales": _money(totals["total"]),
        "order_count": totals["count"] or 0,
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


def _card_receipt_verification(session: RegisterSession) -> dict:
    """How much of this shift's card money is backed by a checked receipt.

    A shift's card total answers "how much went through the terminal"; it does
    not answer "how much of that can we prove". Those separate the moment a
    provider's receipt has to be proved AFTER the sale, so they are reported
    separately: a manager closing a drawer wants "2,000 of 4,000 verified", not
    a single number that quietly mixes the two.

    Buckets, most to least settled:

    ``verified``     a receipt that passed its checks.
    ``pending``      scanned, still waiting on its issuer.
    ``flagged``      the issuer disowned it, or it proves a different amount.
    ``unavailable``  the issuer could not be reached. Says nothing either way.
    ``no_receipt``   a card payment taken with no receipt scanned at all.
    """
    from apps.payments.card_receipts.base import (
        MISMATCH,
        PENDING,
        REJECTED,
        SETTLED,
        UNAVAILABLE,
    )

    card_payments = Payment.objects.filter(
        register_session=session,
        method=Payment.Method.CARD,
        amount__gt=0,
    )
    gross = card_payments.aggregate(total=Sum("amount"))["total"] or Decimal("0.00")
    with_receipt = card_payments.exclude(card_receipt_data={}).aggregate(
        total=Sum("amount"), count=Count("id")
    )
    receipted_total = with_receipt["total"] or Decimal("0.00")

    buckets = {
        state: Decimal("0.00")
        for state in (SETTLED, PENDING, MISMATCH, REJECTED, UNAVAILABLE)
    }
    counts = dict.fromkeys(buckets, 0)
    tracked = Decimal("0.00")
    for row in (
        card_payments.exclude(card_receipt_data={})
        # Group on the extracted key, not the JSON document: every receipt is a
        # distinct blob, so grouping by the document would return one row per
        # payment and drag every payload back with it.
        .annotate(state=KeyTextTransform("verification_state", "card_receipt_data"))
        .values("state")
        .annotate(total=Sum("amount"), count=Count("id"))
    ):
        state = row["state"]
        amount = row["total"] or Decimal("0.00")
        if state not in buckets:
            # A receipt stored before verification states existed. It was
            # checked at the counter against its own decoded payload, which is
            # exactly what ``settled`` means for a self-contained provider.
            state = SETTLED
        buckets[state] += amount
        counts[state] += row["count"] or 0
        tracked += amount

    # Anything with a receipt that somehow escaped the grouping still belongs
    # somewhere; leaving it out would make the buckets not sum to the total.
    buckets[SETTLED] += receipted_total - tracked

    return {
        "gross": _money(gross),
        "verified": _money(buckets[SETTLED]),
        "pending": _money(buckets[PENDING]),
        "flagged": _money(buckets[MISMATCH] + buckets[REJECTED]),
        "unavailable": _money(buckets[UNAVAILABLE]),
        "no_receipt": _money(gross - receipted_total),
        "counts": {
            "verified": counts[SETTLED],
            "pending": counts[PENDING],
            "flagged": counts[MISMATCH] + counts[REJECTED],
            "unavailable": counts[UNAVAILABLE],
        },
    }


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
    # A drawer's own tenders. A salary deduction never passes through a till —
    # payroll settles it with no session at all — so it has no row here.
    for method in Payment.TILL_METHODS:
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
    aggregate = session.expenses.live().aggregate(
        total=Sum("amount"), count=Count("id")
    )
    return {
        "total": _money(aggregate["total"] or Decimal("0.00")),
        "count": aggregate["count"] or 0,
    }


def _drawer_purchases(session: RegisterSession) -> dict:
    """Supplier purchases paid in cash from this drawer (POS cash purchases).
    Their pay-outs are already inside ``pay_out_total``; this block attributes
    them so the shift review can tell stock buys from generic pay-outs."""
    aggregate = session.supplier_payments.live().aggregate(
        total=Sum("amount"),
        count=Count("id"),
    )
    return {
        "total": _money(aggregate["total"] or Decimal("0.00")),
        "count": aggregate["count"] or 0,
    }


def _dec(value) -> Decimal:
    return Decimal(str(value))
