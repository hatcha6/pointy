from django.conf import settings
from django.db import models
from django.db.models import F, Q

from apps.catalog.models import ProductVariant
from apps.core.models import TimeStampedModel


class StockItem(TimeStampedModel):
    variant = models.OneToOneField(
        ProductVariant,
        on_delete=models.CASCADE,
        related_name="stock",
    )
    quantity_on_hand = models.DecimalField(max_digits=12, decimal_places=3, default=0)
    quantity_committed = models.DecimalField(max_digits=12, decimal_places=3, default=0)
    quantity_expected = models.DecimalField(max_digits=12, decimal_places=3, default=0)
    reorder_level = models.PositiveIntegerField(default=5)

    class Meta:
        ordering = ["variant__product__name", "variant__name"]

    def __str__(self) -> str:
        return f"{self.variant.sku}: {self.quantity_on_hand}"


class StockMovement(TimeStampedModel):
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
    quantity = models.DecimalField(max_digits=12, decimal_places=3)
    note = models.CharField(max_length=240, blank=True)
    created_by = models.ForeignKey(
        "auth.User",
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="stock_movements",
    )
    on_hand_before = models.DecimalField(max_digits=12, decimal_places=3)
    on_hand_after = models.DecimalField(max_digits=12, decimal_places=3)
    committed_before = models.DecimalField(max_digits=12, decimal_places=3)
    committed_after = models.DecimalField(max_digits=12, decimal_places=3)
    expected_before = models.DecimalField(max_digits=12, decimal_places=3)
    expected_after = models.DecimalField(max_digits=12, decimal_places=3)

    class Meta:
        ordering = ["-created_at", "-id"]

    def __str__(self) -> str:
        return f"{self.variant.sku} {self.movement_type} {self.quantity}"


class StockBatch(TimeStampedModel):
    variant = models.ForeignKey(
        ProductVariant,
        on_delete=models.CASCADE,
        related_name="stock_batches",
    )
    source_receipt_line = models.OneToOneField(
        "purchasing.PurchaseReceiptLine",
        on_delete=models.PROTECT,
        related_name="stock_batch",
    )
    expiry_date = models.DateField(db_index=True)
    received_quantity = models.DecimalField(max_digits=12, decimal_places=3)
    remaining_quantity = models.DecimalField(max_digits=12, decimal_places=3)

    class Meta:
        ordering = ["expiry_date", "created_at", "id"]
        indexes = [
            models.Index(
                fields=["variant", "expiry_date", "remaining_quantity"],
                name="stockbatch_variant_expiry_idx",
            ),
            models.Index(
                fields=["expiry_date", "remaining_quantity"],
                name="stockbatch_exp_remain_idx",
            ),
        ]
        constraints = [
            models.CheckConstraint(
                condition=Q(remaining_quantity__lte=F("received_quantity")),
                name="stock_batch_remaining_lte_received",
            ),
        ]

    def __str__(self) -> str:
        return f"{self.variant.sku} expires {self.expiry_date}"


class StockCount(TimeStampedModel):
    """A physical inventory count session.

    Mirrors the ``RegisterSession`` open->closed lifecycle: a session is opened
    (``in_progress``), counted item-by-item through ``StockCountLine`` rows, then
    either ``applied`` (variances written to stock as ``StockMovement`` rows) or
    ``cancelled``. A user may only have one ``in_progress`` count at a time so the
    "resume" path is unambiguous.
    """

    class Status(models.TextChoices):
        IN_PROGRESS = "in_progress", "In progress"
        APPLIED = "applied", "Applied"
        CANCELLED = "cancelled", "Cancelled"

    class Scope(models.TextChoices):
        FULL = "full", "Full shop"
        CATEGORY = "category", "Single category"

    owner = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="stock_counts",
        blank=True,
        null=True,
    )
    owner_key = models.CharField(max_length=64, db_index=True)
    status = models.CharField(
        max_length=16,
        choices=Status.choices,
        default=Status.IN_PROGRESS,
    )
    scope = models.CharField(
        max_length=16,
        choices=Scope.choices,
        default=Scope.FULL,
    )
    category = models.ForeignKey(
        "catalog.ProductCategory",
        on_delete=models.PROTECT,
        related_name="stock_counts",
        blank=True,
        null=True,
    )
    note = models.CharField(max_length=240, blank=True)
    # Denominator for the "X of Y" progress, frozen at start so the total does
    # not drift if the catalog changes mid-count.
    expected_line_count = models.PositiveIntegerField(default=0)
    applied_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="applied_stock_counts",
        blank=True,
        null=True,
    )
    applied_at = models.DateTimeField(blank=True, null=True)
    cancelled_at = models.DateTimeField(blank=True, null=True)

    class Meta:
        ordering = ["-created_at", "-id"]
        permissions = [
            ("apply_stockcount", "Can apply stock count adjustments"),
        ]
        constraints = [
            models.UniqueConstraint(
                fields=["owner_key"],
                condition=Q(status="in_progress"),
                name="unique_in_progress_stock_count_per_owner",
            )
        ]
        indexes = [
            models.Index(fields=["status", "-created_at"]),
        ]

    def __str__(self) -> str:
        return f"{self.owner_key} {self.status} stock count"

    @property
    def count_number(self) -> str:
        if self.pk is None:
            return "SC"
        return f"SC-{self.pk}"


class StockCountLine(TimeStampedModel):
    stock_count = models.ForeignKey(
        StockCount,
        on_delete=models.CASCADE,
        related_name="lines",
    )
    variant = models.ForeignKey(
        ProductVariant,
        on_delete=models.PROTECT,
        related_name="stock_count_lines",
    )
    counted_quantity = models.DecimalField(max_digits=12, decimal_places=3)
    # Snapshot of on_hand at the moment this line was counted (re-snapshotted on
    # every edit). It backs the variance prompt and the apply-time delta.
    expected_quantity = models.DecimalField(max_digits=12, decimal_places=3)
    counted_at = models.DateTimeField()
    counted_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="stock_count_lines",
        blank=True,
        null=True,
    )
    needs_review = models.BooleanField(default=False)
    movement = models.ForeignKey(
        "inventory.StockMovement",
        on_delete=models.SET_NULL,
        related_name="stock_count_lines",
        blank=True,
        null=True,
    )
    applied = models.BooleanField(default=False)
    # Set at apply time: True when on_hand moved between counted_at and apply
    # (e.g. a sale landed mid-count). We flag, never freeze.
    stale_at_apply = models.BooleanField(default=False)
    on_hand_at_apply = models.DecimalField(
        max_digits=12,
        decimal_places=3,
        blank=True,
        null=True,
    )

    class Meta:
        ordering = ["variant__product__name", "variant__name", "id"]
        constraints = [
            models.UniqueConstraint(
                fields=["stock_count", "variant"],
                name="unique_variant_per_stock_count",
            )
        ]
        indexes = [
            models.Index(fields=["stock_count", "needs_review"]),
        ]

    def __str__(self) -> str:
        return f"{self.stock_count_id}:{self.variant.sku} = {self.counted_quantity}"

    @property
    def variance(self):
        return self.counted_quantity - self.expected_quantity
