"""A phone paired to a till, and the scans and photos it sends there.

Pointy cannot ship on the App Store, and a laser wedge scanner cannot read a
2-D code — so the camera every staff member already carries is unreachable.
These models are the handshake that lends it to a till: the till shows a QR, the
phone opens a page on the shop LAN, and what it reads or photographs arrives at
the till in under a second.

The till is identified by ``till_key`` throughout — the stable per-install id the
Flutter client already keeps (``pointy.connection.device_id.v1``). It is the
subscription channel, so a phone stays paired across a till restart, an app
update, and a cashier changing shift.
"""

from django.conf import settings
from django.contrib.contenttypes.fields import GenericForeignKey
from django.contrib.contenttypes.models import ContentType
from django.db import models
from django.utils import timezone

from apps.core.models import TimeStampedModel


class CompanionPairing(TimeStampedModel):
    """A single-use, short-lived invitation for one phone to join one till.

    Only the hash of the code is stored: a pairing is a live credential for its
    two-minute window, and a database read — a backup, a support export, a
    diagnostics bundle — should never hand someone a working one.
    """

    code_hash = models.CharField(max_length=64, unique=True)
    till_key = models.CharField(max_length=64, db_index=True)
    till_label = models.CharField(max_length=120, blank=True)
    created_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="companion_pairings",
    )
    expires_at = models.DateTimeField(db_index=True)
    claimed_at = models.DateTimeField(blank=True, null=True)
    claimed_by = models.ForeignKey(
        "companion.CompanionDevice",
        on_delete=models.SET_NULL,
        related_name="claimed_pairings",
        blank=True,
        null=True,
    )

    class Meta:
        ordering = ["-created_at"]

    def __str__(self) -> str:
        return f"pairing for {self.till_key}"

    @property
    def is_claimable(self) -> bool:
        return self.claimed_at is None and timezone.now() < self.expires_at


class CompanionDeviceQuerySet(models.QuerySet):
    def live(self):
        return self.filter(revoked_at__isnull=True)


class CompanionDevice(TimeStampedModel):
    """A paired phone.

    Deliberately *not* a login. The token authenticates a device to post scans
    and photos into one till's channel and nothing else — see
    ``apps.companion.authentication``. Phones get lost, so the blast radius of a
    stolen token is one shop's inbox, never its books.
    """

    class RevokedReason(models.TextChoices):
        MANUAL = "manual", "Unpaired by staff"
        SESSION_CLOSED = "session_closed", "Register session closed"
        IDLE = "idle", "Idle too long"
        REPLACED = "replaced", "Re-paired from the same phone"

    till_key = models.CharField(max_length=64, db_index=True)
    token_hash = models.CharField(max_length=64, unique=True)
    label = models.CharField(max_length=120, blank=True)
    paired_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="companion_devices",
    )
    # The pairing user's open register session, when they had one. A companion
    # is a tool for a shift: closing the drawer ends it (see ``is_live``).
    register_session = models.ForeignKey(
        "sales.RegisterSession",
        on_delete=models.SET_NULL,
        related_name="companion_devices",
        blank=True,
        null=True,
    )
    user_agent = models.CharField(max_length=255, blank=True)
    address = models.CharField(max_length=64, blank=True)
    last_seen_at = models.DateTimeField(blank=True, null=True, db_index=True)
    # Staff can silence a paired phone without unpairing it — the pocket-scan
    # guard for the ambient mode, where whatever the phone reads goes straight
    # into the open screen.
    is_paused = models.BooleanField(default=False)
    revoked_at = models.DateTimeField(blank=True, null=True)
    revoked_reason = models.CharField(
        max_length=24,
        choices=RevokedReason.choices,
        blank=True,
    )

    objects = CompanionDeviceQuerySet.as_manager()

    class Meta:
        ordering = ["-last_seen_at", "-created_at"]
        indexes = [
            models.Index(fields=["till_key", "revoked_at"]),
        ]

    def __str__(self) -> str:
        return self.label or f"companion {self.pk}"

    @property
    def is_live(self) -> bool:
        """Whether this device may still act, without touching the database."""
        if self.revoked_at is not None:
            return False
        if self.register_session_id and self.register_session.status != "open":
            return False
        return not self.is_idle_expired

    @property
    def is_idle_expired(self) -> bool:
        from django.conf import settings as django_settings

        hours = int(
            getattr(django_settings, "POINTY_COMPANION_IDLE_EXPIRY_HOURS", 24) or 0
        )
        if hours <= 0:
            return False
        last_seen = self.last_seen_at or self.created_at
        if last_seen is None:
            return False
        return timezone.now() - last_seen > timezone.timedelta(hours=hours)

    def revoke(self, reason: str = RevokedReason.MANUAL) -> None:
        if self.revoked_at is not None:
            return
        self.revoked_at = timezone.now()
        self.revoked_reason = reason
        self.save(update_fields=["revoked_at", "revoked_reason", "updated_at"])

    def touch(self, *, address: str = "") -> None:
        """Record liveness on the hot path without an ``updated_at`` write."""
        updates = ["last_seen_at"]
        self.last_seen_at = timezone.now()
        if address and address != self.address:
            self.address = address
            updates.append("address")
        self.save(update_fields=updates)


