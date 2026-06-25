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
    * existing card + order has a *named* customer -> the named customer wins.
      Fold the card (and the placeholder it was parked under) into them, so the
      moment a cashier finally picks the customer we back-fill every earlier
      anonymous sale on that card -- no manual reassign, no forgotten link. Two
      *named* customers on one card is a real conflict (a shared card, or a
      mis-picked customer), so that case is left for the manual reassign action.
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
        _reconcile_card_owner(order, card)

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
        _reconcile_card_owner(order, card)
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


def _reconcile_card_owner(order, card) -> None:
    """Settle who owns ``card`` once it meets ``order``'s customer.

    A walk-in order (no customer) simply takes on whoever already owns the card,
    so a returning anonymous shopper keeps landing under the same placeholder.
    But once the order carries a *named* customer and the card is still parked
    under an auto-created placeholder, the named customer wins -- that's the
    cashier finally telling us who this is, and it's our job to record it rather
    than leave the data half-filled.
    """
    if not order.customer_id:
        order.customer = card.customer
        order.save(update_fields=["customer", "updated_at"])
        return

    if order.customer_id == card.customer_id:
        return  # already aligned

    placeholder = card.customer
    named_customer = order.customer
    if not placeholder.is_auto_created or named_customer.is_auto_created:
        # Either the card already belongs to a named customer (a real
        # conflict -> leave it for the manual reassign action) or the order's
        # customer is itself a placeholder (nothing more authoritative to adopt).
        return

    # Capture the placeholder's id up front: merge_customers deletes it, and
    # Django zeroes the in-memory pk on delete, so the audit trail would lose it.
    placeholder_id = placeholder.pk
    if placeholder.cards.count() == 1:
        # The placeholder only ever existed to hold this one card, so fold its
        # whole history -- this card plus every earlier anonymous sale on it --
        # into the named customer and retire the placeholder.
        merge_customers(source=placeholder, target=named_customer)
        folded = True
    else:
        # The placeholder still holds other cards (a split tender minted it for
        # more than one), so move just this card and leave a co-payer's alone.
        card.customer = named_customer
        card.save(update_fields=["customer", "updated_at"])
        folded = False

    _record_auto_link(
        card_id=card.pk,
        from_customer_id=placeholder_id,
        to_customer_id=named_customer.pk,
        folded=folded,
    )


def _record_auto_link(*, card_id, from_customer_id, to_customer_id, folded) -> None:
    # Moving a card between customers is normally a deliberate human action, so
    # leave an audit trail even when we do it automatically.
    from apps.analytics.services import record_domain_event

    record_domain_event(
        name="customers.payment_card.auto_linked",
        entity_type="payment_card",
        entity_id=card_id,
        attributes={
            "from_customer_id": from_customer_id,
            "to_customer_id": to_customer_id,
            "placeholder_merged": folded,
        },
    )


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
