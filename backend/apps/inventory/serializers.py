from rest_framework import serializers

from apps.catalog.serializers import ProductSerializer
from .models import StockItem, StockMovement


class StockItemSerializer(serializers.ModelSerializer):
    product_detail = ProductSerializer(source="product", read_only=True)

    class Meta:
        model = StockItem
        fields = [
            "id",
            "product",
            "product_detail",
            "quantity_on_hand",
            "quantity_committed",
            "quantity_expected",
            "reorder_level",
            "created_at",
            "updated_at",
        ]
        read_only_fields = ("created_at", "updated_at")

    def validate(self, attrs):
        for field in (
            "quantity_on_hand",
            "quantity_committed",
            "quantity_expected",
            "reorder_level",
        ):
            value = attrs.get(field)
            if value is not None and value < 0:
                raise serializers.ValidationError(
                    {field: "Quantity cannot be negative."}
                )
        return attrs


class StockMovementSerializer(serializers.ModelSerializer):
    product_detail = ProductSerializer(source="product", read_only=True)
    created_by_name = serializers.CharField(source="created_by.username", read_only=True)

    class Meta:
        model = StockMovement
        fields = [
            "id",
            "product",
            "product_detail",
            "stock_item",
            "movement_type",
            "quantity",
            "note",
            "created_by",
            "created_by_name",
            "on_hand_before",
            "on_hand_after",
            "committed_before",
            "committed_after",
            "expected_before",
            "expected_after",
            "created_at",
            "updated_at",
        ]
        read_only_fields = [
            "id",
            "stock_item",
            "created_by",
            "created_by_name",
            "on_hand_before",
            "on_hand_after",
            "committed_before",
            "committed_after",
            "expected_before",
            "expected_after",
            "created_at",
            "updated_at",
        ]

    def validate_quantity(self, value):
        if value <= 0:
            raise serializers.ValidationError("Quantity must be positive.")
        return value
