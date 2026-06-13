from django.utils import timezone
from rest_framework import serializers

from apps.sales.models import OrderAdjustment, OrderAdjustmentLine
from .models import Customer


class CustomerSerializer(serializers.ModelSerializer):
    class Meta:
        model = Customer
        fields = [
            "id",
            "customer_number",
            "full_name",
            "phone",
            "email",
            "gender",
            "birthday",
            "marketing_consent",
            "notes",
            "is_active",
            "created_at",
            "updated_at",
        ]
        read_only_fields = ("id", "customer_number", "created_at", "updated_at")

    def validate_birthday(self, value):
        if value and value > timezone.localdate():
            raise serializers.ValidationError("Birthday cannot be in the future.")
        return value


class CustomerOrderAdjustmentLineSerializer(serializers.ModelSerializer):
    product = serializers.IntegerField(source="variant.product_id", read_only=True)
    variant = serializers.IntegerField(source="variant_id", read_only=True)
    product_name = serializers.CharField(source="variant.product.name", read_only=True)
    variant_name = serializers.CharField(source="variant.display_name", read_only=True)
    line_total = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        read_only=True,
    )

    quantity = serializers.DecimalField(
        max_digits=10,
        decimal_places=3,
        coerce_to_string=False,
        read_only=True,
    )

    class Meta:
        model = OrderAdjustmentLine
        fields = [
            "id",
            "order_line",
            "product",
            "variant",
            "product_name",
            "variant_name",
            "quantity",
            "unit_price",
            "discount_total",
            "line_total",
        ]
        read_only_fields = fields


class CustomerOrderAdjustmentSerializer(serializers.ModelSerializer):
    order = serializers.IntegerField(source="order_id", read_only=True)
    receipt_number = serializers.CharField(
        source="order.receipt_number",
        read_only=True,
    )
    customer = serializers.IntegerField(source="order.customer_id", read_only=True)
    register_session = serializers.IntegerField(
        source="register_session_id",
        read_only=True,
    )
    register_session_number = serializers.CharField(
        source="register_session.session_number",
        read_only=True,
    )
    created_by_username = serializers.CharField(
        source="created_by.username",
        read_only=True,
    )
    lines = CustomerOrderAdjustmentLineSerializer(many=True, read_only=True)

    class Meta:
        model = OrderAdjustment
        fields = [
            "id",
            "order",
            "receipt_number",
            "customer",
            "register_session",
            "register_session_number",
            "adjustment_type",
            "amount",
            "refund_method",
            "reason",
            "created_by",
            "created_by_username",
            "lines",
            "created_at",
            "updated_at",
        ]
        read_only_fields = fields
