from decimal import Decimal

from django.conf import settings
from django.contrib.contenttypes.fields import GenericRelation
from django.core.exceptions import ValidationError
from django.core.validators import MinValueValidator
from django.db import models
from django.db.models import Q, Sum
from django.db.models.functions import Coalesce
from django.db.models.signals import m2m_changed
from django.dispatch import receiver
from django.utils import timezone

from apps.core.models import TimeStampedModel

from . import scale_barcodes


def normalize_sku(value: str | None) -> str:
    return "" if value is None else value.strip().upper()


def normalize_barcode(value: str | None) -> str:
    return "" if value is None else value.strip()


def variant_option_signature(option_values):
    value_ids = sorted(
        {
            getattr(option_value, "pk", option_value)
            for option_value in option_values
        }
    )
    return "|".join(str(value_id) for value_id in value_ids)


class UnitDimension(models.TextChoices):
    COUNT = "count", "Count"
    WEIGHT = "weight", "Weight"
    VOLUME = "volume", "Volume"
    LENGTH = "length", "Length"


# Physical dimensions sell/buy in fractions (1.5 kg); counted things do not.
FRACTIONAL_DIMENSIONS = frozenset(
    {UnitDimension.WEIGHT, UnitDimension.VOLUME, UnitDimension.LENGTH}
)


class UnitOfMeasureQuerySet(models.QuerySet):
    def active(self):
        return self.filter(is_active=True)


class UnitOfMeasure(TimeStampedModel):
    """A unit a product can be counted, sold, or purchased in.

    A global, editable registry (seeded with sensible defaults). Physical-measure
    units (weight/volume/length) carry a ``reference_factor`` so the app can
    *suggest* predictable conversions (1 kg = 1000 g); packaging units (box,
    carton, pack) have no global factor — their real conversion is per-product and
    lives on :class:`ProductUnit`. Conversions never cross dimensions."""

    code = models.SlugField(max_length=32, unique=True)
    name = models.CharField(max_length=64)
    abbreviation = models.CharField(max_length=16, blank=True)
    dimension = models.CharField(
        max_length=8,
        choices=UnitDimension.choices,
        default=UnitDimension.COUNT,
    )
    # For physical units only: how many of the dimension's reference unit fit in
    # one of this unit (g -> 0.001 when kg is the weight reference). Null for
    # packaging/count units. Powers *suggested* per-product factors only.
    reference_factor = models.DecimalField(
        max_digits=18,
        decimal_places=6,
        null=True,
        blank=True,
        validators=[MinValueValidator(Decimal("0.000001"))],
    )
    # Whether quantities of this unit may be fractional. Defaults from dimension
    # but stays editable so a shop can, e.g., forbid half-pieces explicitly.
    allows_fractional = models.BooleanField(default=False)
    # Seeded built-in units; protected from deletion in the admin/API.
    is_system = models.BooleanField(default=False)
    is_active = models.BooleanField(default=True)
    display_order = models.PositiveIntegerField(default=0)

    objects = UnitOfMeasureQuerySet.as_manager()

    class Meta:
        ordering = ["display_order", "name"]

    def save(self, *args, **kwargs):
        self.code = (self.code or "").strip().lower()
        return super().save(*args, **kwargs)

    def __str__(self) -> str:
        return self.name


class ProductQuerySet(models.QuerySet):
    def active(self):
        """Live (non-archived) products."""
        return self.filter(archived_at__isnull=True)

    def archived(self):
        return self.filter(archived_at__isnull=False)


