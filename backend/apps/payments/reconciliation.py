"""Linking cancellation counter payments that were written without the link.

A drawer counts a cancelled payment's counter row by its ``reverses`` link
(``PaymentQuerySet.takings``). Two kinds of counter row exist without one: every
cancellation made before the link did (migration ``0015`` links those), and any
an older backend writes during a live update. For about a minute in the middle
of one, **the old code is still serving against the new schema**, and it knows
the reference it writes (``cancel:<pk>``) but not the link. Left alone, that
cancellation's cash would go back over the counter without its drawer knowing —
the very shortage the link exists to prevent.

It runs on ``post_migrate``, which fires again when the managed container is
rebuilt on the new image after the flip — by which time the window has closed
and every stale row is visible. Idempotent, and empty on a fresh install.

The reference is only trusted as far as the row it names bears it out: that
payment must be cancelled, on the same invoice, by the same method, for exactly
the opposite amount, and not already given back by another row. Anyone taking
a payment can type a reference, so a row that merely claims to be a
cancellation stays what it is.
"""

import re

from django.db import connection
from django.db.models.signals import post_migrate
from django.dispatch import receiver

_DIGITS = re.compile(r"[0-9]+")


def link_counter_payments(payment_model) -> int:
    """Point every unlinked counter payment at the payment it gives back.

    Takes the model rather than importing it so that migration ``0015`` can
    hand it the historical one. Returns the rows linked.
    """
    from apps.documents.statuses import DocumentStatus
    from apps.payments.documents import COUNTER_REFERENCE_PREFIX

    candidates = (
        payment_model.objects.filter(
            reverses__isnull=True,
            amount__lt=0,
            external_reference__startswith=COUNTER_REFERENCE_PREFIX,
        )
        .order_by("id")
        .values_list("id", "order_id", "method", "amount", "external_reference")
    )
    linked = 0
    for pk, order_id, method, amount, reference in candidates:
        target = reference[len(COUNTER_REFERENCE_PREFIX) :]
        if not _DIGITS.fullmatch(target):
            continue
        original = payment_model.objects.filter(
            pk=int(target),
            order_id=order_id,
            method=method,
            amount=-amount,
            doc_status=DocumentStatus.CANCELLED,
        )
        if not original.exists():
            continue
        if payment_model.objects.filter(reverses_id=int(target)).exists():
            # Given back once already. A second row naming it is not a second
            # refund of the same money, whatever its reference says.
            continue
        payment_model.objects.filter(pk=pk).update(reverses_id=int(target))
        linked += 1
    return linked


def reconcile_payment_reversals() -> int:
    """Link what an older backend wrote during a live update. Returns rows linked."""
    from apps.documents.guards import system_write
    from apps.payments.models import Payment

    # ``reverses`` is frozen on a submitted payment like every other field it
    # carries. Filling in the link a row was written without is the machine
    # catching up, not a person rewriting what a payment said.
    with system_write():
        return link_counter_payments(Payment)


def _has_reverses_column() -> bool:
    """``post_migrate`` also fires for partial and backwards runs, where the
    live model has the column and the table may not yet."""
    try:
        with connection.cursor() as cursor:
            columns = connection.introspection.get_table_description(
                cursor, "payments_payment"
            )
    except Exception:  # pragma: no cover - schema not ready
        return False
    return any(column.name == "reverses_id" for column in columns)


@receiver(post_migrate)
def _reconcile_after_migrate(sender, **kwargs):
    if getattr(sender, "label", None) != "payments":
        return
    if not _has_reverses_column():
        return
    reconcile_payment_reversals()
