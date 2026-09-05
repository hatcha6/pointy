from django.core.exceptions import ValidationError
from django.core.validators import MinValueValidator
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

    class Rank(models.TextChoices):
        """RFM segments, ordered best → worst. Assigned automatically by the
        ``customers.recompute_customer_segments`` Celery task (see
        ``apps.customers.segmentation``); never set by hand."""

        CHAMPION = "champion", "Champion"
        LOYAL = "loyal", "Loyal"
        POTENTIAL_LOYALIST = "potential_loyalist", "Potential loyalist"
        NEW = "new_customer", "New customer"
        PROMISING = "promising", "Promising"
        NEEDS_ATTENTION = "needs_attention", "Needs attention"
        AT_RISK = "at_risk", "At risk"
        CANT_LOSE = "cant_lose", "Can't lose them"
        HIBERNATING = "hibernating", "Hibernating"
        LOST = "lost", "Lost"
        # No recognized purchase on record yet (walk-in placeholders, brand-new
        # contacts). Kept distinct from a scored rank so the UI can hide them.
        INACTIVE = "inactive", "No purchases"

    class CreditLimitPolicy(models.TextChoices):
        """How much this customer is allowed to owe on آجل invoices.

        Three states rather than one nullable number, because all three are
        things a shop owner actually says. ``SHOP_DEFAULT`` follows
        ``ShopSettings.default_customer_credit_limit`` so lowering the shop's
        appetite for risk does not mean editing every contact. ``UNLIMITED`` is
        the wholesale buyer everyone trusts, who must not be capped by a default
        written for walk-ins. ``CUSTOM`` carries its own ceiling — including
        ``0``, which is how you say "this one pays cash".
        """

        SHOP_DEFAULT = "shop_default", "Shop default"
        UNLIMITED = "unlimited", "No limit"
        CUSTOM = "custom", "Custom limit"

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
    # Opt-out consent (the shop policy): marketing is allowed by default and
    # blocked once the customer opts out — via an SMS STOP or a staff toggle — or
    # is flagged do-not-contact. Transactional messages (invoice, debt, OTP)
    # ignore both. The single authority is apps.crm.consent.can_send.
    marketing_opted_out_at = models.DateTimeField(blank=True, null=True)
    do_not_contact = models.BooleanField(default=False)
    notes = models.TextField(blank=True)
    is_active = models.BooleanField(default=True)
    # Placeholder customers minted automatically the first time a payment card is
    # seen. They stay hidden from the contacts list until a human names one
    # (claiming it) or merges it into a real customer.
    is_auto_created = models.BooleanField(default=False)

    # --- Credit (آجل) ---------------------------------------------------------
    # What this customer may owe. The policy decides whether ``credit_limit`` is
    # read at all; it is only meaningful under ``CUSTOM``. Resolved for real by
    # ``apps.customers.receivables.effective_credit_limit`` — nothing else
    # should reach for these two columns directly, because "no limit" is
    # expressed differently at each level and conflating the two spellings is
    # the way this feature would silently stop blocking anything.
    credit_limit_policy = models.CharField(
        max_length=16,
        choices=CreditLimitPolicy.choices,
        default=CreditLimitPolicy.SHOP_DEFAULT,
    )
    credit_limit = models.DecimalField(
        max_digits=12,
        decimal_places=2,
        blank=True,
        null=True,
        validators=[MinValueValidator(0)],
    )

    # --- RFM segmentation (recomputed nightly, never edited by hand) ----------
    # The named segment a customer falls into, used for targeting and the
    # contacts-list rank filter. ``INACTIVE`` until the customer has a
    # recognized purchase and the task has run at least once.
    rfm_segment = models.CharField(
        max_length=32,
        choices=Rank.choices,
        default=Rank.INACTIVE,
        db_index=True,
    )
    # Per-axis quintile scores (1 = weakest, 5 = strongest; 0 = unscored).
    rfm_recency_score = models.PositiveSmallIntegerField(default=0)
    rfm_frequency_score = models.PositiveSmallIntegerField(default=0)
    rfm_monetary_score = models.PositiveSmallIntegerField(default=0)
    # Sum of the three scores (3–15 once scored, 0 while unscored) — a cheap
    # single-column sort key for "best customers first".
    rfm_score = models.PositiveSmallIntegerField(default=0)
    # Raw inputs kept for display and so a rerun can be reasoned about offline.
    rfm_recency_days = models.PositiveIntegerField(blank=True, null=True)
    rfm_frequency = models.PositiveIntegerField(default=0)
    rfm_monetary = models.DecimalField(max_digits=12, decimal_places=2, default=0)
    rfm_last_purchase_at = models.DateTimeField(blank=True, null=True)
    rfm_calculated_at = models.DateTimeField(blank=True, null=True)

    class Meta:
        ordering = ["full_name", "customer_number"]

    def clean(self):
        if self.birthday and self.birthday > timezone.localdate():
            raise ValidationError({"birthday": "Birthday cannot be in the future."})
        # A custom policy with no number is not "no limit" — it is a customer
        # whose ceiling nobody wrote down, and reading it as unlimited would let
        # a half-filled form quietly disable the gate.
        if (
            self.credit_limit_policy == self.CreditLimitPolicy.CUSTOM
            and self.credit_limit is None
        ):
            raise ValidationError(
                {"credit_limit": "A custom credit limit needs an amount."}
            )

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