class Product(TimeStampedModel):
    name = models.CharField(max_length=255)
    description = models.TextField(blank=True)
    is_active = models.BooleanField(default=True)
    # Archived products are retired from the live catalog: hidden from the
    # product list, POS, and purchasing, but kept (with their sales/purchase
    # history) and restorable. Archive is independent of `is_active`.
    archived_at = models.DateTimeField(null=True, blank=True, db_index=True)
    archived_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="archived_products",
        blank=True,
        null=True,
    )
    # Derived from ``tracking_mode`` and kept only so the release currently in
    # shops can still read it — it filters on
    # ``variant__product__tracks_expiry`` in the expiry-alert query and in
    # purchasing. §18.4: two flags governing one behaviour is how a shop's
    # expiry tracking stops without anyone noticing, so the mode is the answer
    # and this column is a mirror of it, written by ``save`` and by nothing
    # else. It goes in the contract release with the batch columns.
    #
    # Read it through the ``tracks_lots`` predicate, never directly.
    tracks_expiry = models.BooleanField(default=False, db_index=True)

    class TrackingMode(models.TextChoices):
        """How closely this product's stock is identified.

        ``quantity`` is what every product shipped as and what every product
        that does not opt in stays: a number in a bin, with no identity of its
        own. The other three are *shapes* a product takes when its trade needs
        one, and the fourth is the reason the first three are an enum rather
        than a pair of booleans — a serialised pharmaceutical pack is a unit
        *inside* a lot, and ``serial | batch`` as an exclusive choice is a wrong
        model of the world rather than a simplification of it.
        """

        QUANTITY = "quantity", "Quantity only"
        BATCH = "batch", "Batch / lot tracked"
        SERIAL = "serial", "Individually tracked"
        SERIAL_BATCH = "serial_batch", "Serialised within a lot"

    # Stays ``quantity`` for every product that never asks for anything else —
    # the whole invisibility guarantee in one column default. Indexed because
    # every stock write asks it, and a b-tree on a column that is one value for
    # 99% of rows still answers "is this one of the few" in constant time.
    tracking_mode = models.CharField(
        max_length=16,
        choices=TrackingMode.choices,
        default=TrackingMode.QUANTITY,
        db_index=True,
    )
    # What kind of identified thing this is, for identifier labels and (later)
    # per-unit attributes. Reuses the shop-editable registry the workshop side
    # already maintains rather than inventing a second one.
    asset_type = models.ForeignKey(
        "customers.AssetType",
        on_delete=models.PROTECT,
        null=True,
        blank=True,
        related_name="tracked_products",
    )
    # Warranty granted on sale, in days. 0 = none. Stamped onto the unit when it
    # is sold, so re-pricing the warranty next year does not re-date last year's.
    warranty_days = models.PositiveIntegerField(default=0)
    # --- batch & expiry policy -------------------------------------------
    # Read when ``tracking_mode`` is batch/serial_batch, or when
    # ``tracks_expiry`` is on.
    # Does a delivery of this have to say when it goes off?
    #
    # This is the half of the old ``tracks_expiry`` that was a real question in
    # its own right. That flag answered two at once — "does this stock belong to
    # cohorts" and "does it expire" — and folding it into ``tracking_mode``
    # (§18.4) answers only the first. Without this, every lot-tracked product
    # would demand an expiry date at receiving, which is right for milk and
    # wrong for a paint batch or a run of phone cases that are lot-tracked for
    # provenance and never go off.
    #
    # Set for every product that had ``tracks_expiry`` before the fold, so no
    # shop's receiving changed on the day it upgraded.
    expiry_required = models.BooleanField(default=False)
    shelf_life_days = models.PositiveIntegerField(default=0)  # 0 = indefinite
    expiry_warning_days = models.PositiveIntegerField(default=30)

    class BatchPickStrategy(models.TextChoices):
        FEFO = "fefo", "First expiring, first out"
        FIFO = "fifo", "First in, first out"
        MANUAL = "manual", "Manual select"

    auto_pick_strategy = models.CharField(
        max_length=16,
        choices=BatchPickStrategy.choices,
        default=BatchPickStrategy.FEFO,
    )
    prevent_selling_expired = models.BooleanField(default=True)
    # Service products (labor, fees) are sold without touching stock.
    is_service = models.BooleanField(default=False)
    # Prepared (made-to-order) products — restaurant dishes — are also sold
    # without stock of their own; the kitchen job consumes their recipe
    # ingredients instead.
    is_prepared = models.BooleanField(default=False)
    # Denormalized "most bought" score: the count of paid sale lines this product's
    # variants appear on within a rolling 90-day window, recomputed nightly by
    # ``catalog.recompute_product_popularity``. It is the catalog's default sort key
    # (most bought first) and the tiebreak for search relevance — read straight off
    # this indexed column so ordering by demand costs zero extra queries.
    popularity = models.PositiveIntegerField(default=0, db_index=True)
    # Base (stock-keeping) unit the product is counted in. Stock, recipes, and
    # job materials all use this unit. Its value is a ``UnitOfMeasure.code``; the
    # built-in codes below stay the defaults, but the unit list is now editable so
    # the field is no longer restricted to these choices.
    class Unit(models.TextChoices):
        PIECE = "piece", "Piece"
        KILOGRAM = "kg", "Kilogram"
        GRAM = "g", "Gram"
        LITER = "l", "Liter"
        MILLILITER = "ml", "Milliliter"

    unit = models.CharField(max_length=32, default=Unit.PIECE)
    # The currency this product's price sheet is written in. NULL means the
    # shop's own currency, which is what every existing product is and stays.
    #
    # This is a *pricing* attribute, not a ledger one: the sale is still rung up,
    # stored and reported in the shop's base currency. What it says is "the
    # number the owner maintains for this product is 12.00 dollars", so that a
    # rate move can be turned into a considered repricing instead of a
    # re-keying session. The base-currency price stays on the variant exactly as
    # before — see ``ProductVariant.price_amount``.
    pricing_currency = models.ForeignKey(
        "fx.Currency",
        on_delete=models.PROTECT,
        related_name="priced_products",
        null=True,
        blank=True,
    )
    # Units pre-selected in POS / purchasing. Blank = the base ``unit``. Stored as
    # a ``UnitOfMeasure.code`` and resolved against this product's ProductUnit set.
    default_sale_unit = models.CharField(max_length=32, blank=True, default="")
    default_purchase_unit = models.CharField(max_length=32, blank=True, default="")
    categories = models.ManyToManyField(
        "ProductCategory",
        blank=True,
        related_name="products",
    )
    variant_options = models.ManyToManyField(
        "VariantOption",
        blank=True,
        related_name="products",
    )
    # Per-line modifier sets (e.g. "Milk", "Extras"). Unlike variant_options
    # these never create distinct variants — they are per-sale-line add-ons that
    # adjust price and print on the chit/receipt.
    modifier_groups = models.ManyToManyField(
        "ModifierGroup",
        blank=True,
        through="ProductModifierGroup",
        related_name="products",
    )
    attachments = GenericRelation(
        "attachments.Attachment",
        content_type_field="owner_content_type",
        object_id_field="owner_object_id",
        related_query_name="products",
    )

    objects = ProductQuerySet.as_manager()

    class Meta:
        ordering = ["name"]
        indexes = [
            # The live catalog (POS + products list) is the single most-hit
            # list: it always filters archived_at IS NULL and orders by name,
            # id. A partial index keeps it small and serves that sort directly,
            # avoiding a filesort over the whole catalog on every load.
            models.Index(
                fields=["name", "id"],
                name="product_name_live_idx",
                condition=Q(archived_at__isnull=True),
            ),
        ]

    def save(self, *args, **kwargs):
        # One flag, not two. ``tracks_expiry`` is whatever the mode says it is,
        # so a product cannot end up tracking lots while its expiry flag says
        # otherwise — the four-combination state §18.4 says must not exist.
        expiry = self.tracks_lots
        if self.tracks_expiry != expiry:
            self.tracks_expiry = expiry
            update_fields = kwargs.get("update_fields")
            if update_fields is not None:
                kwargs["update_fields"] = {*update_fields, "tracks_expiry"}
        return super().save(*args, **kwargs)

    @property
    def is_archived(self) -> bool:
        return self.archived_at is not None

    # The three questions every stock path asks about a mode, answered here so
    # no caller ever writes ``mode in ("serial", "serial_batch")`` by hand and
    # gets one of the two wrong.
    @property
    def is_tracked(self) -> bool:
        """Does this product's stock carry identity at all?"""
        return self.tracking_mode != Product.TrackingMode.QUANTITY

    @property
    def tracks_units(self) -> bool:
        """Is every article of this product identified one at a time?"""
        return self.tracking_mode in (
            Product.TrackingMode.SERIAL,
            Product.TrackingMode.SERIAL_BATCH,
        )

    @property
    def tracks_lots(self) -> bool:
        """Does this product's stock belong to identified cohorts?"""
        return self.tracking_mode in (
            Product.TrackingMode.BATCH,
            Product.TrackingMode.SERIAL_BATCH,
        )

    @property
    def requires_lot(self) -> bool:
        """Must every new unit of this product name the lot it was born in?"""
        return self.tracking_mode == Product.TrackingMode.SERIAL_BATCH

    def archive(self, *, by=None):
        self.archived_at = timezone.now()
        self.archived_by = by
        self.save(update_fields=["archived_at", "archived_by", "updated_at"])

    def restore(self):
        self.archived_at = None
        self.archived_by = None
        self.save(update_fields=["archived_at", "archived_by", "updated_at"])

    @property
    def default_variant(self):
        if self.pk is None:
            return None
        # Reuse the prefetched variant set when the caller prefetched "variants"
        # (list serializers do) so we don't fire a query per product — and the
        # returned variant carries its already-prefetched option_values/attachments
        # instead of re-fetching them (which is what made the catalog list N+1).
        # Falls back to a direct query for un-prefetched single instances.
        if "variants" in getattr(self, "_prefetched_objects_cache", {}):
            defaults = [
                variant for variant in self.variants.all() if variant.is_default
            ]
            return min(defaults, key=lambda variant: variant.id) if defaults else None
        return self.variants.filter(is_default=True).order_by("id").first()

    @property
    def quantity_on_hand(self):
        return self.variants.aggregate(
            quantity=Coalesce(
                Sum("stock_items__quantity_on_hand"),
                Decimal("0"),
                output_field=models.DecimalField(max_digits=12, decimal_places=3),
            ),
        )["quantity"]

    def ensure_default_variant(self, **variant_data):
        if self.pk is None:
            return None
        defaults = self._default_variant_defaults(variant_data)
        variant = self.variants.filter(is_default=True).order_by("id").first()
        if variant is None:
            variant = self.variants.order_by("id").first()
        if variant is None:
            return ProductVariant.objects.create(
                product=self,
                is_default=True,
                **defaults,
            )

        update_fields = []
        if not variant.is_default:
            variant.is_default = True
            update_fields.append("is_default")
        for field in ("name", "sku", "barcode", "unit_price", "is_active"):
            if field in variant_data:
                setattr(variant, field, defaults[field])
                update_fields.append(field)
        if update_fields:
            variant.save(update_fields=[*set(update_fields), "updated_at"])
        return variant

    def _default_variant_defaults(self, data):
        sku = normalize_sku(data.get("sku")) or self._generated_default_sku()
        unit_price = Decimal(data.get("unit_price", Decimal("0.00")))
        return {
            "name": str(data.get("name", "")).strip(),
            "sku": sku,
            "barcode": normalize_barcode(data.get("barcode", "")),
            "unit_price": unit_price,
            "is_active": bool(data.get("is_active", self.is_active)),
        }

    def _generated_default_sku(self):
        base_sku = f"P{self.pk:06d}"
        candidate = base_sku
        suffix = 2
        while ProductVariant.objects.filter(sku=candidate).exists():
            candidate = f"{base_sku}-{suffix}"
            suffix += 1
        return candidate

    def __str__(self) -> str:
        return self.name


