from __future__ import annotations

from django.db import models
from django.db.models import Q

from apps.core.models import TimeStampedModel

from .secrets import decrypt_secrets, encrypt_secrets


class MessagingGateway(TimeStampedModel):
    """A configured way to send/receive messages — one per SIM/phone/provider.

    ``provider`` selects the transport driver (see apps.messaging.transports);
    ``config`` holds non-secret connection details; the ``max_messages_per_minute``
    etc. fields hold the deliverability policy that paces a single consumer SIM.
    Credentials (the SMS Gate password, the inbound webhook signing key) live
    encrypted in ``secrets_encrypted`` and are never serialized back out.
    """

    class Provider(models.TextChoices):
        SMS_GATE = "sms_gate", "SMS Gate (Android)"
        FAKE = "fake", "Fake (testing)"

    class Channel(models.TextChoices):
        SMS = "sms", "SMS"

    name = models.CharField(max_length=120, unique=True)
    provider = models.CharField(
        max_length=32, choices=Provider.choices, default=Provider.SMS_GATE
    )
    channel = models.CharField(
        max_length=16, choices=Channel.choices, default=Channel.SMS
    )
    config = models.JSONField(default=dict, blank=True)
    secrets_encrypted = models.TextField(blank=True, editable=False)

    is_default = models.BooleanField(default=False)
    is_active = models.BooleanField(default=True)

    # Deliverability policy — a single SIM is the bottleneck (see the plan §7).
    max_messages_per_minute = models.PositiveIntegerField(default=6)
    daily_cap = models.PositiveIntegerField(default=0)  # 0 = unlimited
    quiet_hours_start = models.TimeField(blank=True, null=True)
    quiet_hours_end = models.TimeField(blank=True, null=True)
    send_timeout_seconds = models.PositiveIntegerField(default=15)

    # Health / observability.
    last_seen_at = models.DateTimeField(blank=True, null=True)
    last_error = models.TextField(blank=True)
    last_error_at = models.DateTimeField(blank=True, null=True)

    class Meta:
        ordering = ["name"]
        permissions = [
            ("manage_gateways", "Can configure messaging gateways and send tests"),
            ("view_logs", "Can view messaging send/receive logs"),
        ]
        constraints = [
            models.UniqueConstraint(
                fields=["is_default"],
                condition=Q(is_default=True),
                name="unique_default_messaging_gateway",
            )
        ]

    def __str__(self) -> str:
        return self.name

    def save(self, *args, **kwargs):
        # Exactly one default at a time (mirrors PrinterProfile).
        if self.is_default:
            MessagingGateway.objects.exclude(pk=self.pk).filter(
                is_default=True
            ).update(is_default=False)
        super().save(*args, **kwargs)

    # --- secret storage -----------------------------------------------------
    def get_secret(self, key: str, default: str = "") -> str:
        return decrypt_secrets(self.secrets_encrypted).get(key, default)

    def set_secret(self, key: str, value: str | None) -> None:
        data = decrypt_secrets(self.secrets_encrypted)
        if value in (None, ""):
            data.pop(key, None)
        else:
            data[key] = value
        self.secrets_encrypted = encrypt_secrets(data)

    def has_secret(self, key: str) -> bool:
        return bool(decrypt_secrets(self.secrets_encrypted).get(key))

    @classmethod
    def default_gateway(cls) -> "MessagingGateway | None":
        active = cls.objects.filter(is_active=True)
        return active.filter(is_default=True).first() or active.order_by("created_at").first()


