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

    def save(self, *args, **kwargs):
        self.coupon_code = normalize_coupon_code(self.coupon_code)
        self.full_clean()
        return super().save(*args, **kwargs)

    def __str__(self) -> str:
        return self.name


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