class ProductAlias(TimeStampedModel):
    """A learned alternate name for a product. When a user confirms which product an
    imported invoice line refers to (via the AI product picker), the invoice's name
    is remembered here so the same supplier wording auto-matches next time — every
    shop and wholesaler names products differently, and this makes matching adapt."""

    class Source(models.TextChoices):
        INVOICE = "invoice", "Invoice match"
        MANUAL = "manual", "Manual"
        # A match no human confirmed line-by-line: the invoice-intake pipeline's
        # supplier-history prior, and the LLM adjudication that follows it.
        # Recorded distinctly so machine-made aliases can be weighted lower —
        # or revoked in bulk — without touching what users confirmed themselves.
        AI_ADJUDICATED = "ai_adjudicated", "AI adjudicated"

    product = models.ForeignKey(
        Product,
        on_delete=models.CASCADE,
        related_name="aliases",
    )
    alias = models.CharField(max_length=255)
    # The normalized comparison key (Arabic-folded, diacritic-stripped, casefolded),
    # indexed so the matcher can look up an exact alias hit cheaply.
    normalized = models.CharField(max_length=255, db_index=True)
    source = models.CharField(
        max_length=16,
        choices=Source.choices,
        default=Source.MANUAL,
    )

    class Meta:
        ordering = ["alias"]
        constraints = [
            models.UniqueConstraint(
                fields=["product", "normalized"],
                name="unique_product_alias",
            )
        ]

    def __str__(self) -> str:
        return f"{self.alias} → {self.product_id}"

    def save(self, *args, **kwargs):
        from .search_terms import normalize_term

        self.alias = (self.alias or "").strip()[:255]
        if not self.normalized:
            self.normalized = normalize_term(self.alias)
        super().save(*args, **kwargs)

    @classmethod
    def remember(cls, product, text, *, source=Source.INVOICE):
        """Record ``text`` as an alias of ``product`` (idempotent). No-op when the
        text is blank or already normalizes to the product's own name or an existing
        alias — so we never store a redundant or empty synonym."""
        from .search_terms import normalize_term

        text = (text or "").strip()
        normalized = normalize_term(text)
        if not normalized or normalized == normalize_term(product.name):
            return None
        obj, _ = cls.objects.get_or_create(
            product=product,
            normalized=normalized,
            defaults={"alias": text[:255], "source": source},
        )
        return obj


