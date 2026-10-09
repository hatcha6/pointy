"""Channel-agnostic send plumbing.

``enqueue_message`` queues a message (idempotent on ``dedup_key``); ``deliver_message``
claims a queued row and pushes it through its gateway's transport. Both are
deliberately consent-agnostic — the CRM layer (apps.crm.consent) gates marketing
*before* calling here, preserving the rule that messaging never imports crm.

Messages are built from approved templates (``apps.messaging.sms_templates``):
the SMS provider delivers nothing else, so ``template=sms_template(kind, ...)``
is how every sender says what to send.
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
from .approvals import TEMPLATE_REFUSAL_CODES, note_kind_unapproved
from .phone import normalize_phone
from .segments import count_segments
from .sms_templates import SmsTemplate
from .transports import UNCERTAIN_FAILURE_CODES, SendResult, UnknownProvider, transport_for

logger = logging.getLogger(__name__)

# A message that has waited this long for an unreachable provider is given up
# on: an invoice SMS a day late is noise, and the queue must not grow forever.
_DEFER_HORIZON = timedelta(hours=24)

# Terminal states in which the customer received nothing. A dedup key held by
# one of these does not stop a fresh attempt.
_NEVER_REACHED = {
    OutboundMessage.Status.FAILED,
    OutboundMessage.Status.EXPIRED,
    OutboundMessage.Status.CANCELLED,
}


class NoGatewayConfigured(Exception):
    """Raised when nothing can be sent: no gateway, SMS switched off by the
    shop, an SMS balance that cannot pay for a message, or no SMS at all.

    ``code`` says which (``no_gateway`` | ``service_disabled`` |
    ``insufficient_balance`` | ``not_entitled``) so a view can tell the user
    what to do about it.
    """

    def __init__(self, message: str = "", *, code: str = "no_gateway"):
        super().__init__(message or code)
        self.code = code


_UNAVAILABLE_MESSAGES = {
    "insufficient_balance": "رصيد الرسائل لا يكفي لهذه الرسالة. حوّل مبلغاً من المحفظة إلى رصيد الرسائل من صفحة الاشتراك.",
    "not_entitled": "خدمة الرسائل غير متاحة لهذا المحل بعد. تواصل مع الدعم.",
    "service_disabled": "خدمة الرسائل موقوفة من إعدادات الرسائل في المحل.",
    "no_gateway": "خدمة الرسائل غير متاحة حاليًا.",
}


def unavailable_message(exc: NoGatewayConfigured) -> str:
    """The Arabic sentence a view shows when a send could not even be queued."""
    return _UNAVAILABLE_MESSAGES.get(exc.code, _UNAVAILABLE_MESSAGES["no_gateway"])


def _sending_gateway(gateway: MessagingGateway | None) -> MessagingGateway:
    if gateway is None:
        gateway = MessagingGateway.default_gateway()
    if gateway is None:
        if MessagingGateway.objects.filter(provider=MessagingGateway.Provider.RELAY).exists():
            raise NoGatewayConfigured(
                "SMS is switched off for this shop", code="service_disabled"
            )
        raise NoGatewayConfigured("no active messaging gateway is configured")
    if not gateway.is_active:
        raise NoGatewayConfigured(
            f"gateway {gateway.pk} is switched off", code="service_disabled"
        )
    try:
        reason = transport_for(gateway).unavailable_reason()
    except UnknownProvider:
        raise NoGatewayConfigured(
            f"gateway {gateway.pk} has no driver for {gateway.provider!r}"
        ) from None
    if reason:
        raise NoGatewayConfigured(f"gateway {gateway.pk}: {reason}", code=reason)
    return gateway


def enqueue_message(
    *,
    to: str,
    body: str = "",
    template: SmsTemplate | None = None,
    consent_class: str | None = None,
    gateway: MessagingGateway | None = None,
    dedup_key: str | None = None,
    not_before=None,
    expires_at=None,
    source_type: str = "",
    source_id: str | int = "",
    channel: str = MessagingGateway.Channel.SMS,
    max_attempts: int = 3,
) -> OutboundMessage:
    """Queue one outbound message. Returns the existing row if ``dedup_key`` repeats.

    Pass ``template`` (``sms_template(kind, *values)``); ``body`` then defaults to
    its rendering and ``consent_class`` to the template's own. A bare ``body`` is
    still accepted for a gateway that sends free text, and is recorded as failed
    (``template_required``) on one that cannot.

    Raises ``NoGatewayConfigured`` when nothing can be sent at all — no gateway,
    SMS switched off, or not in the shop's subscription — or when the SMS
    balance cannot pay for this message's parts, so callers that treat SMS as
    best-effort simply carry on.
    """
    gateway = _sending_gateway(gateway)

    if dedup_key:
        existing = OutboundMessage.objects.filter(dedup_key=dedup_key).first()
        if existing and existing.status not in _NEVER_REACHED:
            return existing
        if existing:
            # The earlier attempt never reached anyone — the template was not
            # approved yet, the month's allowance was spent. The key exists to
            # stop a second copy, and there is no first copy: release it so
            # "send again" actually sends.
            OutboundMessage.objects.filter(pk=existing.pk).update(dedup_key=None)

    if template is not None:
        body = body or template.render()
        if consent_class is None:
            consent_class = template.consent_class
    if consent_class is None:
        consent_class = OutboundMessage.ConsentClass.TRANSACTIONAL

    normalized = normalize_phone(to)
    segments = count_segments(body)
    message = OutboundMessage(
        gateway=gateway,
        channel=channel,
        to_phone=normalized,
        to_phone_raw=to or "",
        body=body,
        template_kind=template.kind if template is not None else "",
        template_values=list(template.values) if template is not None else [],
        consent_class=consent_class,
        segments=segments,
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
    elif template is None and transport_for(gateway).requires_template:
        # A sender that was never taught a template kind. Visible in the log as
        # what it is, instead of going out as free text the provider rejects.
        message.status = OutboundMessage.Status.FAILED
        message.error_code = "template_required"
        message.error_detail = "the SMS provider only delivers approved templates"
    else:
        # Paid per SMS part: a balance that covers a short message may not
        # cover this one. Better said at the button than as a failed message.
        reason = transport_for(gateway).unaffordable_reason(segments)
        if reason:
            raise NoGatewayConfigured(
                f"gateway {gateway.pk}: {reason} for {segments} part(s)", code=reason
            )

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
        fields = [
            "status", "provider_message_id", "sent_at",
            "error_code", "error_detail", "updated_at",
        ]
        if result.sent_body and result.sent_body != message.body:
            message.body = result.sent_body
            message.segments = count_segments(result.sent_body)
            fields += ["body", "segments"]
        if result.segments and result.segments != message.segments:
            # What the provider billed it as is what it cost.
            message.segments = result.segments
            if "segments" not in fields:
                fields.append("segments")
        message.save(update_fields=fields)
        _note_gateway_reachable(message.gateway, now=now)
        return

    if result.defer and now - message.created_at < _DEFER_HORIZON:
        # The provider was out of reach or busy — nothing is wrong with the
        # message, so the attempt the claim took is handed back.
        message.status = OutboundMessage.Status.QUEUED
        message.attempts = max(0, message.attempts - 1)
        message.next_attempt_at = now + timedelta(
            seconds=result.retry_after_seconds or 60
        )
        message.error_code = result.error_code
        message.error_detail = result.error_detail
        message.save(
            update_fields=[
                "status", "attempts", "next_attempt_at",
                "error_code", "error_detail", "updated_at",
            ]
        )
        _note_gateway_error(message.gateway, result)
        return

    message.error_code = result.error_code
    message.error_detail = result.error_detail
    fields = ["status", "error_code", "error_detail", "next_attempt_at", "updated_at"]
    if result.provider_message_id:
        # A failure that may still have gone out keeps the provider's id, so
        # the delivery poll can learn that it did.
        message.provider_message_id = result.provider_message_id
        fields.append("provider_message_id")
    # A deferral that reaches here has waited out the whole horizon: give up
    # rather than spend the ordinary retries on a provider that never came back.
    if result.retryable and not result.defer and message.attempts < message.max_attempts:
        message.status = OutboundMessage.Status.QUEUED
        message.next_attempt_at = now + _backoff(message.attempts)
    else:
        message.status = OutboundMessage.Status.FAILED
        message.next_attempt_at = None
    message.save(update_fields=fields)
    if result.error_code in TEMPLATE_REFUSAL_CODES:
        # One kind waiting for its template, not a gateway in trouble: the
        # settings page lists that kind as not approved yet.
        note_kind_unapproved(message.template_kind)
        return
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
        try:
            transport = transport_for(message.gateway)
        except UnknownProvider:
            # A gateway left over from a provider this build no longer ships.
            _apply_result(
                message,
                SendResult(
                    ok=False, status="failed", error_code="driver_error",
                    error_detail=f"no driver for {message.gateway.provider!r}",
                    retryable=False,
                ),
            )
            return message
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


# How far back a delivery poll looks. The provider settles a message's fate
# within minutes; one still unsettled after two days never will be.
_DELIVERY_WINDOW = timedelta(hours=48)
_DELIVERY_BATCH = 500

def sync_delivery_statuses(gateway: MessagingGateway, *, transport=None, now=None) -> int:
    """Ask the gateway's provider what became of recently sent messages.

    The relay learns delivery from Resala's log rather than being called back,
    so this is the receipt webhook turned around: poll, then record each answer
    as a ``DeliveryReceipt`` exactly as a pushed one would be. It also asks
    after sends that failed in doubt, which the relay may yet find went out.
    Returns how many messages it advanced.
    """
    now = now or timezone.now()
    since = now - _DELIVERY_WINDOW
    candidates = list(
        OutboundMessage.objects.filter(
            gateway=gateway,
            status=OutboundMessage.Status.SENT,
            sent_at__gte=since,
        )
        .exclude(provider_message_id="")
        .order_by("-sent_at")[:_DELIVERY_BATCH]
    )
    candidates += list(
        OutboundMessage.objects.filter(
            gateway=gateway,
            status=OutboundMessage.Status.FAILED,
            error_code__in=UNCERTAIN_FAILURE_CODES,
            created_at__gte=since,
        )
        .exclude(provider_message_id="")
        .order_by("-created_at")[:_DELIVERY_BATCH]
    )
    if not candidates:
        return 0
    if transport is None:
        transport = transport_for(gateway)
    by_pk = {message.pk: message for message in candidates}
    applied = 0
    for pk, status in transport.delivery_statuses(candidates).items():
        message = by_pk.get(pk)
        if message is None:
            continue
        if message.status == OutboundMessage.Status.FAILED:
            applied += _recover_doubtful_send(gateway, message, status, now=now)
            continue
        if (status or "").strip().lower() == "sent":
            continue  # still on its way: nothing new to record
        apply_receipt(
            gateway,
            provider_message_id=message.provider_message_id,
            status=status,
            raw={"source": "poll", "status": status},
        )
        applied += 1
    return applied


def _recover_doubtful_send(gateway, message: OutboundMessage, status: str, *, now) -> int:
    """A send that failed in doubt went out after all: the relay found it in
    Resala's sent log and kept its price. Record what it became — sent,
    delivered, or out but never delivered. Any other answer leaves it failed:
    not found (refunded), or still being checked."""
    state = (status or "").strip().lower()
    if state not in {"sent", "delivered", "undelivered"}:
        return 0
    message.sent_at = message.sent_at or now
    message.error_detail = ""
    fields = ["sent_at", "error_code", "error_detail", "updated_at"]
    if state == "undelivered":
        message.error_code = "delivery_failed"
    else:
        message.error_code = ""
        message.status = (
            OutboundMessage.Status.DELIVERED if state == "delivered" else OutboundMessage.Status.SENT
        )
        fields.append("status")
        if state == "delivered":
            message.delivered_at = now
            fields.append("delivered_at")
    message.save(update_fields=fields)
    DeliveryReceipt.objects.create(
        gateway=gateway,
        outbound=message,
        provider_message_id=message.provider_message_id,
        status=state,
        raw={"source": "poll", "status": state, "recovered": True},
        received_at=now,
    )
    return 1


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