class CompanionCaptureRequest(TimeStampedModel):
    """A till asking its phone for one specific photo.

    Carrying the destination here — not on the phone — is what makes the phone
    side dumb and safe: the operator taps the shutter and the picture files
    itself against the right product, purchase order or job, because the till
    said so before the camera ever opened.
    """

    class Status(models.TextChoices):
        PENDING = "pending", "Pending"
        FULFILLED = "fulfilled", "Fulfilled"
        CANCELLED = "cancelled", "Cancelled"
        EXPIRED = "expired", "Expired"

    till_key = models.CharField(max_length=64, db_index=True)
    prompt = models.CharField(max_length=200, blank=True)
    # Optional: a request with no owner is a free capture that comes back to the
    # till as an event (the AI composer's "photograph this invoice").
    owner_content_type = models.ForeignKey(
        ContentType,
        on_delete=models.CASCADE,
        related_name="companion_capture_requests",
        blank=True,
        null=True,
    )
    owner_object_id = models.PositiveBigIntegerField(blank=True, null=True)
    owner = GenericForeignKey("owner_content_type", "owner_object_id")
    role = models.CharField(max_length=64, blank=True)
    is_primary = models.BooleanField(default=False)
    allow_multiple = models.BooleanField(default=False)
    status = models.CharField(
        max_length=12,
        choices=Status.choices,
        default=Status.PENDING,
        db_index=True,
    )
    created_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="companion_capture_requests",
    )
    expires_at = models.DateTimeField(db_index=True)

    class Meta:
        ordering = ["-created_at"]
        indexes = [
            models.Index(fields=["till_key", "status", "-created_at"]),
        ]

    def __str__(self) -> str:
        return self.prompt or f"capture request {self.pk}"

    @property
    def is_open(self) -> bool:
        return self.status == self.Status.PENDING and timezone.now() < self.expires_at


class CompanionEvent(TimeStampedModel):
    """One thing a phone sent to a till. The durable inbox behind the stream.

    Written *before* the stream is notified, and read back by primary key, so a
    till whose connection dropped mid-shift replays what it missed instead of
    silently losing a scan. The primary key is the cursor.
    """

    class Kind(models.TextChoices):
        SCAN = "scan", "Barcode or QR scan"
        CAPTURE = "capture", "Photo"
        DEVICE_STATE = "device_state", "Device connected, paused or left"

    till_key = models.CharField(max_length=64, db_index=True)
    device = models.ForeignKey(
        CompanionDevice,
        on_delete=models.SET_NULL,
        related_name="events",
        blank=True,
        null=True,
    )
    kind = models.CharField(max_length=16, choices=Kind.choices, db_index=True)
    payload = models.JSONField(default=dict, blank=True)
    attachment = models.ForeignKey(
        "attachments.Attachment",
        on_delete=models.SET_NULL,
        related_name="companion_events",
        blank=True,
        null=True,
    )
    capture_request = models.ForeignKey(
        CompanionCaptureRequest,
        on_delete=models.SET_NULL,
        related_name="events",
        blank=True,
        null=True,
    )

    class Meta:
        ordering = ["id"]
        indexes = [
            models.Index(fields=["till_key", "id"]),
        ]

    def __str__(self) -> str:
        return f"{self.kind} for {self.till_key}"