class ProductUnitQuerySet(models.QuerySet):
    def active(self):
        return self.filter(unit__is_active=True)

    def sellable(self):
        return self.active().filter(is_sellable=True)

    def purchasable(self):
        return self.active().filter(is_purchasable=True)


class ProductUnit(TimeStampedModel):
    """An additional unit a specific product can be transacted in, with its
    per-product conversion to the product's base (stock) unit and an optional
    custom price.

    The base unit itself is implicit and is never stored here — it always has
    factor 1 and its price is the variant ``unit_price``. Packaging units (box,
    carton, pack) may wrap any base unit with an arbitrary per-product factor
    (1 box = 12 pieces, or 1 sack = 25 kg); the unit's dimension only drives the
    whole-number rule and the *suggested* factor, never a hard constraint."""

    product = models.ForeignKey(
        Product,
        on_delete=models.CASCADE,
        related_name="units",
    )
    unit = models.ForeignKey(
        UnitOfMeasure,
        on_delete=models.PROTECT,
        related_name="product_units",
    )
    # How many base units make up one of this unit, for THIS product (box -> 12).
    factor_to_base = models.DecimalField(
        max_digits=18,
        decimal_places=6,
        validators=[MinValueValidator(Decimal("0.000001"))],
    )
    # Custom price for one of this unit. Null -> derived = variant.unit_price *
    # factor_to_base. Lets a shop price a wholesale box below 12x the piece price.
    price = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        null=True,
        blank=True,
        validators=[MinValueValidator(Decimal("0.00"))],
    )
    # The same frozen-foreign-price trio as ``ProductVariant``, for a pack whose
    # price sheet is written per box rather than per piece. Null throughout for
    # a unit whose price is derived from the variant's.
    price_amount = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        null=True,
        blank=True,
        validators=[MinValueValidator(Decimal("0.00"))],
    )
    price_rate = models.DecimalField(
        max_digits=18,
        decimal_places=8,
        null=True,
        blank=True,
        validators=[MinValueValidator(Decimal("0"))],
    )
    price_rate_at = models.DateTimeField(null=True, blank=True)
    is_sellable = models.BooleanField(default=True)
    is_purchasable = models.BooleanField(default=True)
    display_order = models.PositiveIntegerField(default=0)

    objects = ProductUnitQuerySet.as_manager()

    class Meta:
        ordering = ["display_order", "id"]
        constraints = [
            models.UniqueConstraint(
                fields=["product", "unit"],
                name="unique_product_unit",
            ),
            models.CheckConstraint(
                condition=Q(factor_to_base__gt=0),
                name="product_unit_factor_positive",
            ),
            models.CheckConstraint(
                condition=Q(price__isnull=True) | Q(price__gte=0),
                name="product_unit_price_non_negative",
            ),
        ]

    def __str__(self) -> str:
        return f"{self.product_id}: {self.unit_id} ×{self.factor_to_base}"


class ProductUnitBarcode(TimeStampedModel):
    """A barcode printed on the packaging of one product unit (the carton/box
    EAN). Scanning it rings up that unit — one carton, at the carton price —
    instead of one base unit. A unit may carry several codes (regional EANs,
    multi-flavour cartons that share a product), so this is a child table
    rather than a column on :class:`ProductUnit`.

    Uniqueness is global across unit barcodes; collisions with *variant*
    barcodes cannot be a DB constraint (different table) and are enforced in
    the serializers and importers instead."""

    product_unit = models.ForeignKey(
        ProductUnit,
        on_delete=models.CASCADE,
        related_name="barcodes",
    )
    barcode = models.CharField(max_length=64, unique=True)

    class Meta:
        ordering = ["id"]

    def save(self, *args, **kwargs):
        self.barcode = normalize_barcode(self.barcode)
        return super().save(*args, **kwargs)

    def __str__(self) -> str:
        return self.barcode


class ProductCategory(TimeStampedModel):
    name = models.CharField(max_length=160)
    description = models.TextField(blank=True)
    parent = models.ForeignKey(
        "self",
        null=True,
        blank=True,
        related_name="children",
        on_delete=models.PROTECT,
    )
    is_active = models.BooleanField(default=True)
    # Surfaced as a one-tap filter chip above the catalog search in POS and
    # purchasing. The filter is recursive (the category plus its descendants),
    # see apps.catalog.services.category_ids_with_descendants.
    is_quick_access = models.BooleanField(default=False)
    # Manual sort order, primarily used to arrange the quick-access strip.
    # Lower values come first; ties fall back to name.
    display_order = models.PositiveIntegerField(default=0)

    class Meta:
        ordering = ["display_order", "name"]
        verbose_name_plural = "product categories"
        constraints = [
            models.UniqueConstraint(
                fields=["parent", "name"],
                name="unique_product_category_sibling_name",
            ),
        ]

    def __str__(self) -> str:
        return self.name


