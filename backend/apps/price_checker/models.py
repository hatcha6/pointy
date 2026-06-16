from django.db import models
from django.utils import timezone
from django.utils.text import slugify

from apps.core.models import TimeStampedModel


def normalize_device_identifier(value: str | None) -> str:
    """Slug used as the stable, unique id for a device (often MAC-derived)."""
    return slugify(value or "").strip()[:80]


class PriceCheckerDevice(TimeStampedModel):
    """A self-service in-store barcode price verifier.

    Devices come in protocol families (see ``Transport``) and wildly different
    display capabilities. The concrete protocol/markup lives in a *driver*
    (see ``apps.price_checker.drivers``); this record holds the device's
    identity, network address, and display capabilities (rows/cols, Arabic
    rendering tier, wire encoding).
    """

    class Transport(models.TextChoices):
        HTTP = "http", "HTTP / web kiosk"
        TCP = "tcp", "Raw TCP socket"
        UDP = "udp", "UDP datagram"

    class ArabicSupport(models.TextChoices):
        # Cannot render Arabic at all -> Latin fallback (e.g. "12.50 LYD").
        NONE = "none", "None (Latin fallback)"
        # Smart display (browser / OS) shapes + reorders itself: send logical
        # UTF-8 and let the device do the work.
        UNICODE = "unicode", "Unicode (device shapes)"
        # Dumb display with a CP1256 Arabic font that shapes letters but does
        # not reorder RTL: send base letters in visual order, CP1256-encoded.
        CP1256 = "cp1256", "CP1256 (server reorders)"
        # Pure glyph blitter, no shaping, no bidi: send pre-shaped presentation
        # forms in visual order (server reshapes + reorders).
        GLYPHS = "glyphs", "Pre-shaped glyphs (server shapes)"

    class Status(models.TextChoices):
        # Found on the network but not yet confirmed/configured by staff.
        DISCOVERED = "discovered", "Discovered"
        ACTIVE = "active", "Active"
        DISABLED = "disabled", "Disabled"

    class DiscoveryMethod(models.TextChoices):
        MANUAL = "manual", "Added manually"
        SCAN = "scan", "Found by network scan"
        SELF = "self", "Self-registered on first contact"

    identifier = models.SlugField(max_length=80, unique=True)
    name = models.CharField(max_length=120)
    # Driver key, e.g. "generic_http", "scantech_shuttle". Validated against the
    # registry in the serializer (kept a plain CharField so new drivers don't
    # require a migration).
    driver = models.CharField(max_length=64)
    make = models.CharField(max_length=80, blank=True)
    model = models.CharField(max_length=80, blank=True)
    transport = models.CharField(
        max_length=8,
        choices=Transport.choices,
        default=Transport.HTTP,
    )

    # Network identity. address/port are used for outbound connections to
    # TCP-server-mode devices and to recognise a device that contacts us.
    address = models.GenericIPAddressField(blank=True, null=True)
    port = models.PositiveIntegerField(blank=True, null=True)
    mac_address = models.CharField(max_length=17, blank=True, db_index=True)

    # Display capabilities. Defaults suit a small 5x20 verifier; drivers seed
    # sensible values per make at registration time.
    display_rows = models.PositiveSmallIntegerField(default=5)
    display_cols = models.PositiveSmallIntegerField(default=20)
    arabic_support = models.CharField(
        max_length=8,
        choices=ArabicSupport.choices,
        default=ArabicSupport.UNICODE,
    )
    encoding = models.CharField(max_length=24, default="utf-8")

    location = models.CharField(max_length=120, blank=True)
    status = models.CharField(
        max_length=12,
        choices=Status.choices,
        default=Status.ACTIVE,
        db_index=True,
    )
    discovery_method = models.CharField(
        max_length=8,
        choices=DiscoveryMethod.choices,
        default=DiscoveryMethod.MANUAL,
    )
    last_seen_at = models.DateTimeField(blank=True, null=True)
    settings = models.JSONField(default=dict, blank=True)

    class Meta:
        ordering = ["name", "identifier"]

    def __str__(self) -> str:
        return self.name or self.identifier

    @property
    def is_serving(self) -> bool:
        return self.status == self.Status.ACTIVE

    def mark_seen(self, *, address: str | None = None) -> None:
        updates = ["last_seen_at"]
        self.last_seen_at = timezone.now()
        if address and address != self.address:
            self.address = address
            updates.append("address")
        # Avoid a full save (and updated_at churn) on the hot scan path.
        self.save(update_fields=updates)


class PriceCheckEvent(TimeStampedModel):
    """Audit record for every barcode a price checker scans.

    Kept intentionally denormalised (device_identifier, product_name, prices)
    so the log survives device or product deletion and powers analytics:
    most-checked items, and — via ``NOT_FOUND`` rows — mislabelled or
    missing-barcode products.
    """

    class Result(models.TextChoices):
        FOUND = "found", "Found"
        NOT_FOUND = "not_found", "Not found"
        ERROR = "error", "Error"

    device = models.ForeignKey(
        PriceCheckerDevice,
        on_delete=models.SET_NULL,
        related_name="events",
        blank=True,
        null=True,
    )
    device_identifier = models.CharField(max_length=80, blank=True, db_index=True)
    barcode = models.CharField(max_length=64, db_index=True)
    result = models.CharField(
        max_length=12,
        choices=Result.choices,
        db_index=True,
    )

    variant = models.ForeignKey(
        "catalog.ProductVariant",
        on_delete=models.SET_NULL,
        related_name="price_check_events",
        blank=True,
        null=True,
    )
    product_name = models.CharField(max_length=255, blank=True)
    original_price = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        blank=True,
        null=True,
    )
    final_price = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        blank=True,
        null=True,
    )
    discount_total = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        blank=True,
        null=True,
    )
    currency = models.CharField(max_length=16, blank=True)
    # Logical (un-shaped) text we rendered, for audit/debugging.
    response_text = models.TextField(blank=True)
    source_address = models.CharField(max_length=64, blank=True)
    latency_ms = models.PositiveIntegerField(blank=True, null=True)
    metadata = models.JSONField(default=dict, blank=True)

    class Meta:
        ordering = ["-created_at"]
        indexes = [
            models.Index(fields=["result", "-created_at"]),
            models.Index(fields=["barcode", "-created_at"]),
        ]

    def __str__(self) -> str:
        return f"{self.barcode} ({self.result})"
