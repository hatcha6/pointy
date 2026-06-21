from django.core.exceptions import ValidationError
from django.db import models, transaction
from django.utils import timezone

from apps.core.models import TimeStampedModel


class Customer(TimeStampedModel):
    class Gender(models.TextChoices):
        UNSPECIFIED = "", "Unspecified"
        FEMALE = "female", "Female"
        MALE = "male", "Male"
        NON_BINARY = "non_binary", "Non-binary"
        PREFER_NOT_TO_SAY = "prefer_not_to_say", "Prefer not to say"

    customer_number = models.CharField(max_length=32, unique=True, blank=True)
    full_name = models.CharField(max_length=255)
    phone = models.CharField(max_length=64, blank=True)
    email = models.EmailField(blank=True)
    gender = models.CharField(
        max_length=32,
        choices=Gender.choices,
        blank=True,
        default=Gender.UNSPECIFIED,
    )
    birthday = models.DateField(blank=True, null=True)
    marketing_consent = models.BooleanField(default=False)
    notes = models.TextField(blank=True)
    is_active = models.BooleanField(default=True)
    # Placeholder customers minted automatically the first time a payment card is
    # seen. They stay hidden from the contacts list until a human names one
    # (claiming it) or merges it into a real customer.
    is_auto_created = models.BooleanField(default=False)

    class Meta:
        ordering = ["full_name", "customer_number"]

    def clean(self):
        if self.birthday and self.birthday > timezone.localdate():
            raise ValidationError({"birthday": "Birthday cannot be in the future."})

    def save(self, *args, **kwargs):
        self.full_clean()
        if not self.customer_number:
            with transaction.atomic():
                super().save(*args, **kwargs)
                self.customer_number = f"C{self.created_at:%Y%m%d}{self.id:06d}"
                return super().save(update_fields=["customer_number"])
        return super().save(*args, **kwargs)

    def __str__(self) -> str:
        return self.full_name


class Asset(TimeStampedModel):
    """A customer-owned item the shop works on (phone, laptop, console, …).

    Jobs link to assets so a returning customer's device history is one
    lookup away.
    """

    class AssetType(models.TextChoices):
        PHONE = "phone", "Phone"
        TABLET = "tablet", "Tablet"
        LAPTOP = "laptop", "Laptop"
        CONSOLE = "console", "Game console"
        APPLIANCE = "appliance", "Appliance"
        OTHER = "other", "Other"

    customer = models.ForeignKey(
        Customer,
        on_delete=models.PROTECT,
        related_name="assets",
    )
    asset_type = models.CharField(
        max_length=24,
        choices=AssetType.choices,
        default=AssetType.OTHER,
    )
    brand = models.CharField(max_length=120, blank=True)
    model_name = models.CharField(max_length=120, blank=True)
    serial_number = models.CharField(max_length=120, blank=True)
    imei = models.CharField(max_length=64, blank=True)
    color = models.CharField(max_length=64, blank=True)
    notes = models.TextField(blank=True)
    is_active = models.BooleanField(default=True)

    class Meta:
        ordering = ["-created_at"]

    def __str__(self) -> str:
        label = " ".join(part for part in (self.brand, self.model_name) if part)
        return label or f"Asset {self.pk}"

    @property
    def display_name(self) -> str:
        label = " ".join(part for part in (self.brand, self.model_name) if part)
        return label or self.get_asset_type_display()


class PaymentCard(TimeStampedModel):
    """A redacted payment card seen at checkout, deduped across sales.

    Built from the (already redacted) terminal receipt — we only ever see a
    truncated PAN (BIN + last four), never the full number or CVV, so storing it
    is PCI-safe. ``fingerprint`` is a best-effort identity hashed from the masked
    PAN, scheme and AID; two physical cards that share a BIN and last-four can
    collide, so treat it as a strong hint, not a guarantee. A card always belongs
    to exactly one customer at a time (re-pointed on merge / reassign).
    """

    customer = models.ForeignKey(
        Customer,
        on_delete=models.PROTECT,
        related_name="cards",
    )
    fingerprint = models.CharField(max_length=64, unique=True)
    masked_pan = models.CharField(max_length=64, blank=True)
    card_scheme = models.CharField(max_length=64, blank=True)
    aid = models.CharField(max_length=64, blank=True)
    label = models.CharField(max_length=120, blank=True)
    first_seen_at = models.DateTimeField(default=timezone.now)
    last_seen_at = models.DateTimeField(default=timezone.now)
    is_active = models.BooleanField(default=True)
    # Snapshot of the most recent payment's card_receipt_data, kept for reference
    # (full per-payment evidence still lives on each Payment).
    last_receipt_data = models.JSONField(default=dict, blank=True)

    class Meta:
        ordering = ["-last_seen_at", "-id"]

    def __str__(self) -> str:
        return self.display_name

    @property
    def display_name(self) -> str:
        return self.label or self.masked_pan or f"Card {self.pk}"