class VariantOptionQuerySet(models.QuerySet):
    def active(self):
        return self.filter(is_active=True)


class VariantOption(TimeStampedModel):
    code = models.CharField(max_length=64, unique=True)
    name = models.CharField(max_length=160)
    display_order = models.PositiveIntegerField(default=0)
    is_active = models.BooleanField(default=True)

    objects = VariantOptionQuerySet.as_manager()

    class Meta:
        ordering = ["display_order", "name"]

    def save(self, *args, **kwargs):
        self.code = self.code.strip().lower()
        self.name = self.name.strip()
        return super().save(*args, **kwargs)

    def __str__(self) -> str:
        return self.name


class VariantOptionValueQuerySet(models.QuerySet):
    def active(self):
        return self.filter(is_active=True, option__is_active=True)


class VariantOptionValue(TimeStampedModel):
    option = models.ForeignKey(
        VariantOption,
        on_delete=models.CASCADE,
        related_name="values",
    )
    code = models.CharField(max_length=64)
    name = models.CharField(max_length=160)
    display_order = models.PositiveIntegerField(default=0)
    is_active = models.BooleanField(default=True)

    objects = VariantOptionValueQuerySet.as_manager()

    class Meta:
        ordering = ["option__display_order", "display_order", "name"]
        constraints = [
            models.UniqueConstraint(
                fields=["option", "code"],
                name="unique_variant_option_value_code",
            ),
            models.UniqueConstraint(
                fields=["option", "name"],
                name="unique_variant_option_value_name",
            ),
        ]

    def save(self, *args, **kwargs):
        self.code = self.code.strip().lower()
        self.name = self.name.strip()
        return super().save(*args, **kwargs)

    def __str__(self) -> str:
        return f"{self.option.name}: {self.name}"


class ModifierGroupQuerySet(models.QuerySet):
    def active(self):
        return self.filter(is_active=True)


class ModifierGroup(TimeStampedModel):
    """A reusable set of per-line choices applied to a product, e.g. "Milk"
    (single-select) or "Extras" (multi-select). Assigned to products via
    ProductModifierGroup. Unlike VariantOption (which builds distinct priced,
    stocked variants), a modifier is a per-sale-line add-on: it only adjusts the
    line price and prints on the chit/receipt — it never creates a variant."""

    name = models.CharField(max_length=160)
    # 0 = optional; >=1 = the cashier must choose at least this many options.
    min_select = models.PositiveIntegerField(default=0)
    # null = unlimited multi-select; 1 = single-select.
    max_select = models.PositiveIntegerField(blank=True, null=True, default=1)
    display_order = models.PositiveIntegerField(default=0)
    is_active = models.BooleanField(default=True)

    objects = ModifierGroupQuerySet.as_manager()

    class Meta:
        ordering = ["display_order", "name"]

    def __str__(self) -> str:
        return self.name


class ModifierOption(TimeStampedModel):
    group = models.ForeignKey(
        ModifierGroup,
        on_delete=models.CASCADE,
        related_name="options",
    )
    name = models.CharField(max_length=160)
    price_delta = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        default=Decimal("0.00"),
        validators=[MinValueValidator(Decimal("0.00"))],
    )
    # 1 = toggle (on/off); >1 = quantifiable up to this many (a stepper appears).
    max_quantity = models.PositiveIntegerField(
        default=1,
        validators=[MinValueValidator(1)],
    )
    # Preselected when the modifier sheet opens, so the common case is one tap.
    is_default = models.BooleanField(default=False)
    display_order = models.PositiveIntegerField(default=0)
    is_active = models.BooleanField(default=True)

    class Meta:
        ordering = ["group__display_order", "display_order", "name"]

    def __str__(self) -> str:
        return f"{self.group.name}: {self.name}"


class ProductModifierGroup(TimeStampedModel):
    """Assigns a reusable ModifierGroup to a Product with a per-product order."""

    product = models.ForeignKey(
        Product,
        on_delete=models.CASCADE,
        related_name="modifier_group_links",
    )
    group = models.ForeignKey(
        ModifierGroup,
        on_delete=models.CASCADE,
        related_name="product_links",
    )
    display_order = models.PositiveIntegerField(default=0)

    class Meta:
        ordering = ["display_order", "id"]
        constraints = [
            models.UniqueConstraint(
                fields=["product", "group"],
                name="unique_product_modifier_group",
            ),
        ]

    def __str__(self) -> str:
        return f"{self.product.name} → {self.group.name}"


class ProductVariantQuerySet(models.QuerySet):
    def active(self):
        return self.filter(
            is_active=True,
            product__is_active=True,
            product__archived_at__isnull=True,
        )

    def default(self):
        return self.filter(is_default=True)


