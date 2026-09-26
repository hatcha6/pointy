"""What a payment means to the document lifecycle.

A payment is undone by its opposite, not by being deleted: the refund path has
always written a negative payment row per tender so that every ledger and every
balance nets out on its own. Cancelling one takes the same shape.

The drawer is the one sum that had to learn the difference. It leaves a
refund's negative rows out — a refund reaches it through the return's
``cash_amount`` — so it has to be told which negative rows are cancellations,
and ``reverses`` is how.
"""

from django.utils import timezone

from apps.payments.models import Payment

#: What a counter payment's reference says, for the people reading a ledger.
#: The drawer never reads it (see ``Payment.reverses``); the catch-up in
#: ``reconciliation`` does, for counter rows written before the link existed.
COUNTER_REFERENCE_PREFIX = "cancel:"


def reverse(payment, *, at, actor, reason="", context=None):
    """Give the money back with an opposing payment.

    Dated now, never backdated, and attributed to the drawer that is open now —
    a payment taken yesterday and cancelled today is today's cash going out.
    """
    from apps.payments.serializers import payment_commission_values
    from apps.sales import documents as sales_documents

    context = context or {}
    commission_percent, commission_amount = payment_commission_values(
        payment.method, -payment.amount
    )
    counter = Payment.objects.create(
        order=payment.order,
        method=payment.method,
        amount=-payment.amount,
        commission_percent=commission_percent,
        commission_amount=commission_amount,
        external_reference=f"{COUNTER_REFERENCE_PREFIX}{payment.pk}",
        reverses=payment,
        register_session=(
            context.get("register_session") or payment.register_session
        ),
        created_by=actor,
        paid_at=at or timezone.now(),
    )
    # The order's own progress reads from its payments, so it has to be asked
    # again now that one of them has been given back.
    sales_documents.recompute_progress(payment.order)
    return counter


__all__ = ["COUNTER_REFERENCE_PREFIX", "reverse"]
