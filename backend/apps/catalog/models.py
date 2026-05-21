from decimal import Decimal

from django.core.validators import MinValueValidator
from django.db import models
from django.db.models import Q, Sum
from django.db.models.functions import Coalesce

from apps.core.models import TimeStampedModel


LEGACY_VARIANT_FIELDS = {"sku", "barcode", "unit_price"}


def normalize_sku(value: str | None) -> str:
    return "" if value is None else value.strip().upper()


def normalize_barcode(value: str | None) -> str:
    return "" if value is None else value.strip()


class ProductQuerySet(models.QuerySet):
    def _variant_lookup_kwargs(self, kwargs):
        translated = {}
        for key, value in kwargs.items():
            lookup_parts = key.split("__", 1)
            field = lookup_parts[0]
            suffix = f"__{lookup_parts[1]}" if len(lookup_parts) == 2 else ""
            if field in LEGACY_VARIANT_FIELDS:
                translated[f"variants__{field}{suffix}"] = value
            else:
                translated[key] = value
        return translated

    def filter(self, *args, **kwargs):
        return super().filter(*args, **self._variant_lookup_kwargs(kwargs))

    def exclude(self, *args, **kwargs):
        return super().exclude(*args, **self._variant_lookup_kwargs(kwargs))

    def get(self, *args, **kwargs):
        return super().get(*args, **self._variant_lookup_kwargs(kwargs))

    def order_by(self, *field_names):
        translated = []
        for field_name in field_names:
            descending = field_name.startswith("-")
            bare_name = field_name[1:] if descending else field_name
            if bare_name in LEGACY_VARIANT_FIELDS:
                bare_name = f"variants__{bare_name}"
            translated.append(f"-{bare_name}" if descending else bare_name)
        return super().order_by(*translated)


class ProductManager(models.Manager.from_queryset(ProductQuerySet)):
    pass


class Product(TimeStampedModel):
    name = models.CharField(max_length=255)
    description = models.TextField(blank=True)
    is_active = models.BooleanField(default=True)
    categories = models.ManyToManyField(
        "ProductCategory",
        blank=True,
        related_name="products",
    )

    objects = ProductManager()

    class Meta:
        ordering = ["name"]

    def __init__(self, *args, **kwargs):
        self._pending_default_variant_data = self._pop_default_variant_data(kwargs)
        super().__init__(*args, **kwargs)

    @staticmethod
    def _pop_default_variant_data(kwargs):
        data = {}
        for field in LEGACY_VARIANT_FIELDS:
            if field in kwargs:
                data[field] = kwargs.pop(field)
        if "is_active" in kwargs:
            data.setdefault("is_active", kwargs["is_active"])
        return data

    def _set_pending_default_variant_value(self, field, value):
        if not hasattr(self, "_pending_default_variant_data"):
            self._pending_default_variant_data = {}
        self._pending_default_variant_data[field] = value

    @property
    def sku(self):
        variant = self.default_variant
        return "" if variant is None else variant.sku

    @sku.setter
    def sku(self, value):
        self._set_pending_default_variant_value("sku", value)

    @property
    def barcode(self):
        variant = self.default_variant
        return "" if variant is None else variant.barcode

    @barcode.setter
    def barcode(self, value):
        self._set_pending_default_variant_value("barcode", value)

    @property
    def unit_price(self):
        variant = self.default_variant
        return Decimal("0.00") if variant is None else variant.unit_price

    @unit_price.setter
    def unit_price(self, value):
        self._set_pending_default_variant_value("unit_price", value)

    @property
    def default_variant(self):
        if self.pk is None:
            return None
        variant = self.variants.filter(is_default=True).order_by("id").first()
        if variant is not None:
            return variant
        variant = self.variants.order_by("id").first()
        if variant is not None:
            return variant
        return self.ensure_default_variant()

    @property
    def quantity_on_hand(self):
        return self.variants.aggregate(
            quantity=Coalesce(Sum("stock__quantity_on_hand"), 0),
        )["quantity"]

    def save(self, *args, **kwargs):
        creating = self._state.adding
        update_fields = kwargs.get("update_fields")
        if update_fields is not None:
            product_update_fields = [
                field for field in update_fields if field not in LEGACY_VARIANT_FIELDS
            ]
            if product_update_fields:
                kwargs["update_fields"] = product_update_fields
                super().save(*args, **kwargs)
            elif creating:
                kwargs.pop("update_fields", None)
                super().save(*args, **kwargs)
        else:
            super().save(*args, **kwargs)

        if not kwargs.get("raw", False):
            self.ensure_default_variant(**getattr(self, "_pending_default_variant_data", {}))
            self._pending_default_variant_data = {}

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
        for field in LEGACY_VARIANT_FIELDS:
            if field in variant_data:
                setattr(variant, field, defaults[field])
                update_fields.append(field)
        if "is_active" in variant_data:
            variant.is_active = defaults["is_active"]
            update_fields.append("is_active")
        if update_fields:
            variant.save(update_fields=[*set(update_fields), "updated_at"])
        return variant

    def _default_variant_defaults(self, data):
        sku = normalize_sku(data.get("sku")) or self._generated_default_sku()
        unit_price = Decimal(data.get("unit_price", Decimal("0.00")))
        return {
            "name": "",
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
        return f"{self.sku} - {self.name}"


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

    class Meta:
        ordering = ["name"]
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


class ProductVariantQuerySet(models.QuerySet):
    def active(self):
        return self.filter(is_active=True, product__is_active=True)

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
    option_values = models.ManyToManyField(
        VariantOptionValue,
        blank=True,
        related_name="product_variants",
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
        ]

    @property
    def display_name(self):
        return self.name.strip() or self.product.name

    @property
    def full_name(self):
        name = self.name.strip()
        if not name:
            return self.product.name
        return f"{self.product.name} - {name}"

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