class ProductVariant(TimeStampedModel):
    product = models.ForeignKey(Product, on_delete=models.CASCADE, related_name="variants")
    name = models.CharField(max_length=160, blank=True)
    sku = models.CharField(max_length=64, unique=True)
    barcode = models.CharField(max_length=64, blank=True, db_index=True)
    # GS1 trade-item number, when the pack carries one. A GTIN identifies a
    # trade item at exactly the level this codebase already calls a variant —
    # the 500mg box, not the drug — which is why it sits here and the tracking
    # mode sits on the product. A scanned GS1 DataMatrix resolves to a variant
    # through this column before its lot and serial are read.
    gtin = models.CharField(max_length=14, blank=True, db_index=True)
    # ALWAYS the shop's base currency. This is the invariant the whole
    # multi-currency design rests on: every money column in this product keeps
    # meaning base currency, so nothing downstream — stock value, margin, the
    # loss guard, discounts, reports — has to learn about currencies.
    unit_price = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        validators=[MinValueValidator(Decimal("0.00"))],
    )
    # The foreign price this product is maintained in, when its product carries
    # a ``pricing_currency``, plus the rate that produced ``unit_price`` from it
    # and the instant that rate was effective. Frozen: nothing re-reads a rate to
    # re-derive ``unit_price``, because a price that changed itself between a
    # customer asking and paying is not a price. Repricing is an explicit,
    # previewed action — see ``apps.catalog.pricing``.
    price_amount = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        null=True,
        blank=True,
        validators=[MinValueValidator(Decimal("0.00"))],
    )
    price_rate = models.DecimalField(
        max_digits=18,
        decimal_places=8,
        null=True,
        blank=True,
        validators=[MinValueValidator(Decimal("0"))],
    )
    price_rate_at = models.DateTimeField(null=True, blank=True)
    is_active = models.BooleanField(default=True)
    is_default = models.BooleanField(default=False)
    option_signature = models.CharField(
        max_length=1024,
        blank=True,
        db_index=True,
        editable=False,
    )
    option_values = models.ManyToManyField(
        VariantOptionValue,
        blank=True,
        related_name="product_variants",
    )
    attachments = GenericRelation(
        "attachments.Attachment",
        content_type_field="owner_content_type",
        object_id_field="owner_object_id",
        related_query_name="product_variants",
    )

    objects = ProductVariantQuerySet.as_manager()

    class Meta:
        ordering = ["product__name", "is_default", "name", "id"]
        constraints = [
            models.UniqueConstraint(
                fields=["product"],
                condition=Q(is_default=True),
                name="unique_default_product_variant",
            ),
            models.UniqueConstraint(
                fields=["barcode"],
                condition=~Q(barcode=""),
                name="unique_non_blank_product_variant_barcode",
            ),
            models.CheckConstraint(
                condition=Q(unit_price__gte=0),
                name="product_variant_unit_price_non_negative",
            ),
            models.UniqueConstraint(
                fields=["product", "option_signature"],
                condition=~Q(option_signature=""),
                name="unique_product_variant_option_signature",
            ),
        ]

    @property
    def display_name(self):
        return self.name.strip() or self.option_values_label or self.product.name

    @property
    def full_name(self):
        name = self.name.strip() or self.option_values_label
        if not name or name == self.product.name:
            return self.product.name
        return f"{self.product.name} - {name}"

    @property
    def option_values_label(self):
        # Reuse a prefetched ``option_values`` (e.g. when serialising lists of
        # order/purchase lines) instead of a per-variant query; fall back to a
        # ``select_related`` fetch for un-prefetched callers.
        prefetched = getattr(self, "_prefetched_objects_cache", None)
        if prefetched is not None and "option_values" in prefetched:
            option_values = self.option_values.all()
        else:
            option_values = self.option_values.select_related("option").all()
        labels = [
            str(option_value).strip()
            for option_value in option_values
            if str(option_value).strip()
        ]
        return " / ".join(labels)

    #: Annotate a variant queryset with this to make ``quantity_on_hand`` free.
    #: A join and a GROUP BY, not a query per row — the sum has to come from
    #: somewhere and a page of products must not pay for it one variant at a
    #: time.
    ON_HAND_ANNOTATION = "on_hand_total"

    @property
    def quantity_on_hand(self):
        """Everything on hand, wherever it is.

        Was a one-to-one read while a variant had exactly one stock row; it is a
        sum across warehouses now. For a shop with one warehouse — which is most
        of them, and all of them until they open a second — it returns exactly
        the number it always did.

        Answered from an annotation if the caller made one, then from a
        prefetch, and only then from the database. Reading it off a bare
        instance in a loop is a query per row, which is the shape of every
        stock-list bug this codebase has had.
        """
        annotated = getattr(self, self.ON_HAND_ANNOTATION, None)
        if annotated is not None:
            return annotated
        cache = getattr(self, "_prefetched_objects_cache", None) or {}
        if "stock_items" in cache:
            return sum(
                (row.quantity_on_hand for row in cache["stock_items"]),
                Decimal("0.000"),
            )
        total = self.stock_items.aggregate(total=Sum("quantity_on_hand"))["total"]
        return total if total is not None else 0

    def quantity_on_hand_at(self, warehouse):
        """What is on hand in one named place.

        The question the till, the stock count and the transfer ask — never
        ``quantity_on_hand``, which would answer about the store room's stock
        when the customer is standing in the showroom.
        """
        warehouse_id = getattr(warehouse, "pk", warehouse)
        cache = getattr(self, "_prefetched_objects_cache", None) or {}
        if "stock_items" in cache:
            return sum(
                (
                    row.quantity_on_hand
                    for row in cache["stock_items"]
                    if row.warehouse_id == warehouse_id
                ),
                Decimal("0.000"),
            )
        row = (
            self.stock_items.filter(warehouse_id=warehouse_id)
            .values_list("quantity_on_hand", flat=True)
            .first()
        )
        return row if row is not None else 0

    def save(self, *args, **kwargs):
        self.name = self.name.strip()
        self.sku = normalize_sku(self.sku)
        self.barcode = normalize_barcode(self.barcode)
        return super().save(*args, **kwargs)

    def __str__(self) -> str:
        return f"{self.sku} - {self.full_name}"


