"""Recording a payment made on the provider's own website as the sale it was.

The field case, 2026-09-25: a checkout bug refused every LNET top-up at the
till for most of an afternoon, so the cashiers did them on LNET's website and
took the customers' cash. Every one of those top-ups happened — the customer's
line was credited, the agency float paid for it — and Pointy knows about none
of them. The drawer holds cash no sale explains, and the float is lower than
Pointy's arithmetic says.

A manager puts that right from LNET's own payments report (mirrored by
:mod:`apps.integrations.payment_report`): pick the payment, pick the register
session whose drawer took the cash — still open, or already counted and
closed, which is where an afternoon of website top-ups usually ends up — say
how the customer paid, and this module issues the invoice the till would have
issued. What it promises:

**Nothing is sent to the provider.** The top-up already happened. The sale is
recorded around it and its fulfillment is born ``confirmed`` — never
``pending``, not even inside its own transaction — so the at-most-once guard
in :mod:`apps.integrations.recharge` has nothing it could ever charge.

**One payment, one sale.** The report row is locked for the whole write, and
the provider's reference is checked against every fulfillment that already
claims it: the till's own top-ups carry theirs, and so does anything recorded
here before. Reconciliation takes the same row lock before it confirms
anything (``reconciliation._confirm``), so the nightly sweep and a manager
cannot claim one payment twice between them.

**Only what the provider prints right now.** The mirror is a copy, so the
report is read again, live, down past the payment before anything is written.
A payment that was cancelled since, or that the report no longer shows, is
refused.

**It is the till's sale.** The line is built by the till's own line serializer
and issued by ``sales.services.checkout_order`` — same price rule, same cost,
same receipt number series, same payment rules for cash, card, transfer and
آجل. The only differences are the ones the situation forces: no discount rule
runs (the customer paid the website's figure, not a promotion's), and the
payment lands in the drawer the manager names rather than the manager's own.

**The float is drawn once, dated when the provider drew it.** A confirmed
fulfillment's cost is what ``float_ledger.drawn`` subtracts from the LNET
account in the treasury, dated by ``confirmed_at`` — set to the payment's own
time.

**A sale waiting for its top-up is not double-counted.** If Pointy already
took money for a top-up of this line that the provider has not confirmed, the
website payment may well BE that top-up. It is refused as a new sale unless
the manager says otherwise, and can instead be linked to the waiting sale —
which is what reconciliation would do, and what stops the till from ever
charging that sale a second time.
"""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass, field
from datetime import timedelta
from decimal import Decimal, InvalidOperation

from django.db import transaction
from django.utils import timezone

from apps.analytics.models import AnalyticsEvent
from apps.analytics.services import record_domain_event
from apps.core.state_version import bump

from . import payment_report
from .models import IntegrationFulfillment, IntegrationSubscriber, ProviderPayment
from .providers import provider_for
from .providers.base import PAYMENT_VERIFIED
from .provisioning import service_variant_for
from .reconciliation import CLOCK_SLACK

# --- where a report payment stands in Pointy (stable codes; Arabic lives in
# the Flutter layer — add codes, never rename them) ---------------------------
#: A Pointy sale already accounts for it: the till's own top-up, or one
#: recorded here before.
STATE_RECORDED = "recorded"
#: It was recorded here, and that invoice has since been voided — the way a
#: manager corrects a wrong drawer or payment method. It may be recorded again.
STATE_RELEASED = "released"
#: A Pointy sale that took the customer's money and is still waiting for its
#: top-up could be this very payment.
STATE_PENDING_SALE = "pending_sale"
#: A real, finished payment with no sale behind it: cash nobody accounted for.
STATE_UNRECORDED = "unrecorded"
#: The provider does not call it done — pending, cancelled, or a cancellation
#: in flight.
STATE_NOT_VERIFIED = "not_verified"
#: Made by another login under the agency, which may not be this till's float.
STATE_OTHER_OPERATOR = "other_operator"
#: Not a plain top-up: extra data bought with it, or no amount, date or line.
STATE_UNSUPPORTED = "unsupported"

RECORDABLE_STATES = frozenset({STATE_UNRECORDED, STATE_RELEASED, STATE_PENDING_SALE})

