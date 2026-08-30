"""Channel-agnostic send plumbing.

``enqueue_message`` queues a message (idempotent on ``dedup_key``); ``deliver_message``
claims a queued row and pushes it through its gateway's transport. Both are
deliberately consent-agnostic — the CRM layer (apps.crm.consent) gates marketing
*before* calling here, preserving the rule that messaging never imports crm.
"""

from __future__ import annotations

import logging
from datetime import timedelta

from django.db import IntegrityError, transaction
from django.db.models import F
from django.utils import timezone

from .models import (
    DeliveryReceipt,
    InboundMessage,
    MessagingGateway,
    OutboundMessage,
)
from .phone import normalize_phone
from .segments import count_segments
from .transports import SendResult, transport_for

logger = logging.getLogger(__name__)


class NoGatewayConfigured(Exception):
    """Raised when there is no active gateway to send through."""


def enqueue_message(
    *,
    to: str,
    body: str,
    consent_class: str = OutboundMessage.ConsentClass.TRANSACTIONAL,
    gateway: MessagingGateway | None = None,
    dedup_key: str | None = None,
    not_before=None,
    expires_at=None,
    source_type: str = "",
    source_id: str | int = "",
    channel: str = MessagingGateway.Channel.SMS,
    max_attempts: int = 3,
) -> OutboundMessage:
    """Queue one outbound message. Returns the existing row if ``dedup_key`` repeats."""
    if gateway is None:
        gateway = MessagingGateway.default_gateway()
    if gateway is None:
        raise NoGatewayConfigured("no active messaging gateway is configured")

    if dedup_key:
        existing = OutboundMessage.objects.filter(dedup_key=dedup_key).first()
        if existing:
            return existing

    normalized = normalize_phone(to)
    message = OutboundMessage(
        gateway=gateway,
        channel=channel,
        to_phone=normalized,
        to_phone_raw=to or "",
        body=body,
        consent_class=consent_class,
        segments=count_segments(body),
        max_attempts=max_attempts,
        dedup_key=dedup_key or None,
        not_before=not_before,
        expires_at=expires_at,
        source_type=source_type,
        source_id=str(source_id) if source_id not in (None, "") else "",
        status=(
            OutboundMessage.Status.SCHEDULED
            if not_before
            else OutboundMessage.Status.QUEUED
        ),
    )
    if not normalized:
        # Never sendable — record it terminally rather than retrying forever.
        message.status = OutboundMessage.Status.FAILED
        message.error_code = "bad_number"
        message.error_detail = f"unparseable phone: {to!r}"

    try:
        with transaction.atomic():
            message.save()
    except IntegrityError:
        if dedup_key:
            return OutboundMessage.objects.get(dedup_key=dedup_key)
        raise
    return message


def _backoff(attempts: int) -> timedelta:
    return timedelta(seconds=min(300, 30 * (2 ** max(0, attempts - 1))))


def _apply_result(message: OutboundMessage, result: SendResult) -> None:
    now = timezone.now()
    if result.ok:
        message.status = OutboundMessage.Status.SENT
        message.provider_message_id = result.provider_message_id
        message.sent_at = now
        message.error_code = ""
        message.error_detail = ""
        message.save(
            update_fields=[
                "status", "provider_message_id", "sent_at",
                "error_code", "error_detail", "updated_at",
            ]
        )
        _note_gateway_reachable(message.gateway, now=now)
        return

    message.error_code = result.error_code
    message.error_detail = result.error_detail
    if result.retryable and message.attempts < message.max_attempts:
        message.status = OutboundMessage.Status.QUEUED
        message.next_attempt_at = now + _backoff(message.attempts)
    else:
        message.status = OutboundMessage.Status.FAILED
        message.next_attempt_at = None
    message.save(
        update_fields=[
            "status", "error_code", "error_detail", "next_attempt_at", "updated_at",
        ]
    )
    _note_gateway_error(message.gateway, result)


def _note_gateway_error(gateway: MessagingGateway, result: SendResult) -> None:
    MessagingGateway.objects.filter(pk=gateway.pk).update(
        last_error=f"{result.error_code}: {result.error_detail}"[:2000],
        last_error_at=timezone.now(),
    )


