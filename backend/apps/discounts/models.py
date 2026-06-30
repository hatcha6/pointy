from decimal import Decimal

from django.contrib.contenttypes.fields import GenericForeignKey
from django.contrib.contenttypes.models import ContentType
from django.core.exceptions import ValidationError
from django.core.validators import MinValueValidator
from django.db import models
from django.db.models import Q

from apps.core.models import TimeStampedModel


MONEY_PLACES = Decimal("0.01")


def normalize_coupon_code(code: str | None) -> str:
    return "" if code is None else code.strip().upper()


class DiscountRule(TimeStampedModel):
    class Channel(models.TextChoices):
        SALES = "sales", "Sales"
        PURCHASING = "purchasing", "Purchasing"
        BOTH = "both", "Both"

    class ApplicationType(models.TextChoices):
        AUTOMATIC = "automatic", "Automatic"
        COUPON_CODE = "coupon_code", "Coupon code"

    class Scope(models.TextChoices):
        DOCUMENT = "document", "Document"
        LINE = "line", "Line"

    class ValueType(models.TextChoices):
        PERCENTAGE = "percentage", "Percentage"
        FIXED_AMOUNT = "fixed_amount", "Fixed amount"
        FIXED_UNIT_AMOUNT = "fixed_unit_amount", "Fixed unit amount"
        FIXED_PRICE = "fixed_price", "Fixed price"
        # Quantity-based promotions priced over a pool of whole units that the
        # rule matches (see ``DiscountEngine._pooled_allocations``). All three
        # are line-scoped and ignore the flat ``value`` semantics of the types
        # above except where noted.
        MULTI_BUY = "multi_buy", "Multi-buy (N for price)"
        TIERED = "tiered", "Tiered unit price"
        BUY_X_GET_Y = "buy_x_get_y", "Buy X get Y"

    # The quantity-based value types that are priced by pooling whole units
    # across every line a rule matches (mix-and-match) rather than by the flat
    # per-line ``value`` math the classic types use.
    POOLED_VALUE_TYPES = frozenset(
        {ValueType.MULTI_BUY, ValueType.TIERED, ValueType.BUY_X_GET_Y}
    )

    class BuyGetReward(models.TextChoices):
        FREE = "free", "Free"
        PERCENTAGE = "percentage", "Percentage off"
        FIXED_PRICE = "fixed_price", "Fixed unit price"

    class RoundingMode(models.TextChoices):
        NONE = "none", "No rounding"
        DOWN = "down", "Round down"
        NEAREST = "nearest", "Round to nearest"
        UP = "up", "Round up"

    name = models.CharField(max_length=160)
    description = models.TextField(blank=True)
    channel = models.CharField(
        max_length=16,
        choices=Channel.choices,
        default=Channel.SALES,
    )
    application_type = models.CharField(
        max_length=16,
        choices=ApplicationType.choices,
        default=ApplicationType.AUTOMATIC,
    )
    coupon_code = models.CharField(max_length=64, blank=True, db_index=True)
    scope = models.CharField(
        max_length=16,
        choices=Scope.choices,
        default=Scope.DOCUMENT,
    )
    value_type = models.CharField(max_length=24, choices=ValueType.choices)
    value = models.DecimalField(
        max_digits=10,
        decimal_places=4,
        validators=[MinValueValidator(Decimal("0.0001"))],
    )
    max_discount_amount = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        blank=True,
        null=True,
        validators=[MinValueValidator(Decimal("0.00"))],
    )
    rounding_mode = models.CharField(
        max_length=16,
        choices=RoundingMode.choices,
        default=RoundingMode.NONE,
    )
    rounding_increment = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        blank=True,
        null=True,
        validators=[MinValueValidator(Decimal("0.01"))],
    )
    min_order_subtotal = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        default=0,
        validators=[MinValueValidator(Decimal("0.00"))],
    )
    min_line_quantity = models.PositiveIntegerField(blank=True, null=True)
    # -- Quantity-promotion parameters (only used by the pooled value types) --
    # MULTI_BUY: units that form one priced group; ``value`` is the group price.
    group_size = models.PositiveIntegerField(blank=True, null=True)
    # BUY_X_GET_Y: buy ``buy_quantity`` units to reward ``get_quantity`` units.
    buy_quantity = models.PositiveIntegerField(blank=True, null=True)
    get_quantity = models.PositiveIntegerField(blank=True, null=True)
    # BUY_X_GET_Y: how the rewarded units are discounted. ``value`` carries the
    # magnitude (percent for PERCENTAGE, unit price for FIXED_PRICE; ignored and
    # treated as 100% off for FREE).
    reward_type = models.CharField(
        max_length=16,
        choices=BuyGetReward.choices,
        blank=True,
        default="",
    )
    priority = models.PositiveIntegerField(default=100, db_index=True)
    exclusive = models.BooleanField(default=True)
    is_active = models.BooleanField(default=True)
    starts_at = models.DateTimeField(blank=True, null=True)
    ends_at = models.DateTimeField(blank=True, null=True)
    usage_limit = models.PositiveIntegerField(blank=True, null=True)
    per_customer_usage_limit = models.PositiveIntegerField(blank=True, null=True)
    per_supplier_usage_limit = models.PositiveIntegerField(blank=True, null=True)
    products = models.ManyToManyField(
        "catalog.Product",
        blank=True,
        related_name="discount_rules",
    )
    variants = models.ManyToManyField(
        "catalog.ProductVariant",
        blank=True,
        related_name="discount_rules",
    )
    product_categories = models.ManyToManyField(
        "catalog.ProductCategory",
        blank=True,
        related_name="discount_rules",
    )
    customers = models.ManyToManyField(
        "customers.Customer",
        blank=True,
        related_name="discount_rules",
    )
    # RFM ranks this rule targets (e.g. ["champion", "at_risk"]); empty = every
    # rank. Matched against ``Customer.rfm_segment`` at checkout so a discount
    # can automatically reward (or win back) a whole segment without listing
    # customers by hand. ANDs with the ``customers`` whitelist when both are set.
    customer_ranks = models.JSONField(default=list, blank=True)
    suppliers = models.ManyToManyField(
        "purchasing.Supplier",
        blank=True,
        related_name="discount_rules",
    )
    metadata = models.JSONField(default=dict, blank=True)

    class Meta:
        ordering = ["priority", "id"]
        constraints = [
            models.UniqueConstraint(
                fields=["coupon_code"],
                condition=~Q(coupon_code=""),
                name="unique_non_blank_discount_coupon_code",
            )
        ]

    def clean(self):
        self.coupon_code = normalize_coupon_code(self.coupon_code)
        if (
            self.application_type == self.ApplicationType.COUPON_CODE
            and not self.coupon_code
        ):
            raise ValidationError({"coupon_code": "Coupon discounts require a code."})
        if (
            self.application_type == self.ApplicationType.AUTOMATIC
            and self.coupon_code
        ):
            raise ValidationError(
                {"coupon_code": "Automatic discounts cannot have a coupon code."}
            )
        if self.value_type == self.ValueType.PERCENTAGE and self.value > Decimal("100"):
            raise ValidationError({"value": "Percentage discounts cannot exceed 100."})
        if (
            self.value_type == self.ValueType.FIXED_UNIT_AMOUNT
            and self.scope != self.Scope.LINE
        ):
            raise ValidationError(
                {"scope": "Fixed unit amount discounts must be line-level."}
            )
        if (
            self.value_type == self.ValueType.FIXED_PRICE
            and self.scope != self.Scope.LINE
        ):
            raise ValidationError({"scope": "Fixed price discounts must be line-level."})
        self._clean_quantity_promotion()
        if (
            self.max_discount_amount is not None
            and self.max_discount_amount <= Decimal("0.00")
        ):
            raise ValidationError(
                {"max_discount_amount": "Maximum discount must be greater than zero."}
            )
        if self.rounding_mode == self.RoundingMode.NONE:
            self.rounding_increment = None
        elif self.rounding_increment is None:
            raise ValidationError(
                {"rounding_increment": "Rounding requires an increment."}
            )
        elif self.rounding_increment <= Decimal("0.00"):
            raise ValidationError(
                {"rounding_increment": "Rounding increment must be greater than zero."}
            )
        if (
            self.min_line_quantity is not None
            and self.min_line_quantity < 1
        ):
            raise ValidationError(
                {"min_line_quantity": "Minimum line quantity must be positive."}
            )
        if (
            self.per_customer_usage_limit is not None
            and self.channel == self.Channel.PURCHASING
        ):
            raise ValidationError(
                {
                    "per_customer_usage_limit": (
                        "Customer usage limits require a sales or both channel."
                    )
                }
            )
        if (
            self.per_supplier_usage_limit is not None
            and self.channel == self.Channel.SALES
        ):
            raise ValidationError(
                {
                    "per_supplier_usage_limit": (
                        "Supplier usage limits require a purchasing or both channel."
                    )
                }
            )
        if self.starts_at and self.ends_at and self.ends_at <= self.starts_at:
            raise ValidationError({"ends_at": "End date must be after start date."})
        if self.customer_ranks:
            # Local import avoids a discounts → customers import cycle.
            from apps.customers.models import Customer

            if not isinstance(self.customer_ranks, list):
                raise ValidationError(
                    {"customer_ranks": "Customer ranks must be a list."}
                )
            valid_ranks = set(Customer.Rank.values)
            unknown = [
                rank for rank in self.customer_ranks if rank not in valid_ranks
            ]
            if unknown:
                raise ValidationError(
                    {
                        "customer_ranks": (
                            f"Unknown customer ranks: {', '.join(map(str, unknown))}."
                        )
                    }
                )
            if self.channel == self.Channel.PURCHASING:
                raise ValidationError(
                    {
                        "customer_ranks": (
                            "Customer rank targeting requires a sales or both channel."
                        )
                    }
                )

    def _clean_quantity_promotion(self):
        """Validate and normalise the quantity-promotion value types.

        The pooled types (multi-buy, tiered, buy-X-get-Y) are always line-scoped
        and price a pool of whole units, so the per-line ``min_line_quantity``
        gate would wrongly drop small lines before pooling — it is rejected
        here. Parameters that belong to a *different* value type are cleared so a
        rule retyped from one promotion to another cannot keep stale config.
        Tiered rows are validated by the serializer (they are child records that
        do not exist yet at model-clean time).
        """
        value_type = self.value_type
        if value_type != self.ValueType.MULTI_BUY:
            self.group_size = None
        if value_type != self.ValueType.BUY_X_GET_Y:
            self.buy_quantity = None
            self.get_quantity = None
            self.reward_type = ""

        if value_type not in self.POOLED_VALUE_TYPES:
            return

        if self.scope != self.Scope.LINE:
            raise ValidationError(
                {"scope": "Quantity promotions must be line-level."}
            )
        if self.min_line_quantity is not None:
            raise ValidationError(
                {
                    "min_line_quantity": (
                        "Quantity promotions set their own threshold; leave the "
                        "minimum line quantity empty."
                    )
                }
            )

        if value_type == self.ValueType.MULTI_BUY:
            if self.group_size is None or self.group_size < 2:
                raise ValidationError(
                    {"group_size": "Multi-buy requires a group size of at least 2."}
                )
        elif value_type == self.ValueType.BUY_X_GET_Y:
            if self.buy_quantity is None or self.buy_quantity < 1:
                raise ValidationError(
                    {
                        "buy_quantity": (
                            "Buy X get Y requires a buy quantity of at least 1."
                        )
                    }
                )
            if self.get_quantity is None or self.get_quantity < 1:
                raise ValidationError(
                    {
                        "get_quantity": (
                            "Buy X get Y requires a get quantity of at least 1."
                        )
                    }
                )
            if self.reward_type not in self.BuyGetReward.values:
                raise ValidationError(
                    {"reward_type": "Choose how the rewarded items are discounted."}
                )
            if (
                self.reward_type == self.BuyGetReward.PERCENTAGE
                and self.value > Decimal("100")
            ):
                raise ValidationError(
                    {"value": "Percentage rewards cannot exceed 100."}
                )

    def save(self, *args, **kwargs):
        self.coupon_code = normalize_coupon_code(self.coupon_code)
        self.full_clean()
        return super().save(*args, **kwargs)

    def __str__(self) -> str:
        return self.name