#: How much further back than the payment a live re-read goes, so the page it
#: sits on is certainly read and not merely the one before it.
VERIFY_MARGIN = timedelta(minutes=30)
#: Pages a re-read may spend. Ten rows a page — a busy week, several quiet ones.
VERIFY_PAGES = 60
#: How long after a shift closed a payment may still be stamped and have been
#: in its drawer: the portal's clock and the till's disagree by a minute or
#: so, and a cashier may press "close" moments after the last top-up.
SHIFT_CLOSE_SLACK = timedelta(minutes=15)

#: Fulfillment states that mean "Pointy took the money and the provider has
#: not confirmed the top-up". ``submitted`` is included: a charge that was sent
#: and never answered may have become exactly this payment.
_WAITING = (
    IntegrationFulfillment.Status.PENDING,
    IntegrationFulfillment.Status.SUBMITTED,
    IntegrationFulfillment.Status.FAILED,
)

MONEY = Decimal("0.01")


class PortalSaleError(Exception):
    """A refusal with a stable ``code`` the client branches on."""

    def __init__(self, code: str, detail: str = "", *, status_code=400, extra=None):
        super().__init__(detail or code)
        self.code = code
        self.detail = detail
        self.status_code = status_code
        self.extra = extra or {}

    def payload(self) -> dict:
        return {"code": self.code, "detail": self.detail or self.code, **self.extra}


@dataclass
class PaymentStanding:
    """One report payment, and where it stands in Pointy."""

    payment: ProviderPayment
    state: str
    #: The fulfillment that accounts for it, when ``state`` is ``recorded``.
    claim: IntegrationFulfillment | None = None
    #: Sales waiting for a top-up that this payment could be.
    candidates: list = field(default_factory=list)
    #: Recorded-then-voided claims a new recording would retire.
    released: list = field(default_factory=list)

    @property
    def is_recordable(self) -> bool:
        return self.state in RECORDABLE_STATES


# --- reading ----------------------------------------------------------------
def describe(account, payments) -> list[PaymentStanding]:
    """Where each payment stands. Two queries, however many payments."""
    payments = list(payments)
    references = [payment.reference for payment in payments]
    claims = defaultdict(list)
    for row in IntegrationFulfillment.objects.filter(
        account=account, provider_reference__in=references
    ).select_related(
        "order_line__order__register_session__owner",
    ):
        claims[row.provider_reference].append(row)
    waiting = waiting_sales(
        account, {payment.subscriber_key for payment in payments if payment.subscriber_key}
    )
    return [
        standing_of(account, payment, claims.get(payment.reference, ()), waiting)
        for payment in payments
    ]


def waiting_sales(account, subscriber_keys) -> list:
    """Sales that took the customer's money and still wait for their top-up.

    Only lines still owed one: a voided sale or a returned line gave the
    customer their money back, so a website payment afterwards is a new sale
    and not that one.
    """
    if not subscriber_keys:
        return []
    rows = (
        IntegrationFulfillment.objects.filter(
            account=account, status__in=_WAITING, provider_reference=""
        )
        .select_related("account", "order_line__order")
        .prefetch_related("order_line__adjustment_lines")
        .order_by("created_at")
    )
    return [
        row
        for row in rows
        if payment_report.subscriber_key(row.subscriber_ref) in subscriber_keys
        and _still_owed(row)
    ]


def _still_owed(row) -> bool:
    from apps.sales.models import Order

    line = row.order_line
    return (
        row.status in _WAITING
        and not row.provider_reference
        and line.order.status != Order.Status.VOID
        and not line.adjustment_lines.all()
    )


def standing_of(account, payment, claims, waiting) -> PaymentStanding:
    """The state of one payment, given its claims and the sales still waiting."""
    live = [
        row
        for row in claims
        if row.status != IntegrationFulfillment.Status.CANCELLED
    ]
    holding = [row for row in live if not _is_released(row)]
    if holding:
        return PaymentStanding(payment, STATE_RECORDED, claim=holding[0])
    released = [row for row in live if _is_released(row)]

    problem = recording_problem(account, payment)
    if problem:
        return PaymentStanding(payment, problem, released=released)

    candidates = [row for row in waiting if _could_be(row, payment)]
    if candidates:
        return PaymentStanding(
            payment, STATE_PENDING_SALE, candidates=candidates, released=released
        )
    return PaymentStanding(
        payment,
        STATE_RELEASED if released else STATE_UNRECORDED,
        released=released,
    )


