"""Background settlement of card receipts whose issuer has to be asked.

Split from ``verification`` so the policy (what an outcome means) stays readable
next to the money, and the retry mechanics stay here.
"""

import logging
from datetime import timedelta

from celery import shared_task
from django.utils import timezone

from apps.core.dispatch import enqueue_best_effort

from .card_receipts import IssuerUnavailable
from .card_receipts.base import PENDING, UNAVAILABLE

logger = logging.getLogger(__name__)

# How long a receipt may sit unproven before the sweep tries it again. Longer
# than the retry ladder below, so the sweep picks up only what the task itself
# has given up on -- or never received, if the broker was down at checkout.
STALE_AFTER_MINUTES = 30


@shared_task(
    bind=True,
    name="payments.verify_card_receipt",
    autoretry_for=(IssuerUnavailable,),
    retry_backoff=60,
    retry_backoff_max=1800,
    retry_jitter=True,
    retry_kwargs={"max_retries": 5},
)
def verify_payment_card_receipt(self, payment_id):
    from .models import Payment
    from .verification import verify_payment_receipt

    try:
        payment = Payment.objects.get(pk=payment_id)
    except Payment.DoesNotExist:
        # The payment was reversed before we got to it. Nothing to prove.
        return None

    try:
        return verify_payment_receipt(payment)
    except IssuerUnavailable:
        if self.request.retries >= self.max_retries:
            # Out of attempts. Record that we could not ask -- which is not the
            # same as the receipt being bad, and is stored as its own state so
            # the sweep can come back to it later.
            from .verification import record_verification_state

            return record_verification_state(
                payment,
                dict(payment.card_receipt_data or {}),
                UNAVAILABLE,
                "Could not reach the card issuer.",
            )
        raise


@shared_task(name="payments.sweep_unverified_card_receipts")
def sweep_unverified_card_receipts(limit=200):
    """Re-queue receipts that were never settled.

    Covers the two ways a receipt goes quiet: the broker was down when the
    payment was taken, so nothing was ever queued; or the shop was offline long
    enough to exhaust the retries. Neither should leave money permanently
    unchecked.
    """
    from .models import Payment

    cutoff = timezone.now() - timedelta(minutes=STALE_AFTER_MINUTES)
    stale = Payment.objects.filter(
        method=Payment.Method.CARD,
        created_at__lt=cutoff,
        card_receipt_data__verification_state__in=[PENDING, UNAVAILABLE],
    ).order_by("created_at")[:limit]

    queued = 0
    for payment in stale:
        if not enqueue_best_effort("payments.verify_card_receipt", payment.pk):
            # The broker is not taking work; the next sweep will try again.
            break
        queued += 1
    return queued
