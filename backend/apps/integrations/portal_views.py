"""The API behind "payments made on the provider's website".

Three endpoints, one screen: a day of the provider's payments report with
where each payment stands in Pointy, the invoice a manager records for one,
and the link that settles a sale already waiting for that top-up. The rules
live in :mod:`apps.integrations.portal_sales`; this module only speaks HTTP.
"""

from __future__ import annotations

from datetime import date
from decimal import Decimal

from rest_framework import serializers, status
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.core.permissions import HasPointyPermission
from apps.core.timeutils import business_local_date
from apps.customers.models import Customer
from apps.treasury.models import MoneyAccount

from . import catalog, payment_report, portal_sales
from .models import IntegrationAccount, IntegrationSubscriber

RECORD = ("integrations.record_portal_payment",)
#: Recording one issues an invoice, and issuing a sale document is
#: ``sales.add_order``'s to do — the document lifecycle refuses anyone else at
#: submit. Required here too, so a grant of the first alone fails at the door
#: with a plain 403 rather than halfway through writing the sale.
RECORD_SALE = (*RECORD, "sales.add_order")

MONEY = Decimal("0.01")


def _money(value) -> str | None:
    return None if value is None else str(Decimal(value).quantize(MONEY))


def _account_for(provider: str):
    """``(account, error_response)`` for a provider whose report can be read."""
    spec = catalog.spec_for(provider)
    if spec is None:
        return None, Response(
            {"detail": "unknown provider"}, status=status.HTTP_404_NOT_FOUND
        )
    account = IntegrationAccount.objects.filter(provider=provider, is_active=True).first()
    if (
        account is None
        or not account.is_configured
        or not payment_report.supports_payment_report(account)
    ):
        return None, Response(
            {"code": "unsupported_provider", "detail": "unsupported_provider"},
            status=status.HTTP_404_NOT_FOUND,
        )
    return account, None


def _refusal(error: portal_sales.PortalSaleError) -> Response:
    return Response(error.payload(), status=error.status_code)


class IntegrationPortalPaymentsView(APIView):
    """GET one shop-local day of the provider's payments, and where each stands.

    ``?date=YYYY-MM-DD`` (default today) and ``?refresh=0`` to answer from the
    mirror without reading the provider first. The read happens by default,
    because a manager opening this screen is about to act on what it says.
    """

    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {"GET": RECORD}

    def get(self, request, provider: str):
        account, refusal = _account_for(provider)
        if refusal is not None:
            return refusal

        day = _requested_day(request.query_params.get("date"))
        if day is None:
            return Response(
                {"code": "invalid_date", "detail": "date must be YYYY-MM-DD"},
                status=status.HTTP_400_BAD_REQUEST,
            )
        start, end = payment_report.day_bounds(day)

        read = None
        if request.query_params.get("refresh", "1") not in ("0", "false"):
            read = payment_report.sync(
                account, back_to=start, max_pages=payment_report.DAY_PAGES
            )
            account.refresh_from_db()

        payments = list(payment_report.payments_between(account, start, end))
        standings = portal_sales.describe(account, payments)
        names = _subscriber_names(account, payments)
        prices = account.option_price_map()
        rows = [
            _payment_payload(
                standing,
                price=portal_sales.price_of(account, standing.payment, prices=prices)
                if standing.state != portal_sales.STATE_RECORDED
                else None,
                subscriber=names.get(standing.payment.subscriber_key),
            )
            for standing in standings
        ]
        return Response(
            {
                "provider": account.provider,
                "date": day.isoformat(),
                "currency": account.spec.currency if account.spec else "LYD",
                # Whether the provider could be read just now. The rows below
                # are still real — every one was printed by the provider — but
                # without a fresh read nobody may call the day complete.
                "read_ok": read.ok if read is not None else True,
                "read_error_code": read.error_code if read is not None else "",
                "read_at": account.payments_synced_at,
                "complete": payment_report.covered_from(account, start)
                and (read is None or read.ok),
                "payments": rows,
                "summary": _summary(standings),
                "sessions": _sessions_for(start, end),
                **_checkout_rules(),
            }
        )


