"""Settling a card receipt that could not prove itself at the counter.

Only reference providers land here (see ``card_receipts.base``). Their link
carries an opaque token, so the amount can only be learned by asking the issuer,
and that ask took 16-44 seconds against Madfoatech in testing because the server
renders the receipt image on demand. Nothing that slow belongs in a checkout, so
the payment is written first and proved afterwards.

The outcomes are deliberately four, not two, because they mean different things
to a shop:

``settled``      proved, and it is this payment's receipt.
``mismatch``     proved, but for a different amount. The receipt is real and the
                 payment is wrong -- or the slip was taken from another sale.
``rejected``     the issuer disowned the token. This is the forgery signal.
``unavailable``  we could not reach the issuer. Says nothing about the receipt,
                 and must never be allowed to look like ``rejected``: a shop on
                 a Libyan connection is offline routinely, and branding its
                 takings fraudulent for it would be worse than not checking.
"""

import logging

from django.db import transaction
from django.utils import timezone

from apps.core.dispatch import enqueue_best_effort
from apps.core.models import ShopSettings

from .card_receipts import (
    CardReceiptError,
    IssuerUnavailable,
    amount_matches,
    provider_for,
    terminal_is_trusted,
    verify_receipt_url,
)
from .card_receipts.base import (
    MISMATCH,
    PENDING,
    REJECTED,
    SETTLED,
    UNAVAILABLE,
)

logger = logging.getLogger(__name__)


def receipt_is_pending(payment) -> bool:
    data = payment.card_receipt_data or {}
    return data.get("verification_state") == PENDING


def schedule_receipt_verification(payment) -> bool:
    """Queue the issuer fetch for a receipt that arrived unproven.

    Queued ``on_commit`` so the worker cannot read the payment before the
    transaction that created it lands -- the task fetches by primary key, and a
    worker that wins that race sees no row at all.
    """
    if not receipt_is_pending(payment):
        return False

    # Best-effort, because this hook runs inside the request that just took the
    # money: a wedged broker must cost the shop a delayed check, never the sale.
    # ``sweep_unverified_card_receipts`` is what makes that safe -- a receipt
    # that never got queued is found again by age.
    transaction.on_commit(
        lambda: enqueue_best_effort(
            "payments.verify_card_receipt", payment.pk
        )
    )
    return True


def verify_payment_receipt(payment, *, fetch=None) -> str:
    """Ask the issuer about one payment's receipt and record what it said.

    Returns the resulting state. Raises ``IssuerUnavailable`` so the Celery task
    can retry it -- that is the one outcome worth trying again, and it is
    deliberately not swallowed here.
    """
    data = dict(payment.card_receipt_data or {})
    url = data.get("source_url") or ""
    if not url or provider_for(url) is None:
        return record_verification_state(payment, data, UNAVAILABLE, "No receipt link to verify.")

    try:
        receipt, _image = verify_receipt_url(url, fetch=fetch)
    except IssuerUnavailable:
        raise
    except CardReceiptError as exc:
        return record_verification_state(payment, data, REJECTED, str(exc))

    settings = ShopSettings.load()
    proved = receipt.to_payment_data()
    # What the issuer says replaces what the scan guessed, but the link the
    # shop actually scanned is kept: it is the audit trail.
    proved["source_url"] = url

    # One slip can cover several invoices (an account collection splits a single
    # swipe). Those rows carry the total the slip should prove; everything else
    # is checked against its own amount.
    expected = data.get("expected_amount") or payment.amount
    if data.get("expected_amount"):
        proved["expected_amount"] = data["expected_amount"]
    if receipt.is_verified and not amount_matches(expected, receipt):
        return record_verification_state(
            payment,
            proved,
            MISMATCH,
            f"Receipt proves {receipt.amount}, payment recorded {expected}.",
        )
    if not terminal_is_trusted(receipt, settings.trusted_card_terminal_ids):
        return record_verification_state(
            payment,
            proved,
            MISMATCH,
            "Receipt terminal is not trusted for this shop.",
        )

    state = record_verification_state(payment, proved, SETTLED, "")
    # Only now are there card details to dedupe on: the pending receipt had
    # none, so the link at checkout was a no-op.
    from apps.customers.services import link_card_payment

    if not payment.external_reference and receipt.reference:
        payment.external_reference = receipt.reference[:128]
        payment.save(update_fields=["external_reference", "updated_at"])
    link_card_payment(payment)
    return state


def record_verification_state(payment, data, state, message) -> str:
    data["verification_state"] = state
    data["verification_error"] = message
    data["verified_at"] = timezone.now().isoformat()
    if state != SETTLED:
        # Never leave a failed check looking proved.
        data["server_validated"] = False
    payment.card_receipt_data = data
    payment.save(update_fields=["card_receipt_data", "updated_at"])
    if state in (REJECTED, MISMATCH):
        logger.warning(
            "card receipt %s for payment %s: %s", state, payment.pk, message
        )
    return state
