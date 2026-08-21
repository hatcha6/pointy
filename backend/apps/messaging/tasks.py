"""Celery tasks that pace the outbound queue.

``dispatch_outbound`` runs every ~10s: for each active gateway it drains due
messages up to the per-minute throttle and daily cap, holding marketing during
quiet hours. ``sweep_stuck`` reconciles rows wedged in ``sending`` and expires
stale ones. Sending itself (and the atomic claim) lives in ``services.deliver_message``.
"""

from __future__ import annotations

import logging
from datetime import timedelta

from celery import shared_task
from django.db.models import Q
from django.utils import timezone

from .models import MessagingGateway, OutboundMessage
from .quiet_hours import in_quiet_hours
from .ratelimit import note_sent, take_minute_slot, within_daily_cap
from .services import deliver_message
from .transports import UnknownProvider, transport_for

logger = logging.getLogger(__name__)

_DISPATCH_BATCH = 50
_STUCK_AFTER_MINUTES = 10


@shared_task(
    name="messaging.dispatch_outbound",
    autoretry_for=(Exception,),
    retry_backoff=True,
    retry_kwargs={"max_retries": 2},
)
def dispatch_outbound_task():
    now = timezone.now()
    sent = 0
    for gateway in MessagingGateway.objects.filter(is_active=True):
        try:
            transport = transport_for(gateway)
        except UnknownProvider:
            logger.warning("gateway %s has unknown provider %s", gateway.pk, gateway.provider)
            continue
        if not within_daily_cap(gateway, now=now):
            continue
        due_qs = (
            OutboundMessage.objects.filter(
                gateway=gateway,
                status__in=[OutboundMessage.Status.QUEUED, OutboundMessage.Status.SCHEDULED],
            )
            .filter(Q(next_attempt_at__isnull=True) | Q(next_attempt_at__lte=now))
            .filter(Q(not_before__isnull=True) | Q(not_before__lte=now))
        )
        if in_quiet_hours(gateway, now):
            # Hold marketing out of the *batch*, not just out of the send: a
            # campaign larger than _DISPATCH_BATCH would otherwise fill every
            # tick's batch for the whole window and starve the transactional
            # messages queued behind it — the very messages quiet hours exempts.
            due_qs = due_qs.exclude(consent_class=OutboundMessage.ConsentClass.MARKETING)
        due = list(due_qs.order_by("created_at")[:_DISPATCH_BATCH])
        for message in due:
            if message.expires_at and message.expires_at <= now:
                _expire(message)
                continue
            if not within_daily_cap(gateway, now=now):
                break
            if not take_minute_slot(gateway, now=now):
                break  # minute full — leave the rest for the next tick
            deliver_message(message, transport=transport)
            if message.status == OutboundMessage.Status.SENT:
                note_sent(gateway, now=now)
                sent += 1
    return {"sent": sent}


@shared_task(name="messaging.sweep_stuck", autoretry_for=(Exception,), retry_backoff=True)
def sweep_stuck_task():
    now = timezone.now()
    stuck_before = now - timedelta(minutes=_STUCK_AFTER_MINUTES)
    requeued = OutboundMessage.objects.filter(
        status=OutboundMessage.Status.SENDING, updated_at__lte=stuck_before
    ).update(status=OutboundMessage.Status.QUEUED, next_attempt_at=now)
    expired = OutboundMessage.objects.filter(
        status__in=[OutboundMessage.Status.QUEUED, OutboundMessage.Status.SCHEDULED],
        expires_at__lte=now,
    ).update(status=OutboundMessage.Status.EXPIRED)
    return {"requeued": requeued, "expired": expired}


def _expire(message: OutboundMessage) -> None:
    message.status = OutboundMessage.Status.EXPIRED
    message.save(update_fields=["status", "updated_at"])