def _note_gateway_reachable(gateway: MessagingGateway, *, now=None) -> None:
    """Record a successful round-trip to the device.

    Without this the health fields only ever move in one direction: a single
    failure sets ``last_error`` forever, so the settings page keeps warning about
    a gateway that has been healthy for weeks, and ``last_seen_at`` reflects the
    last *activation* rather than the last time the phone actually answered.
    """
    MessagingGateway.objects.filter(pk=gateway.pk).update(
        last_seen_at=now or timezone.now(),
        last_error="",
        last_error_at=None,
    )


def deliver_message(message: OutboundMessage, *, transport=None) -> OutboundMessage:
    """Claim a queued message and send it. Safe against concurrent workers.

    The claim is an atomic ``queued/scheduled → sending`` filtered UPDATE, so
    two overlapping dispatch runs can never send the same row twice.
    """
    claimed = (
        OutboundMessage.objects.filter(
            pk=message.pk,
            status__in=[OutboundMessage.Status.QUEUED, OutboundMessage.Status.SCHEDULED],
        ).update(
            status=OutboundMessage.Status.SENDING,
            attempts=F("attempts") + 1,
            next_attempt_at=None,
        )
    )
    message.refresh_from_db()
    if not claimed:
        return message  # already handled (or terminal) elsewhere

    if transport is None:
        transport = transport_for(message.gateway)
    try:
        result = transport.send(
            to=message.to_phone, body=message.body, message=message
        )
    except Exception as exc:  # a driver bug must not wedge the message in "sending"
        logger.exception("messaging transport crashed for message %s", message.pk)
        result = SendResult(
            ok=False, status="failed", error_code="driver_error",
            error_detail=str(exc)[:500], retryable=True,
        )
    _apply_result(message, result)
    return message


def record_inbound(
    gateway: MessagingGateway,
    *,
    from_phone: str,
    body: str,
    provider_message_id: str = "",
    received_at=None,
    channel: str = "",
) -> tuple[InboundMessage, bool]:
    """Persist an inbound message, idempotent on ``(gateway, provider_message_id)``.

    Returns ``(message, created)``; a repeat provider id returns the first row.
    """
    if provider_message_id:
        existing = InboundMessage.objects.filter(
            gateway=gateway, provider_message_id=provider_message_id
        ).first()
        if existing:
            return existing, False
    message = InboundMessage.objects.create(
        gateway=gateway,
        channel=channel or gateway.channel,
        from_phone=normalize_phone(from_phone),
        from_phone_raw=from_phone or "",
        body=body or "",
        provider_message_id=provider_message_id or "",
        received_at=received_at or timezone.now(),
    )
    return message, True


_DELIVERED_STATES = {"delivered", "sent_delivered", "delivery_success"}
_FAILED_STATES = {"failed", "undelivered", "error", "delivery_failed"}


def apply_receipt(
    gateway: MessagingGateway,
    *,
    provider_message_id: str,
    status: str,
    raw: dict | None = None,
) -> DeliveryReceipt:
    """Record a delivery receipt and advance the matching OutboundMessage.

    Best-effort: ``sent`` is already terminal-success for UX, so ``delivered`` is
    an upgrade and a ``failed`` receipt only downgrades a not-yet-terminal row.
    """
    outbound = None
    if provider_message_id:
        outbound = (
            OutboundMessage.objects.filter(
                gateway=gateway, provider_message_id=provider_message_id
            )
            .order_by("-created_at")
            .first()
        )
    receipt = DeliveryReceipt.objects.create(
        gateway=gateway,
        outbound=outbound,
        provider_message_id=provider_message_id or "",
        status=status or "",
        raw=raw or {},
        received_at=timezone.now(),
    )
    if outbound is not None:
        _advance_from_receipt(outbound, status)
    return receipt


def _advance_from_receipt(outbound: OutboundMessage, status: str) -> None:
    state = (status or "").strip().lower()
    now = timezone.now()
    advanceable = {
        OutboundMessage.Status.SENT,
        OutboundMessage.Status.SENDING,
        OutboundMessage.Status.QUEUED,
    }
    if state in _DELIVERED_STATES and outbound.status in advanceable:
        outbound.status = OutboundMessage.Status.DELIVERED
        outbound.delivered_at = now
        outbound.save(update_fields=["status", "delivered_at", "updated_at"])
    elif state in _FAILED_STATES and outbound.status in {
        OutboundMessage.Status.SENT,
        OutboundMessage.Status.SENDING,
    }:
        outbound.status = OutboundMessage.Status.FAILED
        outbound.error_code = outbound.error_code or "delivery_failed"
        outbound.save(update_fields=["status", "error_code", "updated_at"])
