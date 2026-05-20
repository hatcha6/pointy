from django.db import models

from apps.core.models import TimeStampedModel


class Product(TimeStampedModel):
    sku = models.CharField(max_length=64, unique=True)
    barcode = models.CharField(max_length=64, blank=True, db_index=True)
    name = models.CharField(max_length=255)
    description = models.TextField(blank=True)
    unit_price = models.DecimalField(max_digits=10, decimal_places=2)
    is_active = models.BooleanField(default=True)
    categories = models.ManyToManyField(
        "ProductCategory",
        blank=True,
        related_name="products",
    )

    class Meta:
        ordering = ["name"]

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
