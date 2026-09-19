"""الأمانات — goods the shop holds, sells and owes for, without ever owning.

Three things become true the moment a customer hands a watch across the counter,
and the obvious model captures only one of them:

======================================  ====================================
What is true at intake                  Where it belongs
======================================  ====================================
the item is physically here, sellable   custody  — ``StockUnit.status``
it adds nothing to stock value          valuation — ``incoming_rate = 0``
we owe its owner the item, or its money liability — **this module**
======================================  ====================================

The third is not "nothing until it sells". Before the sale it is an obligation
to return *the thing*; after the sale it is an obligation to pay *a number*.
Only the form changes: the obligation runs unbroken from the moment the voucher
is signed, and a shop holding forty consigned watches is carrying an exposure
that has to appear somewhere.

**Derived, never posted.** There is no general ledger here and this does not add
one — the same posture ``treasury/position.py`` takes with the money position
and ``Job.settlement_state`` takes with a repair. A payable computed from the
unit's own sale and its own payout row cannot drift from them, which is the
entire failure mode of a stored balance.

Every money figure below has exactly **one** definition, registered in the
static guard (``apps/core/test_money_definitions.py``) so the fifth surface that
wants one has to import it rather than retype it.
"""

from __future__ import annotations

from decimal import Decimal

from django.db.models import F, Q, Sum

from .models import ConsignmentAgreement, StockUnit

ZERO = Decimal("0.00")


def _money(value) -> Decimal:
    return Decimal(value or 0).quantize(Decimal("0.01"))


# ---------------------------------------------------------------------------
# Terms
# ---------------------------------------------------------------------------


class Terms:
    """The payout terms that actually apply to one article.

    A per-unit value overrides the agreement's; ``None`` inherits. One consignor
    signs one page for eight handbags and then names a different reserve on the
    one that is nearly new, and both of those are ordinary.
    """

    __slots__ = ("mode", "payout_rate", "commission_pct", "reserve_price")

    def __init__(self, *, mode, payout_rate, commission_pct, reserve_price):
        self.mode = mode
        self.payout_rate = payout_rate
        self.commission_pct = commission_pct
        self.reserve_price = reserve_price

    @property
    def is_fixed(self) -> bool:
        return self.mode == ConsignmentAgreement.PayoutMode.FIXED

    def __repr__(self) -> str:  # pragma: no cover - debugging aid
        return (
            f"Terms(mode={self.mode!r}, payout_rate={self.payout_rate!r}, "
            f"commission_pct={self.commission_pct!r}, "
            f"reserve_price={self.reserve_price!r})"
        )


def terms_for(unit) -> Terms:
    agreement = unit.agreement if unit.agreement_id else None
    mode = unit.consignor_payout_mode or (
        agreement.payout_mode if agreement else ConsignmentAgreement.PayoutMode.FIXED
    )
    return Terms(
        mode=mode,
        payout_rate=_first(
            unit.consignor_payout_rate, agreement.payout_rate if agreement else None
        ),
        commission_pct=_first(
            unit.consignor_commission_pct,
            agreement.commission_pct if agreement else None,
        ),
        reserve_price=_first(
            unit.consignor_reserve_price,
            agreement.reserve_price if agreement else None,
        ),
    )


def _first(*values):
    for value in values:
        if value is not None:
            return value
    return None


# ---------------------------------------------------------------------------
# The four figures. One definition each.
# ---------------------------------------------------------------------------


def consignor_payout_due(unit, *, sold_price=None) -> Decimal:
    """What the shop owes this unit's consignor.

    For a unit that has already sold, this is what was **stamped at the sale** —
    ``incoming_rate``, written inside the checkout transaction and posted to the
    ledger in the same breath. It is deliberately not recomputed from the
    agreement's terms: editing a commission rate next month must not silently
    rewrite a debt that was fixed when the watch left the shop.

    For a unit still on the shelf this is a *projection* at the price given (or
    its own asking price), which is what the payables screen shows as "will
    owe" and what the price floor is measured against.
    """
    if not unit.is_consignment:
        return ZERO
    if unit.status == StockUnit.Status.SOLD:
        return _money(unit.incoming_rate)
    terms = terms_for(unit)
    if terms.is_fixed:
        return _money(terms.payout_rate)
    price = sold_price if sold_price is not None else (unit.list_price or ZERO)
    pct = Decimal(terms.commission_pct or 0)
    return _money(Decimal(price) * (Decimal(100) - pct) / Decimal(100))


