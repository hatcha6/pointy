"""Undoing a payment.

There was no way to do this before: the API exposed ``DELETE``, which made a
settled invoice unpaid again and left nothing behind saying so. A cancellation
gives the money back through an opposing payment, names who did it and why, and
lands in the drawer that is open now.
"""

from decimal import Decimal

from rest_framework import serializers

from apps.documents import services as document_services
from apps.documents.statuses import DocumentStatus
from apps.sales.models import Order, RegisterSession

from .models import Payment


def collecting_session(payment, *, request=None, register_session=None):
    """The drawer the reversal comes out of.

    Cash that goes back to a customer leaves the till that is open now, not the
    one that took it — that shift was counted and signed off. Card and transfer
    reversals touch no drawer, so they need no session.
    """
    if register_session is not None:
        return register_session
    user = getattr(request, "user", None)
    session = RegisterSession.open_for(user) if user is not None else None
    if session is not None:
        return session
    if payment.method == Payment.Method.CASH:
        raise serializers.ValidationError(
            {
                "detail": (
                    "Cash goes back into an open drawer. Open a register "
                    "session before cancelling a cash payment."
                )
            }
        )
    return payment.register_session


def cancel_payment(payment, *, reason, request=None, register_session=None):
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
    # Read the invoice, do not trust the caller's copy of it: a payment handed
    # in from before its order was voided would otherwise carry a stale
    # lifecycle and walk straight past this guard.
    order = Order.objects.only("id", "doc_status").get(pk=payment.order_id)
    if order.doc_status != DocumentStatus.SUBMITTED:
        raise serializers.ValidationError(
            {
                "detail": (
                    "The invoice this payment belongs to has been voided, and "
                    "its payments were given back with it."
                )
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


__all__ = ["cancel_payment", "collecting_session"]
