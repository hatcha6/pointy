from __future__ import annotations

from django.conf import settings
from django.db import models
from django.db.models import Q

from apps.core.models import TimeStampedModel


class Conversation(TimeStampedModel):
    """A two-way SMS thread with one phone number (and, once known, a customer).

    Keyed on the normalized phone; at most one thread per number may be OPEN at a
    time, so replies always land in the right place.
    """

    class Status(models.TextChoices):
        OPEN = "open", "Open"
        CLOSED = "closed", "Closed"

    customer = models.ForeignKey(
        "customers.Customer",
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="conversations",
    )
    phone = models.CharField(max_length=32, db_index=True)  # normalized E.164
    phone_raw = models.CharField(max_length=64, blank=True)
    status = models.CharField(
        max_length=12, choices=Status.choices, default=Status.OPEN
    )
    last_message_at = models.DateTimeField(blank=True, null=True)
    last_inbound_at = models.DateTimeField(blank=True, null=True)
    unread_count = models.PositiveIntegerField(default=0)
    assigned_to = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="assigned_conversations",
    )

    class Meta:
        ordering = ["-last_message_at", "-created_at"]
        permissions = [
            ("view_conversations", "Can view customer conversations"),
            ("manage_conversations", "Can reply to and manage conversations"),
        ]
        constraints = [
            models.UniqueConstraint(
                fields=["phone"],
                condition=Q(status="open"),
                name="unique_open_conversation_per_phone",
            )
        ]
        indexes = [models.Index(fields=["status", "-last_message_at"])]

    def __str__(self) -> str:
        return self.phone


class ConversationMessage(TimeStampedModel):
    class Direction(models.TextChoices):
        IN = "in", "Inbound"
        OUT = "out", "Outbound"

    conversation = models.ForeignKey(
        Conversation, on_delete=models.CASCADE, related_name="messages"
    )
    direction = models.CharField(max_length=4, choices=Direction.choices)
    body = models.TextField(blank=True)
    outbound = models.ForeignKey(
        "messaging.OutboundMessage",
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="conversation_messages",
    )
    inbound = models.ForeignKey(
        "messaging.InboundMessage",
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="conversation_messages",
    )
    author = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
    )

    class Meta:
        ordering = ["created_at"]

    def __str__(self) -> str:
        return f"{self.direction}: {self.body[:32]}"


class ConsentEvent(TimeStampedModel):
    """Append-only ledger of every change to a customer's contact consent — who
    changed it and why (an SMS STOP, a staff toggle, an import). The current
    state lives on Customer; this is the audit trail.
    """

    class Action(models.TextChoices):
        OPT_OUT = "opt_out", "Opted out of marketing"
        OPT_IN = "opt_in", "Opted in to marketing"
        DO_NOT_CONTACT = "do_not_contact", "Do not contact"
        ALLOW_CONTACT = "allow_contact", "Contact allowed"

    class Source(models.TextChoices):
        SMS_COMMAND = "sms_command", "SMS command"
        STAFF = "staff", "Staff"
        ADMIN_UI = "admin_ui", "Admin UI"
        IMPORT = "import", "Import"

    customer = models.ForeignKey(
        "customers.Customer",
        on_delete=models.CASCADE,
        related_name="consent_events",
    )
    phone = models.CharField(max_length=32, blank=True)
    action = models.CharField(max_length=20, choices=Action.choices)
    channel = models.CharField(max_length=16, blank=True, default="sms")
    source = models.CharField(max_length=16, choices=Source.choices)
    inbound = models.ForeignKey(
        "messaging.InboundMessage",
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
    )
    note = models.TextField(blank=True)

    class Meta:
        ordering = ["-created_at"]
        permissions = [
            ("manage_consent", "Can manage customer contact consent"),
        ]

    def __str__(self) -> str:
        return f"{self.phone} {self.action}"