class PortalPaymentRecordSerializer(serializers.Serializer):
    """How the customer paid for a top-up somebody did on the website."""

    register_session = serializers.IntegerField(min_value=1)
    sale_type = serializers.ChoiceField(choices=[], required=False)
    payment_method = serializers.ChoiceField(
        choices=[], required=False, allow_blank=True
    )
    #: آجل only: what the customer put down now. The rest is owed.
    amount_paid = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        min_value=Decimal("0.00"),
        required=False,
        allow_null=True,
    )
    customer = serializers.PrimaryKeyRelatedField(
        queryset=Customer.objects.all(), required=False, allow_null=True
    )
    card_receipt_url = serializers.CharField(
        required=False, allow_blank=True, trim_whitespace=True, default=""
    )
    money_account = serializers.PrimaryKeyRelatedField(
        queryset=MoneyAccount.objects.all(), required=False, allow_null=True
    )
    #: The manager has seen that a sale waiting for this line's top-up could
    #: be this very payment, and says it is a different one.
    allow_pending_sale = serializers.BooleanField(required=False, default=False)
    #: The total the manager was shown. Refused if the invoice would differ.
    expected_total = serializers.DecimalField(
        max_digits=12, decimal_places=2, required=False, allow_null=True
    )

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        # Filled here, like the checkout's own payment serializer, so this
        # module does not import the sales and payments models at load time.
        from apps.payments.models import Payment
        from apps.sales.models import Order

        self.fields["sale_type"].choices = [
            (Order.SaleType.STANDARD, Order.SaleType.STANDARD.label),
            (Order.SaleType.CREDIT, Order.SaleType.CREDIT.label),
        ]
        self.fields["payment_method"].choices = Payment.till_method_choices()


class IntegrationPortalPaymentRecordView(APIView):
    """POST: issue the invoice for one payment into a register session."""

    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {"POST": RECORD_SALE}

    def post(self, request, provider: str, reference: str):
        account, refusal = _account_for(provider)
        if refusal is not None:
            return refusal
        serializer = PortalPaymentRecordSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        data = serializer.validated_data
        try:
            order = portal_sales.record_payment(
                account=account,
                reference=reference,
                register_session_id=data["register_session"],
                sale_type=data.get("sale_type") or "standard",
                method=data.get("payment_method") or "",
                amount_paid=data.get("amount_paid"),
                customer=data.get("customer"),
                card_receipt_url=data.get("card_receipt_url") or "",
                money_account=data.get("money_account"),
                allow_pending_sale=data.get("allow_pending_sale", False),
                expected_total=data.get("expected_total"),
                request=request,
            )
        except portal_sales.PortalSaleError as error:
            return _refusal(error)
        except serializers.ValidationError as error:
            # The checkout's own refusals — a card slip the shop requires, an
            # آجل ceiling — keep their detail and gain a code to branch on
            # when they arrived without one.
            detail = error.detail
            if isinstance(detail, dict) and "code" in detail:
                return Response(detail, status=status.HTTP_400_BAD_REQUEST)
            return Response(
                {"code": "sale_refused", "detail": "sale_refused", "errors": detail},
                status=status.HTTP_400_BAD_REQUEST,
            )
        return Response(
            {"ok": True, "order": _order_payload(order)},
            status=status.HTTP_201_CREATED,
        )


class PortalPaymentLinkSerializer(serializers.Serializer):
    fulfillment = serializers.IntegerField(min_value=1)


class IntegrationPortalPaymentLinkView(APIView):
    """POST: this website payment IS the top-up a Pointy sale was waiting for."""

    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {"POST": RECORD}

    def post(self, request, provider: str, reference: str):
        account, refusal = _account_for(provider)
        if refusal is not None:
            return refusal
        serializer = PortalPaymentLinkSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        try:
            row = portal_sales.link_payment(
                account=account,
                reference=reference,
                fulfillment_id=serializer.validated_data["fulfillment"],
                request=request,
            )
        except portal_sales.PortalSaleError as error:
            return _refusal(error)
        return Response(
            {"ok": True, "order": _order_payload(row.order_line.order)}
        )


# --- payloads ---------------------------------------------------------------
def _requested_day(raw) -> date | None:
    if not raw:
        return business_local_date()
    try:
        return date.fromisoformat(str(raw))
    except ValueError:
        return None


