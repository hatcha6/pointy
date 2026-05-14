from django.db import models

from apps.catalog.models import Product
from apps.core.models import TimeStampedModel


class StockItem(TimeStampedModel):
    product = models.OneToOneField(Product, on_delete=models.CASCADE, related_name="stock")
    quantity_on_hand = models.IntegerField(default=0)
    reorder_level = models.PositiveIntegerField(default=5)

    class Meta:
        ordering = ["product__name"]

    def __str__(self) -> str:
        return f"{self.product.sku}: {self.quantity_on_hand}"
