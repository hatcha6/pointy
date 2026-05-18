from django.db import models

from apps.catalog.models import Product
from apps.core.models import TimeStampedModel


class StockItem(TimeStampedModel):
    product = models.OneToOneField(Product, on_delete=models.CASCADE, related_name="stock")
    quantity_on_hand = models.IntegerField(default=0)
    quantity_committed = models.IntegerField(default=0)
    quantity_expected = models.IntegerField(default=0)
    reorder_level = models.PositiveIntegerField(default=5)

    class Meta:
        ordering = ["product__name"]

    def __str__(self) -> str:
        return f"{self.product.sku}: {self.quantity_on_hand}"


class StockMovement(TimeStampedModel):
    class Type(models.TextChoices):
        INCREASE = "increase", "Increase stock"
        DECREASE = "decrease", "Decrease stock"
        DAMAGED = "damaged", "Damaged stock"

    product = models.ForeignKey(
        Product,
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

    def __str__(self) -> str:
        return f"{self.product.sku} {self.movement_type} {self.quantity}"
