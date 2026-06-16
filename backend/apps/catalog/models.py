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
    tracks_expiry = models.BooleanField(default=False, db_index=True)
    # Service products (labor, fees) are sold without touching stock.
    is_service = models.BooleanField(default=False)
    # Prepared (made-to-order) products — restaurant dishes — are also sold
    # without stock of their own; the kitchen job consumes their recipe
    # ingredients instead.
    is_prepared = models.BooleanField(default=False)
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

    @property
    def is_archived(self) -> bool:
        return self.archived_at is not None

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
        return self.variants.filter(is_default=True).order_by("id").first()

    @property
    def quantity_on_hand(self):
        return self.variants.aggregate(
            quantity=Coalesce(
                Sum("stock__quantity_on_hand"),
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
    unit_price = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        validators=[MinValueValidator(Decimal("0.00"))],
    )
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
        labels = [
            str(option_value).strip()
            for option_value in self.option_values.select_related("option").all()
            if str(option_value).strip()
        ]
        return " / ".join(labels)

    @property
    def quantity_on_hand(self):
        try:
            return self.stock.quantity_on_hand
        except ProductVariant.stock.RelatedObjectDoesNotExist:
            return 0

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
