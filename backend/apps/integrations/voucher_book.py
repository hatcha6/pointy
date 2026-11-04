"""The shop's book of accounts it has topped up: one place that writes and reads it.

A shop sells game top-ups to many customers, and the same customers come back,
so the book is filled by the sale itself and shared by every till
(:class:`.models.IntegrationSavedAccount`). Best-effort: a sale is never worth
failing over its entry here.
"""

from __future__ import annotations

import logging

from django.db import IntegrityError, transaction
from django.db.models import Case, F, IntegerField, Q, Value, When
from django.utils import timezone

from . import voucher_accounts
from .models import IntegrationSavedAccount

logger = logging.getLogger(__name__)

#: How many accounts one read answers: the page a cashier can scan.
PAGE = 30


def note_sale(fulfillment, *, target: dict) -> None:
    """Remember the account a sale was sent to. Never raises.

    A Steam invite link is used once, so it is not worth keeping.
    """
    if target.get("kind") == voucher_accounts.KIND_STEAM_INVITE:
        return
    try:
        # A savepoint: a failure here must not poison the sale's transaction.
        with transaction.atomic():
            _note(fulfillment)
    except Exception:  # noqa: BLE001 - see the docstring
        logger.warning(
            "could not note the account of fulfillment %s", fulfillment.pk, exc_info=True
        )


def _note(row) -> None:
    now = timezone.now()
    customer_id = row.order_line.order.customer_id
    brand_code = row.package_id
    updates = {"use_count": F("use_count") + 1, "last_used_at": now, "updated_at": now}
    if row.account_name:
        updates["player_name"] = row.account_name
    if customer_id:
        updates["customer_id"] = customer_id
    found = IntegrationSavedAccount.objects.filter(
        account_id=row.account_id, brand_code=brand_code, ref=row.subscriber_ref
    )
    if found.update(**updates):
        return
    try:
        with transaction.atomic():
            IntegrationSavedAccount.objects.create(
                account_id=row.account_id,
                brand_code=brand_code,
                ref=row.subscriber_ref,
                values=dict(row.account_target),
                player_name=row.account_name,
                customer_id=customer_id,
                last_used_at=now,
            )
    except IntegrityError:
        # Another till sold to the same account in this very moment.
        found.update(**updates)


def search(brand_code: str, *, text: str = "", customer_id: int | None = None):
    """``(rows, has_more)``: the brand's accounts, the sale's customer's first."""
    rows = IntegrationSavedAccount.objects.filter(brand_code=brand_code).select_related("customer")
    text = text.strip().removeprefix("@")
    if text:
        rows = rows.filter(
            Q(ref__icontains=text)
            | Q(label__icontains=text)
            | Q(player_name__icontains=text)
            | Q(customer__full_name__icontains=text)
            | Q(customer__phone__icontains=text)
        )
    if customer_id:
        rows = rows.annotate(
            for_customer=Case(
                When(customer_id=customer_id, then=Value(0)),
                default=Value(1),
                output_field=IntegerField(),
            )
        ).order_by("for_customer", "-last_used_at", "-id")
    found = list(rows[: PAGE + 1])
    return found[:PAGE], len(found) > PAGE


def payload(row) -> dict:
    return {
        "id": row.pk,
        "ref": row.ref,
        "values": row.values,
        "player_name": row.player_name,
        "label": row.label,
        "customer": row.customer_id,
        "customer_name": row.customer.full_name if row.customer_id else "",
        "use_count": row.use_count,
        "last_used_at": row.last_used_at.isoformat(),
    }