def recording_problem(account, payment) -> str:
    """Why this payment cannot be recorded as a sale at all, or ``""``."""
    if payment.status != PAYMENT_VERIFIED:
        return STATE_NOT_VERIFIED
    mine = (account.username or "").strip().casefold()
    if mine and (payment.operator_name or "").strip().casefold() != mine:
        # Reconciliation reads the same column the same way (``is_ours``): a
        # staff login under the agency may not be spending this float.
        return STATE_OTHER_OPERATOR
    if (
        payment.amount is None
        or payment.amount <= 0
        or payment.paid_at is None
        or not payment.subscriber_ref
        or _has_extra(payment.extra)
    ):
        return STATE_UNSUPPORTED
    return ""


def _has_extra(value) -> bool:
    text = (value or "").strip()
    if not text:
        return False
    try:
        return Decimal(text) != 0
    except InvalidOperation:
        return True


def _is_released(row) -> bool:
    from apps.sales.models import Order

    return row.performed_outside and row.order_line.order.status == Order.Status.VOID


def _could_be(row, payment) -> bool:
    """Whether a waiting sale could be this payment — generously.

    Reconciliation's own rule (same line, same cost, not before the sale less
    clock slack), widened to the face value too: a commission changed between
    the sale and the payment must not let a double count through. Too
    generous only ever costs the manager one extra confirmation.
    """
    if payment_report.subscriber_key(row.subscriber_ref) != payment.subscriber_key:
        return False
    if payment.paid_at is None or payment.paid_at < row.created_at - CLOCK_SLACK:
        return False
    same_cost = payment.cost is not None and Decimal(row.cost) == payment.cost
    quote = provider_for(row.account).quote(row.option_code)
    same_face = (
        quote is not None
        and quote.face_value is not None
        and payment.amount is not None
        and quote.face_value == payment.amount
    )
    return same_cost or same_face


def price_of(account, payment, *, prices=None) -> Decimal | None:
    """What the invoice for this payment will charge — the till's own price."""
    option = provider_for(account).option_for_payment(payment.amount)
    if option is None:
        return None
    return account.selling_price(
        option.cost, option.code, prices=prices, floor=option.face_value
    )


# --- writing ----------------------------------------------------------------
def record_payment(
    *,
    account,
    reference: str,
    register_session_id: int,
    sale_type: str,
    method: str = "",
    amount_paid=None,
    customer=None,
    card_receipt_url: str = "",
    money_account=None,
    allow_pending_sale: bool = False,
    expected_total=None,
    request,
):
    """Issue the invoice for one report payment into a register session.

    Open or closed: a drawer that was counted with this payment's cash in it
    shows an overage that only recording the sale into it can explain (see
    ``_refuse_wrong_session`` for the one thing that is refused).

    ``sale_type`` is ``standard`` (paid in full now, by ``method``) or
    ``credit`` — آجل, with ``amount_paid`` down by ``method`` and the rest
    owed. ``expected_total`` is the figure the manager was shown; a total that
    has moved since is refused rather than recorded.
    """
    from apps.sales.models import Order, RegisterSession
    from apps.sales.services import checkout_order

    _refuse_bad_terms(sale_type=sale_type, customer=customer)
    payment = _payment(account, reference)
    _reread(account, payment)

    with transaction.atomic():
        payment = ProviderPayment.objects.select_for_update().get(pk=payment.pk)
        session = (
            RegisterSession.objects.select_for_update()
            .filter(pk=register_session_id)
            .first()
        )
        if session is None:
            raise PortalSaleError("register_session_not_found", status_code=404)
        was_closed = session.status != RegisterSession.Status.OPEN
        _refuse_wrong_session(session, payment, user=getattr(request, "user", None))

        standing = _locked_standing(account, payment)
        _refuse_unless_recordable(standing, allow_pending_sale=allow_pending_sale)

        lines = _sale_lines(account, payment, request=request)
        total = _total_of(lines)
        if expected_total is not None and Decimal(str(expected_total)) != total:
            raise PortalSaleError(
                "price_changed", status_code=409, extra={"total": str(total)}
            )
        order = checkout_order(
            register_session=session,
            lines_data=lines,
            payments_data=_tenders(
                sale_type=sale_type,
                method=method,
                total=total,
                amount_paid=amount_paid,
                card_receipt_url=card_receipt_url,
                money_account=money_account,
            ),
            customer=customer,
            discount_result=_no_discounts(lines, customer),
            extra_discount_amount=Decimal("0.00"),
            sale_type=sale_type,
            request=request,
            # The drawer is the cashier's, the hand on the keyboard the
            # manager's: an account collection makes the same crossing.
            payment_context={"allow_cross_owner": True},
        )
        retired = _retire(standing.released)
        record_domain_event(
            name="integrations.portal_payment.recorded",
            event_type=AnalyticsEvent.EventType.AUDIT,
            user=getattr(request, "user", None),
            entity_type="sale_order",
            entity_id=order.pk,
            attributes={
                "provider": account.provider,
                "reference": payment.reference,
                "paid_at": payment.paid_at.isoformat() if payment.paid_at else "",
                "register_session_id": session.pk,
                # Recorded into a shift already counted: its expected cash,
                # its variance and its Z-Report figures all move with this.
                "register_session_closed": was_closed,
                "receipt_number": order.receipt_number,
                "sale_type": order.sale_type,
                "payment_method": method or "",
                "over_pending_sale": standing.state == STATE_PENDING_SALE,
                "pending_order_ids": [row.order_line.order_id for row in standing.candidates],
                "retired_fulfillment_ids": retired,
            },
            metrics={
                "amount": float(payment.amount or 0),
                "cost": float(payment.cost or 0),
                "total": float(order.total),
            },
        )
    bump("integrations")
    if was_closed:
        # A counted drawer's variance just changed; let the integrity sweep
        # see it now rather than on its next beat — the same kick closing a
        # register gives it.
        from apps.fraud.services import schedule_targeted_sweep

        schedule_targeted_sweep()
    return Order.objects.get(pk=order.pk)


