"""Undoing a payment.

There was no way to do this before: the API exposed ``DELETE``, which made a
settled invoice unpaid again and left nothing behind saying so. A cancellation
gives the money back through an opposing payment, names who did it and why, and
lands in the drawer that is open now.

A cash sale is the exception. It is settled at the counter by definition, and
nothing in the shop can hold what its customer would still owe: receivables,
debt reminders and the collect button all belong to credit invoices, so an
unpaid cash sale dropped out of every sales figure while its goods stayed gone.
A cancellation that would leave one unpaid is therefore refused, and the two
things a shop actually means by it each have a route of their own: giving the
sale back is a void or a return, and having taken it the wrong way is
``replace_payment``.
"""

from decimal import Decimal

from django.db import transaction
from django.db.models import Sum
from rest_framework import serializers

from apps.analytics.models import AnalyticsEvent
from apps.analytics.services import record_domain_event
from apps.documents import services as document_services
from apps.documents.statuses import DocumentStatus
from apps.sales.documents import settled_amount
from apps.sales.models import Order, RegisterSession

from .models import Payment


def collecting_session(payment, *, request=None, register_session=None, moves_cash=None):
    """The drawer the reversal comes out of.

    Cash that goes back to a customer leaves the till that is open now, not the
    one that took it — that shift was counted and signed off. Card and transfer
    reversals touch no drawer, so they need no session. ``moves_cash`` is for a
    caller that also takes cash in, which needs an open drawer just the same.
    """
    if register_session is not None:
        return register_session
    user = getattr(request, "user", None)
    session = RegisterSession.open_for(user) if user is not None else None
    if session is not None:
        return session
    if moves_cash is None:
        moves_cash = payment.method == Payment.Method.CASH
    if moves_cash:
        raise serializers.ValidationError(
            {
                "detail": (
                    "Cash moves through an open drawer. Open a register "
                    "session before cancelling or replacing a cash payment."
                )
            }
        )
    return payment.register_session


@transaction.atomic
def cancel_payment(payment, *, reason, request=None, register_session=None):
    """Give ``payment`` back with an opposing one, out of the drawer open now.

    A credit invoice is owed again afterwards, which is the honest consequence.
    A cash sale cannot be (see the module docstring): a cancellation that would
    leave one unpaid is refused. One that leaves it settled, such as giving back
    an extra payment, is not.
    """
    order = _given_back_from(payment)
    if (
        order.sale_type == Order.SaleType.STANDARD
        and settled_amount(order) - payment.amount < order.total
    ):
        raise serializers.ValidationError(
            {
                "code": "cash_sale_payment_not_cancellable",
                "detail": (
                    "A cash sale is settled at the counter, and cancelling this "
                    "payment would leave it unpaid. Void the sale or return its "
                    "items to give it back, or replace the payment to change "
                    "how it was paid."
                ),
            }
        )
    session = collecting_session(
        payment, request=request, register_session=register_session
    )
    return document_services.cancel(
        payment,
        reason=reason,
        request=request,
        context={"register_session": session},
    )