def consignor_payable(*, as_of=None, consignor=None, queryset=None) -> Decimal:
    """Σ payout over units sold and not yet paid for — the shop's liability.

    Counts a consignment sold on آجل exactly like one sold for cash: the shop
    owes the consignor whether or not its own customer has paid, and a payable
    that quietly waited on somebody else's invoice would be the wrong number.
    """
    rows = queryset if queryset is not None else payable_units(
        as_of=as_of, consignor=consignor
    )
    total = rows.aggregate(total=Sum("incoming_rate"))["total"]
    return _money(total)


def payable_units(*, as_of=None, consignor=None):
    """Sold consignments nobody has been paid for. The payables screen's query.

    ``as_of`` reads it **as at that moment**, which means both halves have to
    move: sold by then, and not yet paid by then. Filtering the sale by the date
    and the payment by "is it paid now" answers a question nobody asked — a
    watch sold in August and settled in September would be missing from August's
    figure, and the money position for a past day would show that day's cash
    beside today's obligations.
    """
    rows = StockUnit.objects.filter(is_consignment=True, status=StockUnit.Status.SOLD)
    if consignor is not None:
        rows = rows.filter(consignor=getattr(consignor, "pk", consignor))
    if as_of is None:
        return rows.filter(consignor_paid_at__isnull=True)
    return rows.filter(sold_at__lte=as_of).filter(
        Q(consignor_paid_at__isnull=True) | Q(consignor_paid_at__gt=as_of)
    )


def receivable_units(*, as_of=None, consignor=None):
    """Paid-for consignments that are back on the shelf.

    The mirror of :func:`payable_units`, and it exists for one situation: a
    customer returns a watch three days after its owner collected ten thousand
    dinars, and the shop chooses to **reopen** the consignment rather than buy
    the article in. The watch is the consignor's again and the money has gone,
    so the debt has simply changed direction.
    """
    rows = StockUnit.objects.filter(
        is_consignment=True,
        consignor_payout__isnull=False,
        status__in=StockUnit.ON_HAND_STATUSES,
    )
    if consignor is not None:
        rows = rows.filter(consignor=getattr(consignor, "pk", consignor))
    if as_of is not None:
        rows = rows.filter(consignor_paid_at__lte=as_of)
    return rows


def consignor_receivable(*, as_of=None, consignor=None, queryset=None) -> Decimal:
    """Σ what the shop has paid out on goods it no longer has sold.

    Read off ``incoming_rate``, which is what that article's payout actually
    was, rather than recomputed from the agreement's terms: under a commission
    the payout was a share of a price that is now history, and re-deriving it
    from today's percentage would invent a debt neither party agreed to.

    Not netted against :func:`consignor_payable` anywhere. A shop that owes one
    consignor 10,000 and is owed 3,000 by another owes 10,000 — a single figure
    hiding two people is the kind of arithmetic that empties a till.
    """
    rows = queryset if queryset is not None else receivable_units(
        as_of=as_of, consignor=consignor
    )
    total = rows.aggregate(total=Sum("incoming_rate"))["total"]
    return _money(total)


def consignment_stock_value(warehouse=None) -> Decimal:
    """≡ 0, by construction.

    Consigned units are excluded from stock value by ``StockUnit.stock_value``
    itself, so this is not an arithmetic but a statement — and it is here so
    that a screen wanting to print "قيمة البضاعة: 0" beside the other three
    figures reads it from the same place they come from, rather than typing a
    zero that nothing would ever contradict.
    """
    return ZERO