class Campaign(TimeStampedModel):
    """A marketing SMS blast with a draft → approve → send lifecycle.

    Status is server-controlled (never set through the serializer), so a
    create/update can only ever produce a ``draft`` — the AI can draft but never
    send. Sending happens only through the ``send`` action, gated by the
    human-only ``crm.send_campaigns`` permission.
    """

    class Status(models.TextChoices):
        DRAFT = "draft", "Draft"
        PENDING_APPROVAL = "pending_approval", "Pending approval"
        APPROVED = "approved", "Approved"
        SENDING = "sending", "Sending"
        SENT = "sent", "Sent"
        CANCELLED = "cancelled", "Cancelled"
        FAILED = "failed", "Failed"

    class CreatedVia(models.TextChoices):
        HUMAN = "human", "Human"
        AI = "ai", "AI"

    name = models.CharField(max_length=120)
    body_template = models.TextField()
    channel = models.CharField(max_length=16, default="sms")
    status = models.CharField(
        max_length=20, choices=Status.choices, default=Status.DRAFT, db_index=True
    )

    # Audience: any of RFM segments, an explicit customer set, or a discount rule
    # (whose own targeting is folded in). Empty = every active customer with a
    # phone (a full blast — the count is shown before approval).
    rfm_segments = models.JSONField(default=list, blank=True)
    customers = models.ManyToManyField(
        "customers.Customer", related_name="campaigns", blank=True
    )
    discount_rule = models.ForeignKey(
        "discounts.DiscountRule",
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="campaigns",
    )
    gateway = models.ForeignKey(
        "messaging.MessagingGateway",
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
    )
    scheduled_at = models.DateTimeField(blank=True, null=True)

    created_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="created_campaigns",
    )
    created_via = models.CharField(
        max_length=8, choices=CreatedVia.choices, default=CreatedVia.HUMAN
    )
    approved_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="approved_campaigns",
    )
    approved_at = models.DateTimeField(blank=True, null=True)

    total_recipients = models.PositiveIntegerField(default=0)
    sent_count = models.PositiveIntegerField(default=0)
    failed_count = models.PositiveIntegerField(default=0)
    skipped_optout_count = models.PositiveIntegerField(default=0)

    class Meta:
        ordering = ["-created_at"]
        permissions = [
            ("manage_campaigns", "Can create and edit draft campaigns"),
            ("send_campaigns", "Can approve and send campaigns"),
        ]

    def __str__(self) -> str:
        return self.name


class CampaignRecipient(TimeStampedModel):
    class Status(models.TextChoices):
        PENDING = "pending", "Pending"
        SKIPPED_OPTOUT = "skipped_optout", "Skipped (opted out)"
        QUEUED = "queued", "Queued"
        SENT = "sent", "Sent"
        DELIVERED = "delivered", "Delivered"
        FAILED = "failed", "Failed"

    campaign = models.ForeignKey(
        Campaign, on_delete=models.CASCADE, related_name="recipients"
    )
    customer = models.ForeignKey(
        "customers.Customer", on_delete=models.CASCADE, related_name="campaign_recipients"
    )
    phone = models.CharField(max_length=32, blank=True)
    # Frozen at expansion so editing the template after approval can't rewrite
    # already-resolved copy.
    rendered_body = models.TextField(blank=True)
    segments = models.PositiveSmallIntegerField(default=1)
    status = models.CharField(
        max_length=16, choices=Status.choices, default=Status.PENDING, db_index=True
    )
    outbound = models.ForeignKey(
        "messaging.OutboundMessage",
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="campaign_recipients",
    )

    class Meta:
        ordering = ["created_at"]
        constraints = [
            models.UniqueConstraint(
                fields=["campaign", "customer"],
                name="unique_recipient_per_campaign",
            )
        ]
        indexes = [models.Index(fields=["campaign", "status"])]

    def __str__(self) -> str:
        return f"{self.campaign_id}:{self.phone} [{self.status}]"


class StaffCommandNumber(TimeStampedModel):
    """A phone number allowed to run read-only staff SMS commands (SALES / DEBT /
    HELP). An inbound from one of these — that isn't a consent command — is
    answered instead of threaded into a customer conversation."""

    phone = models.CharField(max_length=32, unique=True)  # normalized E.164
    label = models.CharField(max_length=120, blank=True)
    is_active = models.BooleanField(default=True)

    class Meta:
        ordering = ["label", "phone"]

    def __str__(self) -> str:
        return self.label or self.phone
