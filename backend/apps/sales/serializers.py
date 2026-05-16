from decimal import Decimal

from django.db import transaction
from rest_framework import serializers

from apps.catalog.models import Product
from .models import Order, OrderLine, RegisterSession


class RegisterSessionSerializer(serializers.ModelSerializer):
    class Meta:
        model = RegisterSession
        fields = [
            "id",
            "session_number",
            "status",
            "opening_cash",
            "closing_cash",
            "count_025",
            "count_050",
            "count_075",
            "count_100",
            "opened_at",
            "closed_at",
            "created_at",
            "updated_at",
        ]
        read_only_fields = (
            "id",
            "session_number",
            "status",
            "closing_cash",
            "count_025",
            "count_050",
            "count_075",
            "count_100",
            "opened_at",
            "closed_at",
            "created_at",
            "updated_at",
        )


class RegisterSessionStartSerializer(serializers.Serializer):
    opening_cash = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        min_value=0,
        required=False,
    )


class RegisterSessionCloseSerializer(serializers.Serializer):
    closing_cash = serializers.DecimalField(max_digits=10, decimal_places=2, min_value=0)
    count_025 = serializers.IntegerField(min_value=0)
    count_050 = serializers.IntegerField(min_value=0)
    count_075 = serializers.IntegerField(min_value=0)
    count_100 = serializers.IntegerField(min_value=0)


class OrderLineSerializer(serializers.ModelSerializer):
    product_name = serializers.CharField(source="product.name", read_only=True)
    line_total = serializers.DecimalField(max_digits=10, decimal_places=2, read_only=True)

    class Meta:
        model = OrderLine
        fields = ["id", "product", "product_name", "quantity", "unit_price", "line_total"]
        read_only_fields = ("unit_price",)

    def validate_quantity(self, value):
        if value < 1:
            raise serializers.ValidationError("Quantity must be positive.")
        return value


class OrderSerializer(serializers.ModelSerializer):
    lines = OrderLineSerializer(many=True, allow_empty=False)
    register_session_number = serializers.CharField(
        source="register_session.session_number",
        read_only=True,
    )

    class Meta:
        model = Order
        fields = [
            "id",
            "receipt_number",
            "status",
            "register_session",
            "register_session_number",
            "lines",
            "subtotal",
            "total",
            "created_at",
            "updated_at",
        ]
        read_only_fields = (
            "receipt_number",
            "register_session",
            "register_session_number",
            "subtotal",
            "total",
            "created_at",
            "updated_at",
        )

    @transaction.atomic
    def create(self, validated_data):
        lines_data = validated_data.pop("lines", [])
        order = Order.objects.create(**validated_data)
        for line_data in lines_data:
            product = line_data["product"]
            OrderLine.objects.create(
                order=order,
                product=product,
                quantity=line_data["quantity"],
                unit_price=product.unit_price,
            )
        order.recalculate()
        order.save(update_fields=["subtotal", "total", "updated_at"])
        return order


class CheckoutLineSerializer(serializers.Serializer):
    product = serializers.PrimaryKeyRelatedField(queryset=Product.objects.all())
    quantity = serializers.IntegerField(min_value=1)


class CheckoutSerializer(serializers.Serializer):
    lines = CheckoutLineSerializer(many=True, allow_empty=False)
    payment_method = serializers.ChoiceField(required=False, choices=[])
    amount_received = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        min_value=Decimal("0.00"),
        required=False,
    )

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        from apps.payments.models import Payment

        self.fields["payment_method"].choices = Payment.Method.choices
        self.fields["payment_method"].default = Payment.Method.CASH

    def validate(self, attrs):
        total = Decimal("0.00")
        for line in attrs["lines"]:
            total += line["product"].unit_price * line["quantity"]
        total = total.quantize(Decimal("0.01"))

        amount_received = attrs.get("amount_received", total)
        if amount_received < total:
            raise serializers.ValidationError(
                {"amount_received": "Amount received must cover the order total."}
            )

        attrs["computed_total"] = total
        attrs["amount_received"] = amount_received
        return attrs

    @transaction.atomic
    def create(self, validated_data):
        from apps.payments.models import Payment
        from apps.payments.serializers import PaymentSerializer

        lines_data = validated_data["lines"]
        register_session = self.context["register_session"]
        order = Order.objects.create(register_session=register_session)

        for line_data in lines_data:
            product = line_data["product"]
            OrderLine.objects.create(
                order=order,
                product=product,
                quantity=line_data["quantity"],
                unit_price=product.unit_price,
            )

        order.recalculate()
        order.save(update_fields=["subtotal", "total", "updated_at"])

        payment_serializer = PaymentSerializer(
            data={
                "order": order.pk,
                "method": validated_data.get("payment_method", Payment.Method.CASH),
                "amount": validated_data["amount_received"],
            }
        )
        payment_serializer.is_valid(raise_exception=True)
        payment_serializer.save()
        order.refresh_from_db()
        return order
