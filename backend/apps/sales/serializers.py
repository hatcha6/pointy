from decimal import Decimal

from rest_framework import serializers

from apps.catalog.models import Product
from apps.core.models import ShopSettings
from apps.core.roles import user_is_manager
from .models import (
    Order,
    OrderLine,
    RegisterCashMovement,
    RegisterSession,
)
from .services import (
    cashier_window_expired,
    can_adjust_order,
    checkout_order,
    create_order_with_lines,
    return_order_items,
    validate_order_adjustment_allowed,
    void_order,
)


class RegisterSessionSerializer(serializers.ModelSerializer):
    reconciliation_fields = (
        "cash_sales_total",
        "pay_in_total",
        "pay_out_total",
        "cash_refund_total",
        "expected_cash",
        "denomination_total",
        "cash_variance",
        "has_cash_variance",
    )

    cash_sales_total = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        read_only=True,
    )
    pay_in_total = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        read_only=True,
    )
    pay_out_total = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        read_only=True,
    )
    cash_refund_total = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        read_only=True,
    )
    expected_cash = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        read_only=True,
    )
    denomination_total = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        read_only=True,
    )
    cash_variance = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        read_only=True,
        allow_null=True,
    )

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
            "cash_sales_total",
            "pay_in_total",
            "pay_out_total",
            "cash_refund_total",
            "expected_cash",
            "denomination_total",
            "cash_variance",
            "has_cash_variance",
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
            "cash_sales_total",
            "pay_in_total",
            "pay_out_total",
            "cash_refund_total",
            "expected_cash",
            "denomination_total",
            "cash_variance",
            "has_cash_variance",
            "opened_at",
            "closed_at",
            "created_at",
            "updated_at",
        )

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        request = self.context.get("request")
        if request is None or not user_is_manager(request.user):
            for field in self.reconciliation_fields:
                self.fields.pop(field, None)


class RegisterSessionStartSerializer(serializers.Serializer):
    opening_cash = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        min_value=0,
        required=False,
    )

    def validate(self, attrs):
        if ShopSettings.load().require_opening_cash and "opening_cash" not in attrs:
            raise serializers.ValidationError(
                {"opening_cash": "Opening cash is required."}
            )
        return attrs


class RegisterSessionCloseSerializer(serializers.Serializer):
    closing_cash = serializers.DecimalField(max_digits=10, decimal_places=2, min_value=0)
    count_025 = serializers.IntegerField(min_value=0)
    count_050 = serializers.IntegerField(min_value=0)
    count_075 = serializers.IntegerField(min_value=0)
    count_100 = serializers.IntegerField(min_value=0)


class RegisterCashMovementSerializer(serializers.ModelSerializer):
    created_by_username = serializers.CharField(
        source="created_by.username",
        read_only=True,
    )
    session_number = serializers.CharField(
        source="register_session.session_number",
        read_only=True,
    )

    class Meta:
        model = RegisterCashMovement
        fields = [
            "id",
            "register_session",
            "session_number",
            "movement_type",
            "amount",
            "reason",
            "created_by",
            "created_by_username",
            "created_at",
            "updated_at",
        ]
        read_only_fields = (
            "id",
            "register_session",
            "session_number",
            "movement_type",
            "created_by",
            "created_by_username",
            "created_at",
            "updated_at",
        )


class RegisterCashMovementCreateSerializer(serializers.Serializer):
    amount = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        min_value=Decimal("0.01"),
    )
    reason = serializers.CharField(trim_whitespace=True, allow_blank=False)


class OrderLineSerializer(serializers.ModelSerializer):
    product_name = serializers.CharField(source="product.name", read_only=True)
    line_total = serializers.DecimalField(max_digits=10, decimal_places=2, read_only=True)
    returned_quantity = serializers.IntegerField(read_only=True)
    returnable_quantity = serializers.IntegerField(read_only=True)

    class Meta:
        model = OrderLine
        fields = [
            "id",
            "product",
            "product_name",
            "quantity",
            "returned_quantity",
            "returnable_quantity",
            "unit_price",
            "line_total",
        ]
        read_only_fields = ("unit_price",)

    def validate_quantity(self, value):
        if value < 1:
            raise serializers.ValidationError("Quantity must be positive.")
        return value


class OrderPaymentSerializer(serializers.Serializer):
    id = serializers.IntegerField(read_only=True)
    method = serializers.CharField(read_only=True)
    amount = serializers.DecimalField(max_digits=10, decimal_places=2, read_only=True)
    commission_percent = serializers.DecimalField(
        max_digits=5,
        decimal_places=2,
        read_only=True,
    )
    commission_amount = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        read_only=True,
    )
    external_reference = serializers.CharField(read_only=True)
    created_at = serializers.DateTimeField(read_only=True)