def validate_variant_option_values(product, option_values, *, variant=None):
    option_values = list(option_values)
    selected_options = {}
    duplicate_option_ids = set()
    duplicate_option_names = []
    for option_value in option_values:
        option_id = option_value.option_id
        if option_id in selected_options and option_id not in duplicate_option_ids:
            duplicate_option_ids.add(option_id)
            duplicate_option_names.append(option_value.option.name)
        selected_options[option_id] = option_value

    if duplicate_option_names:
        raise ValidationError(
            {
                "option_values": (
                    "A variant can select at most one value for each option."
                )
            }
        )

    signature = variant_option_signature(option_values)
    if not signature:
        return signature

    allowed_option_ids = set(product.variant_options.values_list("id", flat=True))
    selected_option_ids = set(selected_options)
    if selected_option_ids - allowed_option_ids:
        raise ValidationError(
            {
                "option_values": (
                    "Option values must belong to the product variant option schema."
                )
            }
        )

    queryset = ProductVariant.objects.filter(product=product)
    if variant is not None and variant.pk is not None:
        queryset = queryset.exclude(pk=variant.pk)
    if queryset.filter(option_signature=signature).exists():
        raise ValidationError(
            {
                "option_values": (
                    "A variant with this option value combination already exists."
                )
            }
        )

    for other_variant in queryset.prefetch_related("option_values"):
        if other_variant.option_signature and other_variant.option_signature != signature:
            continue
        if variant_option_signature(other_variant.option_values.all()) == signature:
            raise ValidationError(
                {
                    "option_values": (
                        "A variant with this option value combination already exists."
                    )
                }
            )
    return signature


def refresh_variant_option_signature(variant):
    signature = variant_option_signature(variant.option_values.all())
    if variant.option_signature == signature:
        return
    ProductVariant.objects.filter(pk=variant.pk).update(option_signature=signature)
    variant.option_signature = signature


@receiver(m2m_changed, sender=ProductVariant.option_values.through)
def validate_product_variant_option_values(
    sender,
    instance,
    action,
    reverse,
    pk_set,
    **kwargs,
):
    if action == "pre_add":
        if reverse:
            variants = ProductVariant.objects.filter(pk__in=pk_set).select_related(
                "product"
            )
            for variant in variants:
                value_ids = set(variant.option_values.values_list("pk", flat=True))
                value_ids.add(instance.pk)
                option_values = VariantOptionValue.objects.select_related(
                    "option"
                ).filter(pk__in=value_ids)
                validate_variant_option_values(
                    variant.product,
                    option_values,
                    variant=variant,
                )
            return

        value_ids = set(instance.option_values.values_list("pk", flat=True))
        value_ids.update(pk_set)
        option_values = VariantOptionValue.objects.select_related("option").filter(
            pk__in=value_ids
        )
        validate_variant_option_values(instance.product, option_values, variant=instance)
        return

    if reverse and action == "pre_clear":
        instance._cleared_product_variant_ids = list(
            instance.product_variants.values_list("pk", flat=True)
        )
        return

    if action not in {"post_add", "post_remove", "post_clear"}:
        return

    if reverse:
        variant_ids = (
            pk_set
            if pk_set is not None
            else getattr(instance, "_cleared_product_variant_ids", [])
        )
        variants = ProductVariant.objects.filter(pk__in=variant_ids)
        for variant in variants:
            refresh_variant_option_signature(variant)
        return

    refresh_variant_option_signature(instance)


@receiver(m2m_changed, sender=Product.variant_options.through)
def validate_product_variant_option_schema(
    sender,
    instance,
    action,
    reverse,
    pk_set,
    **kwargs,
):
    if action not in {"pre_remove", "pre_clear"}:
        return

    if reverse:
        product_ids = (
            pk_set
            if pk_set is not None
            else list(instance.products.values_list("pk", flat=True))
        )
        option_ids = [instance.pk]
    else:
        product_ids = [instance.pk]
        if action == "pre_clear":
            option_ids = list(instance.variant_options.values_list("pk", flat=True))
        else:
            option_ids = pk_set or []

    if not product_ids or not option_ids:
        return

    if ProductVariant.objects.filter(
        product_id__in=product_ids,
        option_values__option_id__in=option_ids,
    ).exists():
        raise ValidationError(
            {
                "variant_options": (
                    "Product variant options cannot remove options used by variants."
                )
            }
        )


class BillOfMaterials(TimeStampedModel):
    """Recipe: the components needed to produce ``output_quantity`` of a variant."""

    variant = models.ForeignKey(
        ProductVariant,
        on_delete=models.PROTECT,
        related_name="boms",
    )
    name = models.CharField(max_length=160)
    output_quantity = models.PositiveIntegerField(default=1)
    is_active = models.BooleanField(default=True)

    class Meta:
        ordering = ["name"]
        verbose_name = "bill of materials"
        verbose_name_plural = "bills of materials"

    def __str__(self) -> str:
        return self.name


class BomLine(TimeStampedModel):
    bom = models.ForeignKey(
        BillOfMaterials,
        on_delete=models.CASCADE,
        related_name="lines",
    )
    component_variant = models.ForeignKey(
        ProductVariant,
        on_delete=models.PROTECT,
        related_name="bom_usages",
    )
    quantity = models.DecimalField(
        max_digits=10,
        decimal_places=3,
        validators=[MinValueValidator(Decimal("0.001"))],
    )
    waste_percent = models.DecimalField(max_digits=5, decimal_places=2, default=0)

    class Meta:
        ordering = ["id"]
        constraints = [
            models.UniqueConstraint(
                fields=["bom", "component_variant"],
                name="unique_component_per_bom",
            )
        ]

    def __str__(self) -> str:
        return f"{self.bom_id}: {self.component_variant_id} ×{self.quantity}"


class ScaleBarcodeRuleQuerySet(models.QuerySet):
    def active(self):
        return self.filter(is_active=True)