def link_payment(*, account, reference: str, fulfillment_id: int, request):
    """Settle a sale that waits for its top-up with the website payment that was it.

    What reconciliation would do on finding the payment, done when a manager
    can see that it is the same one. The sale keeps its own lines, price and
    payments — the customer paid once, at the till — and only its top-up is
    marked performed, by this payment. From then on nothing can charge it.
    """
    payment = _payment(account, reference)
    _reread(account, payment)

    with transaction.atomic():
        payment = ProviderPayment.objects.select_for_update().get(pk=payment.pk)
        row = (
            IntegrationFulfillment.objects.select_for_update()
            .filter(pk=fulfillment_id, account=account)
            .select_related("order_line__order")
            .first()
        )
        if row is None:
            raise PortalSaleError("sale_not_found", status_code=404)
        standing = _locked_standing(account, payment)
        if standing.state == STATE_RECORDED:
            raise PortalSaleError(
                "already_recorded",
                status_code=409,
                extra={"order_id": standing.claim.order_line.order_id},
            )
        if standing.state != STATE_PENDING_SALE or row.pk not in {
            candidate.pk for candidate in standing.candidates
        }:
            raise PortalSaleError("not_this_sale", status_code=409)

        was = row.status
        row.status = IntegrationFulfillment.Status.CONFIRMED
        row.provider_reference = payment.reference[:64]
        row.confirmed_at = payment.paid_at
        row.provider_receipt = _receipt(payment, package_name=row.package_name)
        # A charge that was sent and never answered may have been Pointy's
        # own attempt landing after all; only a sale Pointy never sent is
        # certainly the website's work.
        row.performed_outside = was != IntegrationFulfillment.Status.SUBMITTED
        row.last_error_code = ""
        row.last_error = ""
        row.save(
            update_fields=[
                "status",
                "provider_reference",
                "confirmed_at",
                "provider_receipt",
                "performed_outside",
                "last_error_code",
                "last_error",
                "updated_at",
            ]
        )
        retired = _retire(standing.released)
        record_domain_event(
            name="integrations.portal_payment.linked",
            event_type=AnalyticsEvent.EventType.AUDIT,
            user=getattr(request, "user", None),
            entity_type="sale_order",
            entity_id=row.order_line.order_id,
            attributes={
                "provider": account.provider,
                "reference": payment.reference,
                "fulfillment_id": row.pk,
                "previous_status": was,
                "retired_fulfillment_ids": retired,
            },
            metrics={"cost": float(row.cost or 0)},
        )
    bump("integrations")
    return row


def _payment(account, reference: str) -> ProviderPayment:
    if not payment_report.supports_payment_report(account):
        raise PortalSaleError("unsupported_provider", status_code=404)
    payment = ProviderPayment.objects.filter(
        account=account, reference=(reference or "").strip()
    ).first()
    if payment is None:
        raise PortalSaleError("payment_not_found", status_code=404)
    return payment