def _payment_payload(standing, *, price, subscriber) -> dict:
    payment = standing.payment
    claim = standing.claim
    return {
        "reference": payment.reference,
        "paid_at": payment.paid_at,
        "amount": _money(payment.amount),
        "cost": _money(payment.cost),
        "subscriber_ref": payment.subscriber_ref,
        "subscriber_name": subscriber["name"] if subscriber else "",
        "customer_id": subscriber["customer_id"] if subscriber else None,
        "operator_name": payment.operator_name,
        # The provider's own word for it, and our stable code for that word.
        "provider_status": payment.status,
        "provider_status_label": payment.status_label,
        "state": standing.state,
        "recordable": standing.is_recordable,
        # What recording it would charge: the till's own price for the
        # amount. Absent once a sale already accounts for it.
        "price": _money(price),
        "order": _order_payload(claim.order_line.order) if claim else None,
        "candidates": [
            {
                "fulfillment_id": row.pk,
                "status": row.status,
                "sold_at": row.created_at,
                "order": _order_payload(row.order_line.order),
            }
            for row in standing.candidates
        ],
        "released_order_ids": [row.order_line.order_id for row in standing.released],
    }


def _order_payload(order) -> dict:
    session = order.register_session
    return {
        "id": order.pk,
        "receipt_number": order.receipt_number,
        "status": order.status,
        "sale_type": order.sale_type,
        "total": _money(order.total),
        "register_session_id": session.pk if session else None,
        "session_number": session.session_number if session else "",
        "cashier_name": session.owner_display_name if session else "",
    }


def _subscriber_names(account, payments) -> dict:
    """``{subscriber_key: {name, customer_id}}`` for lines the shop has named."""
    refs = {payment.subscriber_ref for payment in payments if payment.subscriber_ref}
    if not refs:
        return {}
    names = {}
    for row in IntegrationSubscriber.objects.filter(
        account=account, subscriber_ref__in=refs
    ).select_related("customer"):
        names[payment_report.subscriber_key(row.subscriber_ref)] = {
            "name": row.label,
            "customer_id": row.customer_id,
        }
    return names


def _summary(standings) -> dict:
    counts: dict[str, int] = {}
    unrecorded = Decimal("0.00")
    for standing in standings:
        counts[standing.state] = counts.get(standing.state, 0) + 1
        if standing.state in (
            portal_sales.STATE_UNRECORDED,
            portal_sales.STATE_RELEASED,
        ):
            unrecorded += standing.payment.amount or Decimal("0.00")
    return {
        "counts": counts,
        "unrecorded_count": counts.get(portal_sales.STATE_UNRECORDED, 0)
        + counts.get(portal_sales.STATE_RELEASED, 0),
        "unrecorded_amount": _money(unrecorded),
        "pending_sale_count": counts.get(portal_sales.STATE_PENDING_SALE, 0),
    }


def _sessions_for(start, end) -> list:
    """The drawers a payment of this day could be recorded into, oldest first.

    Every drawer open now — cash handed across shifts ends up in one — and
    every shift that was open at some point of the day, closed or not: that
    is where the day's website top-ups were taken. A closed one carries its
    counted variance, because the overage a website top-up left in the count
    is how a manager recognises the drawer it belongs to.
    """
    from django.db.models import Q

    from apps.sales.models import RegisterSession, prime_register_session_cash_totals

    sessions = list(
        RegisterSession.objects.filter(
            Q(status=RegisterSession.Status.OPEN)
            | Q(opened_at__lt=end, closed_at__gte=start)
        )
        .select_related("owner")
        .order_by("opened_at", "pk")
    )
    closed = [s for s in sessions if s.status != RegisterSession.Status.OPEN]
    if closed:
        prime_register_session_cash_totals(closed)
    return [
        {
            "id": session.pk,
            "session_number": session.session_number,
            "cashier_name": session.owner_display_name,
            "owner_id": session.owner_id,
            "status": session.status,
            "opened_at": session.opened_at,
            "closed_at": session.closed_at,
            "cash_variance": _money(session.cash_variance)
            if session.status != RegisterSession.Status.OPEN
            else None,
        }
        for session in sessions
    ]


def _checkout_rules() -> dict:
    """The shop's own tender rules, so the sheet asks for what checkout will."""
    from apps.core.models import ShopSettings
    from apps.payments.models import Payment

    settings = ShopSettings.load()
    return {
        "payment_methods": [
            method
            for method in Payment.TILL_METHODS
            if settings.payment_method_enabled(method)
        ],
        "require_customer_for_credit": bool(settings.require_customer_for_credit),
        "require_card_receipt": bool(settings.require_card_payment_receipt),
    }