class OutboundMessage(TimeStampedModel):
    """A single queued/sent message. The queue + state machine the pacer drains."""

    class ConsentClass(models.TextChoices):
        TRANSACTIONAL = "transactional", "Transactional"
        MARKETING = "marketing", "Marketing"

    class Status(models.TextChoices):
        QUEUED = "queued", "Queued"
        SCHEDULED = "scheduled", "Scheduled"
        SENDING = "sending", "Sending"
        SENT = "sent", "Sent"
        DELIVERED = "delivered", "Delivered"
        FAILED = "failed", "Failed"
        CANCELLED = "cancelled", "Cancelled"
        BLOCKED_CONSENT = "blocked_consent", "Blocked (consent)"
        EXPIRED = "expired", "Expired"

    gateway = models.ForeignKey(
        MessagingGateway, on_delete=models.PROTECT, related_name="outbound_messages"
    )
    channel = models.CharField(max_length=16, default=MessagingGateway.Channel.SMS)
    to_phone = models.CharField(max_length=32, db_index=True)  # normalized E.164
    to_phone_raw = models.CharField(max_length=64, blank=True)
    body = models.TextField()
    consent_class = models.CharField(
        max_length=16, choices=ConsentClass.choices, default=ConsentClass.TRANSACTIONAL
    )
    status = models.CharField(
        max_length=20, choices=Status.choices, default=Status.QUEUED, db_index=True
    )
    segments = models.PositiveSmallIntegerField(default=1)

    provider_message_id = models.CharField(max_length=128, blank=True, db_index=True)
    attempts = models.PositiveSmallIntegerField(default=0)
    max_attempts = models.PositiveSmallIntegerField(default=3)
    next_attempt_at = models.DateTimeField(blank=True, null=True)
    not_before = models.DateTimeField(blank=True, null=True)  # quiet-hours / drip
    expires_at = models.DateTimeField(blank=True, null=True)

    # Idempotency: a second enqueue with the same key returns the first row.
    dedup_key = models.CharField(max_length=180, blank=True, null=True, unique=True)
    error_code = models.CharField(max_length=48, blank=True)
    error_detail = models.TextField(blank=True)

    # Where this came from (invoice | debt_reminder | campaign_recipient | reply | ...).
    source_type = models.CharField(max_length=40, blank=True)
    source_id = models.CharField(max_length=64, blank=True)

    sent_at = models.DateTimeField(blank=True, null=True)
    delivered_at = models.DateTimeField(blank=True, null=True)

    class Meta:
        ordering = ["-created_at"]
        indexes = [
            models.Index(fields=["status", "next_attempt_at"]),
            models.Index(fields=["gateway", "status"]),
            models.Index(fields=["source_type", "source_id"]),
        ]

    def __str__(self) -> str:
        return f"{self.to_phone} [{self.status}]"

    @property
    def is_terminal(self) -> bool:
        return self.status in {
            self.Status.SENT,
            self.Status.DELIVERED,
            self.Status.FAILED,
            self.Status.CANCELLED,
            self.Status.BLOCKED_CONSENT,
            self.Status.EXPIRED,
        }


class InboundMessage(TimeStampedModel):
    """A raw message received from a gateway's device. Kept deliberately free of
    CRM meaning — the customer/conversation link lives on apps.crm, so messaging
    never imports crm. Routing (threading, consent/staff commands) is triggered
    by a Celery task dispatched by name after this row is created.
    """

    class HandledAs(models.TextChoices):
        UNHANDLED = "", "Unhandled"
        CONVERSATION = "conversation", "Conversation"
        CONSENT_COMMAND = "consent_command", "Consent command"
        STAFF_COMMAND = "staff_command", "Staff command"
        IGNORED = "ignored", "Ignored"

    gateway = models.ForeignKey(
        MessagingGateway, on_delete=models.CASCADE, related_name="inbound_messages"
    )
    channel = models.CharField(max_length=16, default=MessagingGateway.Channel.SMS)
    from_phone = models.CharField(max_length=32, db_index=True)  # normalized E.164
    from_phone_raw = models.CharField(max_length=64, blank=True)
    body = models.TextField(blank=True)
    provider_message_id = models.CharField(max_length=128, blank=True)
    received_at = models.DateTimeField(blank=True, null=True)
    handled = models.BooleanField(default=False)
    handled_as = models.CharField(
        max_length=20, choices=HandledAs.choices, blank=True, default=HandledAs.UNHANDLED
    )

    class Meta:
        ordering = ["-created_at"]
        constraints = [
            # Inbound idempotency: a re-POST of the same provider id is a no-op.
            models.UniqueConstraint(
                fields=["gateway", "provider_message_id"],
                condition=~Q(provider_message_id=""),
                name="unique_inbound_per_gateway_provider_id",
            )
        ]
        indexes = [models.Index(fields=["from_phone", "-created_at"])]

    def __str__(self) -> str:
        return f"{self.from_phone}: {self.body[:32]}"


class DeliveryReceipt(TimeStampedModel):
    """Append-only log of delivery-status callbacks from a gateway."""

    gateway = models.ForeignKey(
        MessagingGateway, on_delete=models.CASCADE, related_name="delivery_receipts"
    )
    outbound = models.ForeignKey(
        OutboundMessage,
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="receipts",
    )
    provider_message_id = models.CharField(max_length=128, blank=True, db_index=True)
    status = models.CharField(max_length=32, blank=True)
    raw = models.JSONField(default=dict, blank=True)
    received_at = models.DateTimeField(blank=True, null=True)

    class Meta:
        ordering = ["-created_at"]

    def __str__(self) -> str:
        return f"{self.provider_message_id} -> {self.status}"
