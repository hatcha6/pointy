from rest_framework import serializers

from apps.catalog.models import ProductVariant
from apps.catalog.serializers import ProductCatalogSerializer
from .models import StockItem, StockMovement


class StockItemSerializer(serializers.ModelSerializer):
    product_detail = ProductCatalogSerializer(source="variant.product", read_only=True)
    product = serializers.IntegerField(source="variant.product_id", read_only=True)
    variant = serializers.PrimaryKeyRelatedField(
        queryset=ProductVariant.objects.all(),
    )
    variant_sku = serializers.CharField(source="variant.sku", read_only=True)
    variant_name = serializers.CharField(source="variant.display_name", read_only=True)
    variant_full_name = serializers.CharField(source="variant.full_name", read_only=True)

    quantity_on_hand = serializers.DecimalField(
        max_digits=12,
        decimal_places=3,
        coerce_to_string=False,
        required=False,
    )
    quantity_committed = serializers.DecimalField(
        max_digits=12,
        decimal_places=3,
        coerce_to_string=False,
        required=False,
    )
    quantity_expected = serializers.DecimalField(
        max_digits=12,
        decimal_places=3,
        coerce_to_string=False,
        required=False,
    )

    class Meta:
        model = StockItem
        fields = [
            "id",
            "product",
            "variant",
            "variant_sku",
            "variant_name",
            "variant_full_name",
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
        attrs = self._with_variant(attrs)
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

    def _with_variant(self, attrs):
        variant = attrs.get("variant", getattr(self.instance, "variant", None))
        if variant is None:
            raise serializers.ValidationError({"variant": "Variant is required."})
        attrs["variant"] = variant
        return attrs


class StockMovementSerializer(serializers.ModelSerializer):
    product_detail = ProductCatalogSerializer(source="variant.product", read_only=True)
    product = serializers.IntegerField(source="variant.product_id", read_only=True)
    variant = serializers.PrimaryKeyRelatedField(
        queryset=ProductVariant.objects.all(),
    )
    variant_sku = serializers.CharField(source="variant.sku", read_only=True)
    variant_name = serializers.CharField(source="variant.display_name", read_only=True)
    variant_full_name = serializers.CharField(source="variant.full_name", read_only=True)
    created_by_name = serializers.CharField(source="created_by.username", read_only=True)

    class Meta:
        model = StockMovement
        fields = [
            "id",
            "product",
            "variant",
            "variant_sku",
            "variant_name",
            "variant_full_name",
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

    quantity = serializers.DecimalField(
        max_digits=12,
        decimal_places=3,
        coerce_to_string=False,
    )
    on_hand_before = serializers.FloatField(read_only=True)
    on_hand_after = serializers.FloatField(read_only=True)
    committed_before = serializers.FloatField(read_only=True)
    committed_after = serializers.FloatField(read_only=True)
    expected_before = serializers.FloatField(read_only=True)
    expected_after = serializers.FloatField(read_only=True)

    def validate_quantity(self, value):
        if value <= 0:
            raise serializers.ValidationError("Quantity must be positive.")
        return value

    def validate(self, attrs):
        variant = attrs.get("variant")
        if variant is None:
            raise serializers.ValidationError({"variant": "Variant is required."})
        attrs["variant"] = variant
        return attrs