def shop_consignment_commission(*, start=None, end=None) -> Decimal:
    """What the shop earned on consignment sales in a window.

    ``sold_price − payout``. Note what this is *not*: a new definition of gross
    profit. Because the payout is stamped as the unit's cost at the moment of
    sale, gross profit on a consignment line already equals the shop's
    commission and every existing margin report is already right. This exists
    for the consignment screen's own headline, which wants the figure without
    running a margin report.
    """
    rows = StockUnit.objects.filter(
        is_consignment=True, status=StockUnit.Status.SOLD, sold_price__isnull=False
    )
    if start is not None:
        rows = rows.filter(sold_at__gte=start)
    if end is not None:
        rows = rows.filter(sold_at__lte=end)
    # Summed by the database, not by walking the rows: the consignment position
    # is a screen, this is its headline, and an unwindowed read of it is every
    # consignment the shop has ever sold.
    total = rows.aggregate(
        total=Sum(F("sold_price") - F("incoming_rate"))
    )["total"]
    return _money(total)


def consignor_claims_open(as_of=None) -> Decimal:
    """Σ assessed value over unresolved custody incidents.

    ``ConsignmentIncident`` is the next phase's work (§6.2.2). The figure is
    defined here now, and returns zero, so the treasury overlay and the
    consignment screen are shaped for it from the first release rather than
    growing a field later — and so that when incidents land there is exactly one
    place that answers this question.
    """
    return ZERO


def custody_exposure(as_of=None) -> dict:
    """Goods held for other people: how many, and worth how much to them.

    Declared value, not cost — the shop's cost is zero and always will be, and
    the number that matters for an insurance conversation or a claim is what the
    owner and the shop agreed the thing was worth.
    """
    rows = StockUnit.objects.filter(
        is_consignment=True, status__in=StockUnit.ON_HAND_STATUSES
    )
    if as_of is not None:
        rows = rows.filter(acquired_at__lte=as_of)
    totals = rows.aggregate(declared=Sum("declared_value"))
    return {
        "unit_count": rows.count(),
        "declared_value": _money(totals["declared"]),
    }


def consignment_position(*, start=None, end=None, as_of=None) -> dict:
    """The four figures of §5.8, plus custody and the debt that runs the other
    way, in one read."""
    return {
        "stock_value": consignment_stock_value(),
        "consignor_payable": consignor_payable(as_of=as_of),
        "consignor_receivable": consignor_receivable(as_of=as_of),
        "consignor_claims_open": consignor_claims_open(as_of),
        "shop_commission": shop_consignment_commission(start=start, end=end),
        "custody": custody_exposure(as_of),
    }


# ---------------------------------------------------------------------------
# The price floor
# ---------------------------------------------------------------------------


def payout_floor(unit) -> Decimal:
    """The lowest price this consigned article may be sold at.

    ``prevent_selling_at_loss`` compares an asking price against
    ``StockUnit.stock_value``, which for a consigned unit is **zero until the
    instant of sale** — so the guard that exists to stop a shop losing money is,
    on precisely the goods where losing money is easiest, switched off. A
    fixed-payout bag with a 1,200 payout sold at 900 collects 900 and owes
    1,200.

    So: under a **fixed** payout the floor is ``max(reserve_price, payout_rate)``
    and it is **not** overridable — selling below the payout loses the shop its
    own money, not merely its commission. Under **commission** the payout scales
    with the price, so no arithmetic floor is needed and the reserve protects the
    consignor rather than the shop; it stays advisory, with a manager override.
    """
    if not unit.is_consignment:
        return ZERO
    terms = terms_for(unit)
    if terms.is_fixed:
        return max(_money(terms.reserve_price), _money(terms.payout_rate))
    return ZERO


def advisory_floor(unit) -> Decimal:
    """The reserve a manager may override — commission mode only."""
    if not unit.is_consignment:
        return ZERO
    terms = terms_for(unit)
    if terms.is_fixed:
        return ZERO
    return _money(terms.reserve_price)


# ---------------------------------------------------------------------------
# Intake
# ---------------------------------------------------------------------------


def clause_for(policy, *, settings=None) -> str:
    """The shop's own sentence for this liability policy, as it will be printed.

    Copied onto the agreement at submit and never re-read: a shop that rewords
    its voucher next year has not reworded the agreements it already signed, and
    that copy is the difference between a contract and a template.
    """
    from apps.core.models import ShopSettings

    settings = settings or ShopSettings.load()
    return {
        ConsignmentAgreement.Liability.OWNER_RISK: settings.consignment_clause_owner_risk,
        ConsignmentAgreement.Liability.SHOP_LIABLE_EXCEPT_FM: (
            settings.consignment_clause_shop_liable_except_fm
        ),
        ConsignmentAgreement.Liability.SHOP_LIABLE: (
            settings.consignment_clause_shop_liable
        ),
    }.get(policy, "")


