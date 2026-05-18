from rest_framework import serializers

from .models import Product


class ProductSerializer(serializers.ModelSerializer):
    quantity_on_hand = serializers.SerializerMethodField()

    class Meta:
        model = Product
        fields = [
            "id",
            "sku",
            "barcode",
            "name",
            "description",
            "unit_price",
            "is_active",
            "quantity_on_hand",
            "created_at",
            "updated_at",
        ]
        read_only_fields = ("created_at", "updated_at")

    def validate_unit_price(self, value):
        if value < 0:
            raise serializers.ValidationError("Unit price cannot be negative.")
        return value

    def validate_sku(self, value):
        return value.strip().upper()

    def get_quantity_on_hand(self, product):
        try:
            return product.stock.quantity_on_hand
        except Product.stock.RelatedObjectDoesNotExist:
            return 0