class DiscountTier(TimeStampedModel):
    """A quantity break for a ``tiered`` discount rule: once the pooled count of
    matched whole units reaches ``min_quantity``, every whole unit reprices to
    ``unit_price``. The highest tier whose ``min_quantity`` is satisfied wins."""

    rule = models.ForeignKey(
        DiscountRule,
        on_delete=models.CASCADE,
        related_name="tiers",
    )
    min_quantity = models.PositiveIntegerField(validators=[MinValueValidator(1)])
    unit_price = models.DecimalField(
        max_digits=10,
        decimal_places=4,
        validators=[MinValueValidator(Decimal("0.00"))],
    )

    class Meta:
        ordering = ["min_quantity", "id"]
        constraints = [
            models.UniqueConstraint(
                fields=["rule", "min_quantity"],
                name="unique_discount_tier_min_quantity",
            )
        ]

    def __str__(self) -> str:
        return f"{self.rule_id}: {self.min_quantity}+ @ {self.unit_price}"


class AppliedDiscount(TimeStampedModel):
    rule = models.ForeignKey(
        DiscountRule,
        on_delete=models.SET_NULL,
        related_name="applied_discounts",
        blank=True,
        null=True,
    )
    rule_name = models.CharField(max_length=160)
    coupon_code = models.CharField(max_length=64, blank=True)
    source = models.CharField(
        max_length=16,
        choices=DiscountRule.ApplicationType.choices,
        default=DiscountRule.ApplicationType.AUTOMATIC,
    )
    channel = models.CharField(max_length=16, choices=DiscountRule.Channel.choices)
    scope = models.CharField(max_length=16, choices=DiscountRule.Scope.choices)
    value_type = models.CharField(max_length=24, choices=DiscountRule.ValueType.choices)
    value = models.DecimalField(max_digits=10, decimal_places=4)
    priority = models.PositiveIntegerField(default=100)
    exclusive = models.BooleanField(default=False)
    source_subtotal = models.DecimalField(max_digits=10, decimal_places=2, default=0)
    discount_amount = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        validators=[MinValueValidator(Decimal("0.00"))],
    )
    document_content_type = models.ForeignKey(
        ContentType,
        on_delete=models.PROTECT,
        related_name="+",
        blank=True,
        null=True,
    )
    document_object_id = models.PositiveBigIntegerField(blank=True, null=True, db_index=True)
    document = GenericForeignKey("document_content_type", "document_object_id")
    line_content_type = models.ForeignKey(
        ContentType,
        on_delete=models.PROTECT,
        related_name="+",
        blank=True,
        null=True,
    )
    line_object_id = models.PositiveBigIntegerField(blank=True, null=True, db_index=True)
    line = GenericForeignKey("line_content_type", "line_object_id")
    allocations = models.JSONField(default=list, blank=True)
    metadata = models.JSONField(default=dict, blank=True)

    class Meta:
        ordering = ["created_at", "id"]

    def __str__(self) -> str:
        return f"{self.rule_name} {self.discount_amount}"


