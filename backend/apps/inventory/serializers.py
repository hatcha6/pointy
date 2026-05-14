from rest_framework import serializers

from apps.catalog.serializers import ProductSerializer
from .models import StockItem


class StockItemSerializer(serializers.ModelSerializer):
    product_detail = ProductSerializer(source="product", read_only=True)

    class Meta:
        model = StockItem
        fields = [
            "id",
            "product",
            "product_detail",
            "quantity_on_hand",
            "reorder_level",
            "created_at",
            "updated_at",
        ]
        read_only_fields = ("created_at", "updated_at")
