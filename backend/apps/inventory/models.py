from django.db import models

from apps.catalog.models import Product, ProductVariant
from apps.core.models import TimeStampedModel


def resolve_variant(product=None, variant=None):
    if variant is not None:
        return variant
    if isinstance(product, ProductVariant):
        return product
    if isinstance(product, Product):
        return product.default_variant
    return None


class VariantBackedQuerySet(models.QuerySet):
    @staticmethod
    def _variant_lookup_key(key):
        if not isinstance(key, str):
            return key
        if key == "product":
            return "variant__product"
        if key.startswith("product__"):
            return f"variant__{key}"
        if key == "product_id":
            return "variant__product_id"
        if key.startswith("product_id__"):
            return f"variant__product_id__{key.split('__', 1)[1]}"
        return key

    def _variant_lookup_kwargs(self, kwargs):
        return {
            self._variant_lookup_key(key): value
            for key, value in kwargs.items()
        }

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
            bare_name = self._variant_lookup_key(bare_name)
            translated.append(f"-{bare_name}" if descending else bare_name)
        return super().order_by(*translated)

    def select_related(self, *fields):
        if not fields:
            return super().select_related(*fields)
        return super().select_related(
            *(self._variant_lookup_key(field) for field in fields)
        )


class VariantBackedManager(models.Manager.from_queryset(VariantBackedQuerySet)):
    def _variant_kwargs(self, kwargs):
        kwargs = dict(kwargs)
        product = kwargs.pop("product", None)
        if "variant" not in kwargs and product is not None:
            kwargs["variant"] = resolve_variant(product=product)
        return kwargs

    def create(self, **kwargs):
        return super().create(**self._variant_kwargs(kwargs))

    def get_or_create(self, defaults=None, **kwargs):
        defaults = None if defaults is None else self._variant_kwargs(defaults)
        return super().get_or_create(defaults=defaults, **self._variant_kwargs(kwargs))


class VariantProductCompatibilityMixin:
    @property
    def product(self):
        if self.variant_id:
            return self.variant.product
        return getattr(self, "_compat_product", None)

    @product.setter
    def product(self, value):
        self._compat_product = value
        if self.variant_id is None:
            variant = resolve_variant(product=value)
            if variant is not None:
                self.variant = variant

    @property
    def product_id(self):
        if self.variant_id:
            return self.variant.product_id
        product = getattr(self, "_compat_product", None)
        return getattr(product, "pk", product)

    @product_id.setter
    def product_id(self, value):
        self._compat_product = value


class StockItem(VariantProductCompatibilityMixin, TimeStampedModel):
    variant = models.OneToOneField(
        ProductVariant,
        on_delete=models.CASCADE,
        related_name="stock",
    )
    quantity_on_hand = models.IntegerField(default=0)
    quantity_committed = models.IntegerField(default=0)
    quantity_expected = models.IntegerField(default=0)
    reorder_level = models.PositiveIntegerField(default=5)

    objects = VariantBackedManager()

    class Meta:
        ordering = ["variant__product__name", "variant__name"]

    def __str__(self) -> str:
        return f"{self.variant.sku}: {self.quantity_on_hand}"


class StockMovement(VariantProductCompatibilityMixin, TimeStampedModel):
    class Type(models.TextChoices):
        INCREASE = "increase", "Increase stock"
        DECREASE = "decrease", "Decrease stock"
        DAMAGED = "damaged", "Damaged stock"
        EXPECTED = "expected", "Expected stock"
        RECEIVE_EXPECTED = "receive_expected", "Receive expected stock"
        RECEIVE_DAMAGED = "receive_damaged", "Receive damaged expected stock"
        CANCEL_EXPECTED = "cancel_expected", "Cancel expected stock"

    variant = models.ForeignKey(
        ProductVariant,
        on_delete=models.CASCADE,
        related_name="stock_movements",
    )
    stock_item = models.ForeignKey(
        StockItem,
        on_delete=models.CASCADE,
        related_name="movements",
    )
    movement_type = models.CharField(max_length=32, choices=Type.choices)
    quantity = models.PositiveIntegerField()
    note = models.CharField(max_length=240, blank=True)
    created_by = models.ForeignKey(
        "auth.User",
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="stock_movements",
    )
    on_hand_before = models.IntegerField()
    on_hand_after = models.IntegerField()
    committed_before = models.IntegerField()
    committed_after = models.IntegerField()
    expected_before = models.IntegerField()
    expected_after = models.IntegerField()

    class Meta:
        ordering = ["-created_at", "-id"]

    objects = VariantBackedManager()

    def __str__(self) -> str:
        return f"{self.variant.sku} {self.movement_type} {self.quantity}"