def _reread(account, payment) -> None:
    """Read the report again, live, down past this payment. Raise if it is not there."""
    started = timezone.now()
    result = payment_report.sync(
        account,
        back_to=(payment.paid_at or started) - VERIFY_MARGIN,
        max_pages=VERIFY_PAGES,
    )
    if not result.ok:
        raise PortalSaleError(
            "provider_unavailable",
            result.error_detail,
            status_code=503,
            extra={"provider_error_code": result.error_code},
        )
    payment.refresh_from_db()
    if payment.last_seen_at < started:
        # The report no longer prints it where it was — or it is further back
        # than a re-read may go. Either way nothing may be written on the
        # strength of a copy.
        raise PortalSaleError("payment_not_confirmed", status_code=409)


def _locked_standing(account, payment) -> PaymentStanding:
    """Where a payment stands, with every fulfillment that claims it locked."""
    claims = list(
        IntegrationFulfillment.objects.select_for_update()
        .filter(account=account, provider_reference=payment.reference)
        .select_related("order_line__order")
    )
    return standing_of(
        account,
        payment,
        claims,
        waiting_sales(account, {payment.subscriber_key}),
    )


def _refuse_wrong_session(session, payment, *, user) -> None:
    """The one drawer a payment can certainly not be in, and closed books.

    An open drawer can hold any payment: cash from the shift before is
    handed over and counted in, and the manager knows where it went. A
    CLOSED one is different in one way that is not a judgement call — it was
    counted when it closed, and a payment the provider stamped after that
    cannot have been in the count. Everything else about a closed shift is
    the manager's call and the point of allowing it: a drawer counted with a
    website top-up's cash in it shows an overage until the sale is recorded
    into it.

    Neither the payment's own day nor a closed shift's may sit inside a
    period the books are closed through: the float draw is dated by the
    payment, and a closed shift's figures are that period's figures.
    """
    from apps.core.period_lock import PeriodLocked, assert_period_open
    from apps.sales.models import RegisterSession

    closed = session.status != RegisterSession.Status.OPEN
    if (
        closed
        and session.closed_at is not None
        and payment.paid_at is not None
        and payment.paid_at > session.closed_at + SHIFT_CLOSE_SLACK
    ):
        raise PortalSaleError("session_closed_before_payment", status_code=409)
    moments = [payment.paid_at]
    if closed:
        moments.append(session.closed_at)
    for moment in moments:
        if moment is None:
            continue
        try:
            assert_period_open(
                moment,
                user=user,
                entity_type="register_session",
                entity_id=session.pk,
                action="integrations.portal_payment.record",
            )
        except PeriodLocked as locked:
            raise PortalSaleError(
                "period_locked", str(locked), status_code=409
            ) from locked


def _refuse_bad_terms(*, sale_type, customer) -> None:
    """The checkout serializer's rules on sale type, which the checkout itself
    does not re-check — so a direct caller must."""
    from apps.core.models import ShopSettings
    from apps.sales.models import Order

    if sale_type not in (Order.SaleType.STANDARD, Order.SaleType.CREDIT):
        # A quotation takes no provider work, and this top-up is done.
        raise PortalSaleError("invalid_sale_type")
    if (
        sale_type == Order.SaleType.CREDIT
        and customer is None
        and ShopSettings.load().require_customer_for_credit
    ):
        raise PortalSaleError("customer_required")


def _refuse_unless_recordable(standing: PaymentStanding, *, allow_pending_sale) -> None:
    if standing.state == STATE_RECORDED:
        raise PortalSaleError(
            "already_recorded",
            status_code=409,
            extra={"order_id": standing.claim.order_line.order_id},
        )
    if not standing.is_recordable:
        raise PortalSaleError(standing.state, status_code=409)
    if standing.state == STATE_PENDING_SALE and not allow_pending_sale:
        raise PortalSaleError(
            STATE_PENDING_SALE,
            status_code=409,
            extra={
                "order_ids": [row.order_line.order_id for row in standing.candidates]
            },
        )