def open_agreements_for(consignor):
    return ConsignmentAgreement.objects.submitted().filter(
        consignor=getattr(consignor, "pk", consignor)
    )


# ---------------------------------------------------------------------------
# Sale
# ---------------------------------------------------------------------------


def stamp_payout(unit, *, sold_price) -> Decimal:
    """Fix this unit's cost at the payout its terms produce, at the sale.

    A consignment sale is a purchase and a sale in one transaction, and this is
    the purchase half: at the instant we sold it, we acquired it for the payout.
    From here the ordinary machinery does the rest — COGS is the payout, gross
    profit is the commission, and every margin report is already right.
    """
    payout = consignor_payout_due(unit, sold_price=sold_price)
    unit.incoming_rate = payout
    return payout


def notify_consignor_of_sale(unit, order, *, settings=None):
    """Tell the owner their goods sold, now, in one SMS.

    Idempotent by ``dedup_key``: a retried checkout, a resend from the unit
    screen and a reposted sale all resolve to the same queued row. Never raises
    into a checkout — a gateway that is down is a message that waits, not a sale
    that fails.
    """
    from apps.core.models import ShopSettings
    from apps.messaging import services as messaging
    from apps.messaging.models import MessagingGateway, OutboundMessage

    settings = settings or ShopSettings.load()
    if not settings.consignment_auto_sms_on_sale:
        return None
    phone = getattr(unit.consignor, "phone", "") if unit.consignor_id else ""
    if not phone:
        return None

    body = render_sale_sms(unit, order, settings=settings)
    try:
        return messaging.enqueue_message(
            to=phone,
            body=body,
            consent_class=OutboundMessage.ConsentClass.TRANSACTIONAL,
            channel=MessagingGateway.Channel.SMS,
            dedup_key=f"consignment_sold_{unit.pk}_{order.pk}",
            source_type="consignment_sale",
            source_id=order.pk,
        )
    except messaging.NoGatewayConfigured:
        # A shop with no SMS gateway consigns goods perfectly well; it just
        # phones people. Refusing the sale over it would be absurd.
        return None


def render_sale_sms(unit, order, *, settings=None) -> str:
    from apps.core.models import CONSIGNMENT_SALE_SMS_TEMPLATE, ShopSettings

    settings = settings or ShopSettings.load()
    template = (
        settings.consignment_sale_sms_template or CONSIGNMENT_SALE_SMS_TEMPLATE
    )
    values = {
        "consignor_name": getattr(unit.consignor, "full_name", "") or "",
        "product_name": unit.variant.full_name if unit.variant_id else "",
        "code": unit.code,
        "invoice_number": getattr(order, "receipt_number", "") or "",
        "payout_amount": f"{consignor_payout_due(unit):.2f}",
    }
    try:
        return template.format(**values)
    except (KeyError, IndexError, ValueError):
        # A shop that typed {total} into its own template gets its template
        # back rather than a 500 in the middle of a checkout.
        return template


def render_payout_sms(unit, payout, *, settings=None) -> str:
    return (
        f"تم تسليمكم مبلغ {payout.amount:.2f} د.ل سند رقم "
        f"{payout.number or payout.pk} مقابل بيع "
        f"{unit.variant.full_name if unit.variant_id else ''}. "
        "سعدنا بالتعامل معكم."
    )


__all__ = [
    "Terms",
    "advisory_floor",
    "clause_for",
    "consignment_position",
    "consignment_stock_value",
    "consignor_claims_open",
    "consignor_payable",
    "consignor_payout_due",
    "consignor_receivable",
    "custody_exposure",
    "notify_consignor_of_sale",
    "payable_units",
    "payout_floor",
    "receivable_units",
    "render_payout_sms",
    "render_sale_sms",
    "shop_consignment_commission",
    "stamp_payout",
    "terms_for",
]