class ScaleBarcodeRule(TimeStampedModel):
    """How this shop's weighing scales lay out the barcodes they print.

    A price-computing scale prints an in-store code carrying the item and a
    measured value, and the *same thirteen digits* mean 1.250 kg on one scale
    and 12.50 dinars on another. Nothing in the code says which. So the layout
    is declared here, per shop, and :mod:`apps.catalog.scale_barcodes` refuses
    to read a label no rule describes.

    Rules are tried in ``sequence`` order and the first match wins, so a shop
    running a produce scale and a deli scale on different prefixes gets both.
    """

    name = models.CharField(max_length=120)
    # One character per digit position: literal digits are the prefix the scale
    # prints, I is the item (PLU) code, V the embedded value, C the check digit,
    # X a digit to skip. "21IIIIIVVVVVC" is the produce default.
    pattern = models.CharField(max_length=32)
    value_kind = models.CharField(
        max_length=8,
        choices=[
            (scale_barcodes.ValueKind.WEIGHT, "Weight"),
            (scale_barcodes.ValueKind.PRICE, "Price"),
            (scale_barcodes.ValueKind.COUNT, "Count"),
        ],
        default=scale_barcodes.ValueKind.WEIGHT,
    )
    # How many of the V digits are decimals. Grams inside five digits is 3.
    value_decimals = models.PositiveSmallIntegerField(default=3)
    # The unit the value is in once scaled — only meaningful for weight rules.
    # Converted to the product's own unit through UnitOfMeasure.reference_factor.
    value_unit = models.CharField(max_length=32, default=Product.Unit.KILOGRAM)
    # Cheap scales do print wrong check digits. A shop that owns one turns the
    # guard off for that rule rather than losing the feature — but it is on by
    # default, because it is the only thing standing between a misread digit and
    # a wrong quantity.
    require_check_digit = models.BooleanField(default=True)
    is_active = models.BooleanField(default=True)
    sequence = models.PositiveIntegerField(default=0)

    objects = ScaleBarcodeRuleQuerySet.as_manager()

    class Meta:
        ordering = ["sequence", "id"]

    def __str__(self) -> str:
        return f"{self.name} ({self.pattern})"

    def clean(self):
        try:
            scale_barcodes.validate_pattern(self.pattern)
        except scale_barcodes.ScaleRuleError as error:
            raise ValidationError({"pattern": str(error)}) from error
        if self.value_decimals > (self.pattern or "").count(scale_barcodes.VALUE):
            raise ValidationError(
                {
                    "value_decimals": (
                        "More decimal places than the pattern has value digits."
                    )
                }
            )
        if not self.is_active:
            return
        # Two active rules that can match the same codes make the till's answer
        # depend on row order, which is no answer at all.
        clashing = (
            ScaleBarcodeRule.objects.active()
            .exclude(pk=self.pk)
            .filter(pattern__isnull=False)
        )
        signature = self.as_rule().signature
        for other in clashing:
            try:
                other_signature = other.as_rule().signature
            except scale_barcodes.ScaleRuleError:
                continue  # An unusable row matches nothing, so it clashes with nothing.
            if other_signature == signature:
                raise ValidationError(
                    {
                        "pattern": (
                            f"'{other.name}' already matches these codes. "
                            "Two active rules cannot describe the same label."
                        )
                    }
                )

    def as_rule(self) -> scale_barcodes.ScaleRule:
        """The frozen, database-free shape the parser works in."""

        return scale_barcodes.ScaleRule(
            pattern=self.pattern,
            value_kind=self.value_kind,
            value_decimals=self.value_decimals,
            value_unit=self.value_unit,
            require_check_digit=self.require_check_digit,
            name=self.name,
            rule_id=self.pk,
        )


class ScalePluQuerySet(models.QuerySet):
    def active(self):
        return self.filter(is_active=True)


class ScalePlu(TimeStampedModel):
    """The number a product answers to on the shop's weighing scales.

    A scale does not know about barcodes or SKUs. It knows a PLU: a short
    number the operator keys in, which the scale then prints into the label
    along with what it weighed. So this is the product's identity on every
    scale in the shop, and it has one property that matters more than all the
    others: **it never moves**. Stickers printed last week are still on shelves
    and in customers' bags; a PLU that got reassigned turns every one of them
    into a label for the wrong product, at the wrong price, with nothing on
    screen to say so. Numbers are therefore allocated once, never reused, and
    retired by deactivating the row rather than deleting it.
    """

    variant = models.OneToOneField(
        ProductVariant,
        on_delete=models.CASCADE,
        related_name="scale_plu",
    )
    plu_number = models.PositiveIntegerField(unique=True)
    # What the scale prints on the sticker. Defaults to the product's name, but
    # stays separate because a scale's label is a few dozen characters of a
    # character set we do not choose — plenty of them cannot print Arabic at
    # all, and a shop with one of those needs somewhere to put "JEBEN ABYAD"
    # without renaming the product everybody else reads.
    label_name = models.CharField(max_length=40, blank=True)
    # Packaging weight the scale subtracts before it prints, in grams.
    tare_grams = models.PositiveIntegerField(default=0)
    # Printed as a sell-by date on the label. Null leaves the scale's own
    # setting alone.
    shelf_life_days = models.PositiveSmallIntegerField(null=True, blank=True)
    is_active = models.BooleanField(default=True)

    objects = ScalePluQuerySet.as_manager()

    class Meta:
        ordering = ["plu_number"]

    def __str__(self) -> str:
        return f"PLU {self.plu_number}"

    @property
    def printed_name(self) -> str:
        return self.label_name.strip() or self.variant.product.name

    @classmethod
    def next_number(cls) -> int:
        """The lowest number that has never been used.

        Deliberately ``max + 1`` over *every* row, retired ones included: a gap
        left by a deactivated PLU stays a gap, because the stickers that carry
        it may still be in the shop.
        """

        highest = cls.objects.aggregate(models.Max("plu_number"))["plu_number__max"]
        return int(highest or 0) + 1