def _sale_lines(account, payment, *, request) -> list:
    """The cart line a till would have rung up for this payment, validated.

    Through the till's own line serializer, so the price rule, the cost and
    the provider checks are the checkout's and not a second copy of them.
    """
    from apps.sales.serializers import CheckoutLineSerializer

    option = provider_for(account).option_for_payment(payment.amount)
    if option is None:
        raise PortalSaleError(STATE_UNSUPPORTED, status_code=409)
    package_name = (
        IntegrationSubscriber.objects.filter(
            account=account, subscriber_ref=payment.subscriber_ref
        )
        .values_list("package_name", flat=True)
        .first()
        or ""
    )
    variant = service_variant_for(account.provider)
    serializer = CheckoutLineSerializer(
        data=[
            {
                "variant": variant.pk,
                "quantity": "1",
                "integration": {
                    "provider": account.provider,
                    "subscriber_ref": payment.subscriber_ref,
                    "option_code": option.code,
                    "option_label": option.label,
                    "months": 0,
                    "package_id": "",
                    "package_name": package_name,
                    "cost": str(option.cost),
                },
            }
        ],
        many=True,
        context={"request": request},
    )
    serializer.is_valid(raise_exception=True)
    lines = [dict(line) for line in serializer.validated_data]
    # Attached only after validation, by this code: a till cannot send it.
    lines[0]["integration"]["performed"] = {
        "reference": payment.reference,
        "at": payment.paid_at,
        "receipt": _receipt(payment, package_name=package_name),
    }
    return lines


def _total_of(lines) -> Decimal:
    return sum(
        (
            Decimal(line["effective_unit_price"]) * Decimal(line["quantity"])
            for line in lines
        ),
        Decimal("0.00"),
    ).quantize(MONEY)


def _tenders(*, sale_type, method, total, amount_paid, card_receipt_url, money_account):
    """The payments the checkout records, by the till's own rules."""
    from apps.sales.models import Order

    if sale_type == Order.SaleType.CREDIT:
        paid = Decimal(str(amount_paid or 0)).quantize(MONEY)
        if paid < 0 or paid >= total:
            # All of it now is a paid sale, not a debt; a till would refuse
            # to issue it as one too.
            raise PortalSaleError("invalid_amount_paid")
    elif sale_type == Order.SaleType.STANDARD:
        paid = total
    else:
        raise PortalSaleError("invalid_sale_type")
    if paid <= 0:
        return []
    if not method:
        raise PortalSaleError("payment_method_required")
    tender = {"method": method, "amount": paid}
    if card_receipt_url:
        tender["card_receipt_url"] = card_receipt_url
    if money_account is not None:
        tender["money_account"] = money_account
    return [tender]


def _no_discounts(lines, customer):
    """A discount result that discounts nothing.

    The customer paid the website's figure. A promotion running at the till
    today never touched this payment, and letting one apply would record a
    total below the cash that is actually in the drawer.
    """
    from apps.discounts.models import DiscountRule
    from apps.discounts.services import DiscountCalculationResult

    subtotal = _total_of(lines)
    return DiscountCalculationResult(
        channel=DiscountRule.Channel.SALES,
        customer_id=customer.pk if customer is not None else None,
        supplier_id=None,
        subtotal=subtotal,
        discount_total=Decimal("0.00"),
        total=subtotal,
        applications=(),
    )


def _retire(released) -> list[int]:
    """Stand down the fulfillments of voided recordings this one replaces.

    Their top-up happened exactly once. While their invoice was void they
    still drew it from the float, correctly — the money had left. Now that a
    new sale carries it, they must stop, or the float would pay for it twice.
    """
    ids = []
    for row in released:
        row.status = IntegrationFulfillment.Status.CANCELLED
        row.save(update_fields=["status", "updated_at"])
        ids.append(row.pk)
    return ids


def _receipt(payment, *, package_name: str = "") -> dict:
    """The provider's record of the payment, kept the way a till's charge keeps its own."""
    amount = _plain(payment.amount)
    printed = {
        key: value
        for key, value in {
            "username": payment.subscriber_ref,
            "amount": amount,
            "serial": payment.reference,
            "package": package_name,
        }.items()
        if value
    }
    return {
        "reference": payment.reference,
        "serial_number": payment.reference,
        "face_value": amount,
        "cost": "" if payment.cost is None else str(payment.cost),
        "username": payment.subscriber_ref,
        "operator_name": payment.operator_name,
        "at": payment.paid_at.isoformat() if payment.paid_at else "",
        # Recorded from the provider's payments report, not answered by a
        # charge Pointy sent.
        "source": "payment_report",
        "printed": printed,
    }


def _plain(value) -> str:
    if value is None:
        return ""
    normalised = Decimal(value).normalize()
    if normalised == normalised.to_integral_value():
        return str(normalised.quantize(Decimal("1")))
    return format(normalised, "f")
