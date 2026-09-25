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


def _pan_identifying_digits(masked_pan: str) -> int:
    """How many real digits a masked PAN actually reveals."""
    return len(re.sub(r"[^0-9]", "", masked_pan))


def card_fingerprint(receipt_data: dict) -> str:
    """Stable dedupe key for a card from its decoded receipt data.

    Returns "" when there's nothing safe to key on -- which means the card is
    not deduped and not linked to a customer, rather than being merged with
    somebody else's.

    How much a receipt reveals depends on who printed it, and that changes what
    a fingerprint can safely be:

    * Moamalat prints BIN + last four (``639974*********8809``) -- ten digits,
      enough to identify a card on its own. Its key is computed exactly as it
      always has been, byte for byte, because changing the formula would
      re-fingerprint every card already stored and silently duplicate them.

    * Madfoatech prints last four only (``************5091``) and carries no
      AID. Keyed the old way, that collapses to four digits plus a scheme name:
      two unrelated customers holding NUMO cards ending 5091 would land on one
      PaymentCard, and ``link_card_payment`` would file one person's purchase
      history under the other. With a few hundred cards in a shop that is not a
      remote possibility, it is the expected outcome. So a thin PAN has to be
      backed by the cardholder name the slip also prints, and a receipt with
      neither is left unlinked.
    """
    masked_pan = _normalize_pan(receipt_data.get("masked_pan"))
    scheme = str(receipt_data.get("card_type") or "").strip().upper()
    aid = str(receipt_data.get("aid") or "").strip().upper()

    if masked_pan and (_pan_identifying_digits(masked_pan) >= 10 or aid):
        raw = "|".join([masked_pan, scheme, aid])
        return hashlib.sha256(raw.encode("utf-8")).hexdigest()

    cardholder = cardholder_key(receipt_data.get("cardholder_name"))
    if not cardholder:
        return ""
    provider = str(receipt_data.get("provider") or "").strip().lower()
    raw = "|".join([provider, masked_pan, scheme, aid, cardholder])
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def cardholder_key(value) -> str:
    """The cardholder name folded to a comparable key, or "" if unusable."""
    text = re.sub(r"[^A-Z/ ]", "", str(value or "").upper())
    return re.sub(r"\s+", " ", text.replace("/", " ")).strip()


def cardholder_display_name(value) -> str:
    """The cardholder as a shop would write it, or "" if it cannot be trusted.

    Two formats turn up, and only one of them says what the order is:

    * ``SETTA/HATEM`` -- the EMV form, unambiguously SURNAME/FORENAME, so it is
      reordered into ``Hatem Setta``.
    * ``QARQOOM SALEH`` -- Moamalat prints the same name without the slash, and
      nothing in it marks which half is the surname. It is kept exactly as
      printed rather than reordered on a guess: ``Qarqoom Saleh`` is findable
      either way, and a wrong reordering renames a real person.

    Returns "" for anything that does not look like a name at all, so a garbled
    OCR read becomes a plain card placeholder instead of a customer nobody can
    find.
    """
    text = re.sub(r"\s+", " ", str(value or "").strip())
    if not re.fullmatch(r"[A-Za-z][A-Za-z .'/-]*", text or ""):
        return ""
    if "/" in text:
        surname, _, forename = text.partition("/")
        surname, forename = surname.strip().title(), forename.strip().title()
        if len(surname) < 2 or len(forename) < 2:
            return ""
        return f"{forename} {surname}"
    if len(text) < 3 or " " not in text:
        return ""
    return text.title()


