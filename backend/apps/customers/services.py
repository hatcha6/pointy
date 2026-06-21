"""Customer-domain services: payment-card linking and customer merges.

The card auto-link runs at the single payment-creation chokepoint
(``PaymentSerializer.create``), so checkout, standalone partial payments, and job
invoicing all funnel through it. Refund and data-migration paths build ``Payment``
rows directly and intentionally skip this (their FK stays null).
"""

import hashlib
import re

from django.db import IntegrityError, transaction
from django.utils import timezone

from .models import Customer, PaymentCard


def _normalize_pan(value) -> str:
    return re.sub(r"\s+", "", str(value or "")).upper()


def card_fingerprint(receipt_data: dict) -> str:
    """Stable dedupe key for a card from its decoded receipt data.

    Returns "" when there's no masked PAN to key on (nothing to dedupe).
    """
    masked_pan = _normalize_pan(receipt_data.get("masked_pan"))
    if not masked_pan:
        return ""
    scheme = str(receipt_data.get("card_type") or "").strip().upper()
    aid = str(receipt_data.get("aid") or "").strip().upper()
    raw = "|".join([masked_pan, scheme, aid])
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def placeholder_card_name(masked_pan) -> str:
    digits = re.sub(r"\D", "", str(masked_pan or ""))
    last4 = digits[-4:] if len(digits) >= 4 else digits
    return f"Card •••• {last4 or 'card'}"


@transaction.atomic
def link_card_payment(payment) -> PaymentCard | None:
    """Attach a card payment to its PaymentCard (and a customer).

    Smart-attach rules, keyed on whether the order already has *any* customer so
    a split tender across two cards on one walk-in order doesn't fight over the
    placeholder:

    * new card + order has no customer  -> mint a placeholder customer, attach to order
    * new card + order has a customer   -> create the card under that customer
    * existing card + order has no customer -> order adopts the card's owner
    * existing card + order has a customer  -> leave the owner, just link the payment
    """
    receipt_data = payment.card_receipt_data or {}
    fingerprint = card_fingerprint(receipt_data)
    if not fingerprint:
        return None

    masked_pan = str(receipt_data.get("masked_pan") or "").strip()
    order = payment.order
    card = (
        PaymentCard.objects.select_for_update()
        .filter(fingerprint=fingerprint)
        .first()
    )

    if card is None:
        card = _create_card(order, fingerprint, masked_pan, receipt_data)
    else:
        _touch_card(card, masked_pan, receipt_data)
        _adopt_card_owner(order, card)

    payment.card = card
    payment.save(update_fields=["card", "updated_at"])
    return card


def _create_card(order, fingerprint, masked_pan, receipt_data) -> PaymentCard:
    now = timezone.now()
    try:
        with transaction.atomic():
            owner = (
                order.customer
                if order.customer_id
                else Customer.objects.create(
                    full_name=placeholder_card_name(masked_pan),
                    is_auto_created=True,
                )
            )
            card = PaymentCard.objects.create(
                customer=owner,
                fingerprint=fingerprint,
                masked_pan=masked_pan,
                card_scheme=str(receipt_data.get("card_type") or "").strip(),
                aid=str(receipt_data.get("aid") or "").strip(),
                first_seen_at=now,
                last_seen_at=now,
                last_receipt_data=receipt_data,
            )
    except IntegrityError:
        # Same card raced in on another register; fold into the now-existing row.
        card = PaymentCard.objects.select_for_update().get(fingerprint=fingerprint)
        _touch_card(card, masked_pan, receipt_data)
        _adopt_card_owner(order, card)
        return card

    if not order.customer_id:
        order.customer = card.customer
        order.save(update_fields=["customer", "updated_at"])
    return card


def _touch_card(card, masked_pan, receipt_data) -> None:
    card.last_seen_at = timezone.now()
    card.last_receipt_data = receipt_data
    if masked_pan:
        card.masked_pan = masked_pan
    card.save(
        update_fields=["last_seen_at", "last_receipt_data", "masked_pan", "updated_at"]
    )


def _adopt_card_owner(order, card) -> None:
    if not order.customer_id:
        order.customer = card.customer
        order.save(update_fields=["customer", "updated_at"])


@transaction.atomic
def merge_customers(*, source: Customer, target: Customer) -> Customer:
    """Fold ``source`` into ``target``: re-point every relation, then delete source.

    Covers all FKs/M2Ms pointing at Customer — cards & assets (PROTECT, moved
    first so the delete is unblocked), orders, jobs and discount redemptions
    (SET_NULL), and the discount-rule M2M. Order adjustments ride along via their
    order. ``Payment.card`` is untouched (it points at the card, which moved).
    """
    if source.pk == target.pk:
        raise ValueError("Cannot merge a customer into itself.")

    source.cards.update(customer=target)
    source.assets.update(customer=target)
    source.orders.update(customer=target)
    source.jobs.update(customer=target)
    source.discount_redemptions.update(customer=target)
    for rule in source.discount_rules.all():
        rule.customers.remove(source)
        rule.customers.add(target)

    source.delete()
    return target