class DiscountRedemption(TimeStampedModel):
    rule = models.ForeignKey(
        DiscountRule,
        on_delete=models.PROTECT,
        related_name="redemptions",
    )
    applied_discount = models.OneToOneField(
        AppliedDiscount,
        on_delete=models.PROTECT,
        related_name="redemption",
        blank=True,
        null=True,
    )
    coupon_code = models.CharField(max_length=64, blank=True)
    channel = models.CharField(max_length=16, choices=DiscountRule.Channel.choices)
    customer = models.ForeignKey(
        "customers.Customer",
        on_delete=models.SET_NULL,
        related_name="discount_redemptions",
        blank=True,
        null=True,
    )
    supplier = models.ForeignKey(
        "purchasing.Supplier",
        on_delete=models.SET_NULL,
        related_name="discount_redemptions",
        blank=True,
        null=True,
    )
    discount_amount = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        validators=[MinValueValidator(Decimal("0.00"))],
    )
    document_content_type = models.ForeignKey(
        ContentType,
        on_delete=models.PROTECT,
        related_name="+",
        blank=True,
        null=True,
    )
    document_object_id = models.PositiveBigIntegerField(blank=True, null=True, db_index=True)
    document = GenericForeignKey("document_content_type", "document_object_id")

    class Meta:
        ordering = ["-created_at", "-id"]
        indexes = [
            models.Index(fields=["rule", "customer"]),
            models.Index(fields=["rule", "supplier"]),
        ]

    def save(self, *args, **kwargs):
        self.coupon_code = normalize_coupon_code(self.coupon_code)
        return super().save(*args, **kwargs)

    def __str__(self) -> str:
        return f"{self.rule_id} redeemed for {self.discount_amount}"