def placeholder_card_name(masked_pan, receipt_data=None) -> str:
    """What to call the customer a card mints when the order has none.

    Uses the cardholder's own name when the slip printed one -- Madfoatech does,
    Moamalat does not -- because "Hatem Setta" is a person the shop can find
    later and "Card •••• 5091" is a puzzle. The row stays ``is_auto_created``
    either way: the name is a Latin transliteration off a card, not something
    the shop typed, and that flag is what keeps it out of the customer list and
    lets a real customer absorb it later.
    """
    named = cardholder_display_name((receipt_data or {}).get("cardholder_name"))
    if named:
        return named
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
                    full_name=placeholder_card_name(masked_pan, receipt_data),
                    is_auto_created=True,
                )
            )
            card = PaymentCard.objects.create(
                customer=owner,
                fingerprint=fingerprint,
                masked_pan=masked_pan,
                cardholder_name=str(
                    receipt_data.get("cardholder_name") or ""
                ).strip()[:120],
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
    # Backfill only. The name a card was first matched on is never rewritten:
    # it is what the fingerprint was built from, so changing it here would
    # silently decouple the stored key from the value it came from.
    if not card.cardholder_name:
        card.cardholder_name = str(
            receipt_data.get("cardholder_name") or ""
        ).strip()[:120]
    card.save(
        update_fields=[
            "last_seen_at",
            "last_receipt_data",
            "masked_pan",
            "cardholder_name",
            "updated_at",
        ]
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

    _carry_staff_account(source=source, target=target)
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


def _carry_staff_account(*, source, target):
    """Keep an employee's staff account when it is merged away.

    Merging it into a duplicate of the same person moves the employee onto the
    surviving record, so their purchases keep reaching payroll. Merging two
    different employees' accounts would hand one person's purchases to the
    other's wages, so it is refused.
    """
    from apps.employees.models import Employee
    from rest_framework import serializers as drf_serializers

    source_employee = Employee.objects.filter(customer=source).first()
    if source_employee is None:
        return
    if Employee.objects.filter(customer=target).exists():
        raise drf_serializers.ValidationError(
            {
                "source_id": (
                    "Both customers are employees' staff accounts; merging them "
                    "would charge one employee's purchases to the other."
                )
            }
        )
    source_employee.customer = target
    source_employee.save(update_fields=["customer", "updated_at"])


# ---------------------------------------------------------------------------
# Asset ownership
# ---------------------------------------------------------------------------


def open_asset_ownership(asset, *, note=""):
    """Repair an asset whose current-owner row is missing or out of date.

    New assets get their row from the ``post_save`` signal and transfers keep it
    in step, so this is a self-heal for rows that predate either — data imported
    straight into the table, or an ``Asset.customer`` changed by a bulk update
    that bypassed :func:`transfer_asset`.
    """
    from .models import AssetOwnership

    current = asset.ownerships.filter(released_at__isnull=True).first()
    if current is not None and current.customer_id == asset.customer_id:
        return current
    if current is not None:
        current.released_at = timezone.now()
        current.save(update_fields=["released_at", "updated_at"])
    return AssetOwnership.objects.create(
        asset=asset,
        customer=asset.customer,
        acquired_at=asset.created_at or timezone.now(),
        note=note,
    )


@transaction.atomic
def transfer_asset(*, asset, customer, note="", request=None):
    """Hand an asset to a new owner, keeping its whole service history.

    Second-hand phones and used cars change hands constantly here, and they come
    back to the shop that knows them. Re-pointing the asset instead of creating a
    duplicate is what lets the new owner be told "this car had its gearbox done
    here in March" — the history belongs to the item, not to whoever owned it at
    the time.
    """
    from apps.analytics.models import AnalyticsEvent
    from apps.analytics.services import record_domain_event
    from rest_framework import serializers as drf_serializers

    from .models import Asset, AssetOwnership

    asset = Asset.objects.select_for_update().get(pk=asset.pk)
    if customer is None:
        raise drf_serializers.ValidationError(
            {"customer": "An asset always has an owner."}
        )
    previous_customer_id = asset.customer_id
    if previous_customer_id == customer.pk:
        return asset

    now = timezone.now()
    asset.ownerships.filter(released_at__isnull=True).update(
        released_at=now,
        updated_at=now,
    )
    AssetOwnership.objects.create(
        asset=asset,
        customer=customer,
        acquired_at=now,
        note=note,
    )
    asset.customer = customer
    asset.save(update_fields=["customer", "updated_at"])
    record_domain_event(
        name="customers.asset.transferred",
        event_type=AnalyticsEvent.EventType.AUDIT,
        user=getattr(request, "user", None),
        entity_type="customers_asset",
        entity_id=asset.pk,
        attributes={
            "previous_customer_id": previous_customer_id,
            "customer_id": customer.pk,
            "identity": asset.identity_label,
            "note_present": bool(note),
        },
    )
    return asset
