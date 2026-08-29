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


class AssetType(TimeStampedModel):
    """A kind of thing a shop works on, defined by the shop.

    Was a fixed seven-value enum, which quietly decided that Pointy served phone
    shops and car workshops and nobody else. An electronics repairer takes in
    televisions, a generator shop takes in generators, a bicycle shop takes in
    frames — each with its own name for its own number — and none of them should
    need a code change to write that down.

    The ``tracks_*`` flags say which identity fields intake asks for, so a
    television is not asked for a number plate and a car is not asked for an
    IMEI. ``custom_identifier_label`` is the escape hatch for whatever a trade
    calls its own number ("رقم الهيكل", "رقم العداد") without adding a column per
    trade.
    """

    name = models.CharField(max_length=120)
    slug = models.SlugField(max_length=48, unique=True, allow_unicode=True)
    # Names an icon the client maps; unknown keys fall back to a generic one, so
    # a shop-invented type never renders blank.
    icon_key = models.CharField(max_length=32, default="device")
    display_order = models.PositiveIntegerField(default=0)
    is_active = models.BooleanField(default=True)
    # Seeded types cannot be deleted, only deactivated — the same rule the
    # seeded workflow templates use, so a shop cannot delete its way into a
    # registry with no types at all.
    is_system = models.BooleanField(default=False)

    tracks_serial_number = models.BooleanField(default=True)
    tracks_imei = models.BooleanField(default=False)
    tracks_vin = models.BooleanField(default=False)
    tracks_plate_number = models.BooleanField(default=False)
    tracks_engine_number = models.BooleanField(default=False)
    tracks_model_year = models.BooleanField(default=False)
    tracks_odometer = models.BooleanField(default=False)
    custom_identifier_label = models.CharField(max_length=60, blank=True)

    class Meta:
        ordering = ["display_order", "name"]

    def __str__(self) -> str:
        return self.name


class Asset(TimeStampedModel):
    """A customer-owned item the shop works on (phone, laptop, console, …).

    Jobs link to assets so a returning customer's device history is one
    lookup away.
    """

    # ``customer`` is the item's CURRENT owner, denormalised so every existing
    # query keeps working. The full chain of owners lives in ``AssetOwnership``
    # — a phone gets sold on and comes back to the same shop, and the new owner
    # should be able to see what was done to it.
    customer = models.ForeignKey(
        Customer,
        on_delete=models.PROTECT,
        related_name="assets",
    )
    asset_type = models.ForeignKey(
        AssetType,
        on_delete=models.PROTECT,
        related_name="assets",
    )
    brand = models.CharField(max_length=120, blank=True)
    model_name = models.CharField(max_length=120, blank=True)
    serial_number = models.CharField(max_length=120, blank=True)
    imei = models.CharField(max_length=64, blank=True)
    # Vehicle identity. A workshop looks a car up by its chassis number or its
    # plate; neither is optional in practice, but which one the counter staff
    # have to hand varies, so both are searchable and neither is required.
    vin = models.CharField(max_length=64, blank=True)
    plate_number = models.CharField(max_length=32, blank=True)
    engine_number = models.CharField(max_length=64, blank=True)
    model_year = models.PositiveSmallIntegerField(blank=True, null=True)
    # Last odometer reading seen, in kilometres. A hint for service intervals,
    # not an audited measurement — it is whatever the last technician typed.
    odometer = models.PositiveIntegerField(blank=True, null=True)
    # Whatever this trade calls its own number; the type supplies the label.
    custom_identifier = models.CharField(max_length=120, blank=True)
    color = models.CharField(max_length=64, blank=True)
    notes = models.TextField(blank=True)
    is_active = models.BooleanField(default=True)

    class Meta:
        ordering = ["-created_at"]
        # Identity numbers are indexed, not unique. Deliberately: the right
        # answer to "this IMEI is already on file" is to open the device that
        # already exists and show its history — that IS the feature — not to
        # refuse the entry. A hard constraint would also fail the migration on
        # any shop that has already typed the same number twice, and would turn
        # a helpful "you've seen this car before" into a dead end. The API
        # surfaces matches at intake instead (see the assets lookup endpoint).
        indexes = [
            models.Index(fields=["imei"], name="asset_imei_idx"),
            models.Index(fields=["vin"], name="asset_vin_idx"),
            models.Index(fields=["plate_number"], name="asset_plate_idx"),
            models.Index(fields=["serial_number"], name="asset_serial_idx"),
            models.Index(fields=["custom_identifier"], name="asset_custom_id_idx"),
        ]

    def __str__(self) -> str:
        label = " ".join(part for part in (self.brand, self.model_name) if part)
        return label or f"Asset {self.pk}"

    @property
    def display_name(self) -> str:
        label = " ".join(part for part in (self.brand, self.model_name) if part)
        return label or self.asset_type.name

    @property
    def identity_label(self) -> str:
        """The number a person would actually quote to find this item again.

        Plate first for a vehicle — it is what the owner says on the phone —
        then chassis, then the phone identifiers.
        """
        for value in (
            self.plate_number,
            self.vin,
            self.imei,
            self.serial_number,
            self.custom_identifier,
        ):
            if value:
                return value
        return ""


class AssetOwnership(TimeStampedModel):
    """Who owned an asset, and when.

    The open row (``released_at`` null) is the current owner and always agrees
    with ``Asset.customer``. Closed rows are why a shop can answer "this is the
    same car, the previous owner had the gearbox done here in March" — which is
    the entire point of keeping an asset registry rather than just a note on a
    job.
    """

    asset = models.ForeignKey(
        Asset,
        on_delete=models.CASCADE,
        related_name="ownerships",
    )
    customer = models.ForeignKey(
        Customer,
        on_delete=models.PROTECT,
        related_name="asset_ownerships",
    )
    acquired_at = models.DateTimeField(default=timezone.now)
    released_at = models.DateTimeField(blank=True, null=True)
    note = models.CharField(max_length=200, blank=True)

    class Meta:
        ordering = ["-acquired_at", "-id"]
        constraints = [
            models.UniqueConstraint(
                fields=["asset"],
                condition=models.Q(released_at__isnull=True),
                name="one_current_owner_per_asset",
            ),
        ]

    def __str__(self) -> str:
        return f"{self.asset_id} → {self.customer_id}"

    @property
    def is_current(self) -> bool:
        return self.released_at is None


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
