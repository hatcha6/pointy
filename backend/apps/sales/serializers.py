from django.db import transaction
from rest_framework import serializers

from apps.catalog.models import Product
from .models import Order, OrderLine


class OrderLineSerializer(serializers.ModelSerializer):
    product_name = serializers.CharField(source="product.name", read_only=True)
    line_total = serializers.DecimalField(max_digits=10, decimal_places=2, read_only=True)

    class Meta:
        model = OrderLine
        fields = ["id", "product", "product_name", "quantity", "unit_price", "tax_rate", "line_total"]
        read_only_fields = ("unit_price", "tax_rate")


class OrderSerializer(serializers.ModelSerializer):
    lines = OrderLineSerializer(many=True)

    class Meta:
        model = Order
        fields = [
            "id",
            "receipt_number",
            "status",
            "lines",
            "subtotal",
            "tax_total",
            "total",
            "created_at",
            "updated_at",
        ]
        read_only_fields = ("receipt_number", "subtotal", "tax_total", "total", "created_at", "updated_at")

    @transaction.atomic
    def create(self, validated_data):
        lines_data = validated_data.pop("lines", [])
        order = Order.objects.create(**validated_data)
        for line_data in lines_data:
            product = Product.objects.get(pk=line_data["product"].pk)
            OrderLine.objects.create(
                order=order,
                product=product,
                quantity=line_data["quantity"],
                unit_price=product.unit_price,
                tax_rate=product.tax_rate,
            )
        order.recalculate()
        order.save(update_fields=["subtotal", "tax_total", "total", "updated_at"])
        return order