class OrderSerializer(serializers.ModelSerializer):
    lines = OrderLineSerializer(many=True, allow_empty=False)
    payments = OrderPaymentSerializer(many=True, read_only=True)
    register_session_number = serializers.CharField(
        source="register_session.session_number",
        read_only=True,
    )
    can_void = serializers.SerializerMethodField()
    can_return = serializers.SerializerMethodField()
    requires_manager_adjustment = serializers.SerializerMethodField()

    class Meta:
        model = Order
        fields = [
            "id",
            "receipt_number",
            "status",
            "register_session",
            "register_session_number",
            "lines",
            "payments",
            "subtotal",
            "total",
            "can_void",
            "can_return",
            "requires_manager_adjustment",
            "created_at",
            "updated_at",
        ]
        read_only_fields = (
            "receipt_number",
            "register_session",
            "register_session_number",
            "subtotal",
            "total",
            "can_void",
            "can_return",
            "requires_manager_adjustment",
            "created_at",
            "updated_at",
        )

    def get_can_void(self, order):
        return self._can_adjust_order(order)

    def get_can_return(self, order):
        return self._can_adjust_order(order)

    def get_requires_manager_adjustment(self, order):
        return cashier_window_expired(order)

    def _can_adjust_order(self, order):
        request = self.context.get("request")
        return can_adjust_order(order, request.user if request is not None else None)

    def create(self, validated_data):
        lines_data = validated_data.pop("lines", [])
        return create_order_with_lines(lines_data=lines_data, **validated_data)


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
        payment_method = attrs.get("payment_method")
        if payment_method is not None and not ShopSettings.load().payment_method_enabled(
            payment_method
        ):
            raise serializers.ValidationError(
                {"payment_method": "Payment method is disabled."}
            )
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

    def create(self, validated_data):
        from apps.payments.models import Payment

        return checkout_order(
            register_session=self.context["register_session"],
            lines_data=validated_data["lines"],
            payment_method=validated_data.get("payment_method", Payment.Method.CASH),
            amount_received=validated_data["amount_received"],
            request=self.context.get("request"),
        )


class OrderAdjustmentLineInputSerializer(serializers.Serializer):
    line = serializers.PrimaryKeyRelatedField(queryset=OrderLine.objects.all())
    quantity = serializers.IntegerField(min_value=1)


class OrderAdjustmentSerializer(serializers.Serializer):
    reason = serializers.CharField(required=False, allow_blank=True, trim_whitespace=True)

    def validate(self, attrs):
        order = self.context["order"]
        validate_order_adjustment_allowed(
            order,
            request=self.context.get("request"),
        )
        return attrs


class OrderVoidSerializer(OrderAdjustmentSerializer):
    def save(self, **kwargs):
        return void_order(
            order=self.context["order"],
            reason=self.validated_data.get("reason", ""),
            request=self.context.get("request"),
            register_session=self.context.get("adjustment_register_session"),
        )


class OrderReturnSerializer(OrderAdjustmentSerializer):
    lines = OrderAdjustmentLineInputSerializer(many=True, allow_empty=False)

    def validate(self, attrs):
        attrs = super().validate(attrs)
        order = self.context["order"]
        requested_by_line = {}
        for line_data in attrs["lines"]:
            line = line_data["line"]
            if line.order_id != order.pk:
                raise serializers.ValidationError(
                    {"lines": "Return line does not belong to this order."}
                )
            requested_by_line[line.pk] = (
                requested_by_line.get(line.pk, 0) + line_data["quantity"]
            )

        lines_by_id = {
            line.pk: line
            for line in OrderLine.objects.filter(
                pk__in=requested_by_line,
                order=order,
            ).select_related("product")
        }
        validated_lines = []
        for line_id, quantity in requested_by_line.items():
            line = lines_by_id[line_id]
            if quantity > line.returnable_quantity:
                raise serializers.ValidationError(
                    {
                        "lines": (
                            f"Cannot return more than {line.returnable_quantity} "
                            "remaining items."
                        )
                    }
                )
            validated_lines.append((line, quantity))

        attrs["validated_lines"] = validated_lines
        return attrs

    def save(self, **kwargs):
        return return_order_items(
            order=self.context["order"],
            lines=self.validated_data["validated_lines"],
            reason=self.validated_data.get("reason", ""),
            request=self.context.get("request"),
            register_session=self.context.get("adjustment_register_session"),
        )
