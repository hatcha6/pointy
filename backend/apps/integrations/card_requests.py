"""What a till shows of the company's cards it sold: the requests panel.

A card from a slow supplier takes minutes to arrive, and a cashier cannot stand
looking at a spinner for that long. So the sale is recorded, the request goes
out, and the cashier carries on selling while a panel follows it. This module
reads those requests for the panel and settles them on demand, by the same
read-back the two-minute sweep uses (:func:`.reconciliation.settle_attempts`).
"""

from __future__ import annotations

from datetime import timedelta

from django.core.cache import cache
from django.utils import timezone

from apps.core.roles import user_has_full_visibility

from . import catalog, switches
from .fulfillment import fulfillment_kind
from .models import IntegrationAccount, IntegrationFulfillment
from .providers import provider_for
from .providers.base import DETAIL_IN_PROGRESS, without_figures
from .reconciliation import settle_attempts
from .redeem import printed_receipt

#: How far back the panel looks, and how much of it: a glance, not a report.
LOOKBACK = timedelta(days=7)
PAGE = 50
#: The most lines one settle reads back from the relay, one at a time.
SETTLE_LIMIT = 12
#: One line is read from the relay at most this often, however many tills ask.
READ_EVERY_SECONDS = 3
#: An order still open after this long is said to be late. Never "failed": only
#: the relay's word can end it, and a second sale would pay twice.
LATE_AFTER = timedelta(minutes=15)

STATE_QUEUED = "queued"
STATE_WORKING = "working"
STATE_SUCCEEDED = "succeeded"
STATE_FAILED = "failed"
STATE_CANCELLED = "cancelled"

_STATES = {
    IntegrationFulfillment.Status.PENDING: STATE_QUEUED,
    IntegrationFulfillment.Status.SUBMITTED: STATE_WORKING,
    IntegrationFulfillment.Status.CONFIRMED: STATE_SUCCEEDED,
    IntegrationFulfillment.Status.FAILED: STATE_FAILED,
    IntegrationFulfillment.Status.CANCELLED: STATE_CANCELLED,
}


def _visible(user):
    """The requests this user follows: the reporting roles all of them, a cashier
    what went through their own drawer (who a sale belongs to, as on the invoice)."""
    relay_keys = [spec.key for spec in catalog.PROVIDERS if spec.relay_hosted]
    rows = IntegrationFulfillment.objects.filter(provider__in=relay_keys)
    if not user_has_full_visibility(user):
        rows = rows.filter(order_line__order__register_session__owner=user)
    return rows.select_related("order_line__order", "order_line__order__customer").prefetch_related(
        "order_line__adjustment_lines"
    )


def recent(user, *, now=None) -> list[dict]:
    """The latest requests, for the panel as a till opens."""
    now = now or timezone.now()
    with_cost = user_has_full_visibility(user)
    rows = _visible(user).filter(created_at__gte=now - LOOKBACK).order_by("-created_at", "-pk")
    return [payload(row, with_cost=with_cost, now=now) for row in rows[:PAGE]]


def settle(user, line_ids, *, now=None) -> list[dict]:
    """Read the still-open requests among ``line_ids`` back, and answer all of them."""
    now = now or timezone.now()
    line_ids = list(line_ids)[:PAGE]
    visible = _visible(user).filter(order_line_id__in=line_ids)
    sent = [
        row
        for row in visible.filter(status=IntegrationFulfillment.Status.SUBMITTED)
        .order_by("created_at")[:SETTLE_LIMIT]
        if cache.add(f"card_request_read:{row.pk}", 1, READ_EVERY_SECONDS)
    ]
    accounts = {row.account_id for row in sent}
    if accounts:
        for account in switches.running(IntegrationAccount.objects.filter(pk__in=accounts)):
            if account.is_configured:
                settle_attempts(
                    provider_for(account),
                    [row for row in sent if row.account_id == account.pk],
                    now=now,
                )
    with_cost = user_has_full_visibility(user)
    # Read again: the settle wrote through its own rows.
    return [
        payload(row, with_cost=with_cost, now=now)
        for row in _visible(user).filter(order_line_id__in=line_ids).order_by("-created_at", "-pk")
    ]


def _refund(row):
    """What was given back for the line because it was not delivered; ``None``
    when nothing was (a credit sale, a drawer already closed)."""
    from apps.sales.services import line_refund_amount

    line = row.order_line
    if row.status != IntegrationFulfillment.Status.FAILED or not list(line.adjustment_lines.all()):
        return None
    return line_refund_amount(line, line.quantity)


def payload(row, *, with_cost: bool, now) -> dict:
    line = row.order_line
    order = line.order
    state = _STATES.get(row.status, STATE_WORKING)
    finished = {
        STATE_SUCCEEDED: row.confirmed_at or row.updated_at,
        STATE_FAILED: row.updated_at,
        STATE_CANCELLED: row.updated_at,
    }.get(state)
    refund = _refund(row)
    return {
        "fulfillment": row.pk,
        "order_line": row.order_line_id,
        "order": order.pk,
        "receipt_number": order.receipt_number or "",
        "customer_name": order.customer.full_name if order.customer_id else "",
        "brand": row.package_id,
        "brand_name": row.package_name,
        "label": row.option_label,
        "kind": fulfillment_kind(row),
        "account": row.subscriber_ref,
        "account_name": row.account_name,
        "state": state,
        # The relay took it and is working on it, as opposed to an answer lost.
        "in_progress": state == STATE_WORKING and row.last_error == DETAIL_IN_PROGRESS,
        "late": state == STATE_WORKING and row.created_at <= now - LATE_AFTER,
        "amount": line.line_total,
        "created_at": row.created_at.isoformat(),
        "finished_at": finished.isoformat() if finished else None,
        "error_code": row.last_error_code if state == STATE_FAILED else "",
        "error_detail": (
            (row.last_error if with_cost else without_figures(row.last_error))
            if state == STATE_FAILED
            else ""
        ),
        "receipt": printed_receipt(row) if state == STATE_SUCCEEDED else {},
        "refunded": refund is not None,
        "refund_amount": refund,
    }