@transaction.atomic
def replace_payment(payment, *, tenders, reason, request=None, register_session=None):
    """Change the tender a payment came through, never the amount.

    The cashier pressed cash and the customer paid by card, or the card went
    through the other bank's terminal. The new tenders are taken first, against
    the same invoice and into the drawer that is open now, and then the old
    payment is given back by the ordinary cancellation. In between, the invoice
    is briefly over-settled rather than briefly unpaid. So it never leaves the
    sales it is counted in, and nothing that fires when an invoice *becomes*
    paid (a receipt print, the paid event) fires a second time.

    ``tenders`` are ``{"method", "amount"}`` dicts, optionally carrying
    ``card_receipt_url`` and ``money_account``, and must add up to the payment.
    """
    from .serializers import PaymentSerializer

    order = _given_back_from(payment)
    if not tenders:
        raise serializers.ValidationError(
            {"payments": "Name the tender the payment is taken through instead."}
        )
    if any(tender["method"] not in Payment.TILL_METHODS for tender in tenders):
        raise serializers.ValidationError(
            {"payments": "A replacement is taken at the till: cash, card or transfer."}
        )
    replacing_total = sum(
        (Decimal(tender["amount"]) for tender in tenders), Decimal("0.00")
    ).quantize(Decimal("0.01"))
    if replacing_total != payment.amount:
        raise serializers.ValidationError(
            {
                "payments": (
                    f"The replacement must add up to the payment it replaces "
                    f"({payment.amount}); it adds up to {replacing_total}."
                )
            }
        )
    session = collecting_session(
        payment,
        request=request,
        register_session=register_session,
        moves_cash=(
            payment.method == Payment.Method.CASH
            or any(tender["method"] == Payment.Method.CASH for tender in tenders)
        ),
    )

    replacements = []
    for tender in tenders:
        data = {"order": order.pk, "method": tender["method"], "amount": tender["amount"]}
        if tender.get("card_receipt_url"):
            data["card_receipt_url"] = tender["card_receipt_url"]
        if tender.get("money_account") is not None:
            data["money_account"] = getattr(
                tender["money_account"], "pk", tender["money_account"]
            )
        serializer = PaymentSerializer(
            data=data,
            context={
                "request": request,
                "register_session": session,
                "stock_already_recorded": True,
                "replacing": payment,
            },
        )
        serializer.is_valid(raise_exception=True)
        replacements.append(serializer.save())

    document_services.cancel(
        payment,
        reason=reason,
        request=request,
        context={"register_session": session},
    )
    record_domain_event(
        name="payments.payment.replaced",
        event_type=AnalyticsEvent.EventType.AUDIT,
        user=getattr(request, "user", None),
        entity_type="sale_order",
        entity_id=order.pk,
        attributes={
            "receipt_number": order.receipt_number,
            "payment_id": payment.pk,
            "from_method": payment.method,
            "to_methods": [replacement.method for replacement in replacements],
            "replacement_ids": [replacement.pk for replacement in replacements],
            "register_session_id": getattr(session, "pk", None),
            "reason_present": bool(reason),
        },
        metrics={"amount": float(payment.amount)},
    )
    return replacements


def _given_back_from(payment):
    """The invoice ``payment`` is about to be given back from, locked, once
    every refusal shared by cancelling and replacing it has been checked."""
    if payment.amount <= Decimal("0.00"):
        raise serializers.ValidationError(
            {
                "detail": (
                    "This row is already a refund. Take the payment again "
                    "rather than cancelling the refund."
                )
            }
        )
    if payment.method == Payment.Method.SALARY_DEDUCTION:
        # The wage it came out of was paid smaller. Cancelling only this row
        # would reopen the invoice and leave the employee charged twice.
        raise serializers.ValidationError(
            {
                "code": "salary_deduction_owned_by_payroll",
                "detail": (
                    "This invoice was settled from the employee's wages. Void "
                    "the payroll run that took it to give it back."
                ),
            }
        )
    if payment.method == Payment.Method.ACCOUNT_CREDIT:
        # It spent credit the shop owed the customer. Cancelling this row alone
        # would reopen the debt and leave the credit spent — the customer would
        # owe the same money twice.
        raise serializers.ValidationError(
            {
                "code": "account_credit_owned_by_balance",
                "detail": (
                    "This debt was settled from the customer's account credit, "
                    "and cannot be cancelled on its own."
                ),
            }
        )
    # Read the invoice, do not trust the caller's copy of it: a payment handed
    # in from before its order was voided would otherwise carry a stale
    # lifecycle and walk straight past this guard. Locked, because what it
    # still holds is about to be read and a return racing this would change it.
    order = Order.objects.select_for_update().get(pk=payment.order_id)
    if order.doc_status != DocumentStatus.SUBMITTED:
        raise serializers.ValidationError(
            {
                "detail": (
                    "The invoice this payment belongs to has been voided, and "
                    "its payments were given back with it."
                )
            }
        )
    # A return refunds through the tenders the sale was paid with, so part or
    # all of this payment may have gone back already. Giving the whole of it
    # back again would pay the customer twice for the same goods.
    held = order.payments.filter(method=payment.method).aggregate(
        total=Sum("amount")
    )["total"] or Decimal("0.00")
    if payment.amount > held:
        raise serializers.ValidationError(
            {
                "code": "payment_already_given_back",
                "detail": (
                    "Part of this payment has already gone back to the "
                    "customer, through a return or an earlier cancellation. "
                    "Giving it back again would hand over more than the shop "
                    "still holds for this invoice."
                ),
            }
        )
    return order


__all__ = ["cancel_payment", "collecting_session", "replace_payment"]
