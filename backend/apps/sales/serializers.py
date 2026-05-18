from datetime import timedelta
from decimal import Decimal

from django.db import transaction
from django.utils import timezone
from rest_framework import serializers

from apps.catalog.models import Product
from apps.core.models import ShopSettings
from apps.core.roles import user_is_manager
from apps.inventory.models import StockItem, StockMovement
from .models import (
    Order,
    OrderAdjustment,
    OrderAdjustmentLine,
    OrderLine,
    RegisterCashMovement,
    RegisterSession,
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


class OrderSerializer(serializers.ModelSerializer):
    lines = OrderLineSerializer(many=True, allow_empty=False)
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
        return self._cashier_window_expired(order)

    def _can_adjust_order(self, order):
        if order.status != Order.Status.PAID:
            return False
        if not any(line.returnable_quantity > 0 for line in order.lines.all()):
            return False
        request = self.context.get("request")
        if request is not None and user_is_manager(request.user):
            return True
        return not self._cashier_window_expired(order)

    def _cashier_window_expired(self, order):
        if order.created_at is None:
            return False
        settings = ShopSettings.load()
        deadline = order.created_at + timedelta(
            hours=settings.cashier_return_window_hours,
        )
        return timezone.now() > deadline

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
        request = self.context.get("request")
        stock_adjustments = self._prepare_stock_adjustments(lines_data)
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
        self._record_sale_stock_movements(order, stock_adjustments, request)

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

    def _prepare_stock_adjustments(self, lines_data):
        settings = ShopSettings.load()
        quantities_by_product = {}
        products_by_id = {}
        for line_data in lines_data:
            product = line_data["product"]
            products_by_id[product.pk] = product
            quantities_by_product[product.pk] = (
                quantities_by_product.get(product.pk, 0) + line_data["quantity"]
            )

        stock_adjustments = []
        shortages = []
        for product_id in sorted(quantities_by_product):
            product = products_by_id[product_id]
            quantity = quantities_by_product[product_id]
            stock_item, _ = StockItem.objects.select_for_update().get_or_create(
                product=product,
            )
            if (
                not settings.allow_overselling
                and stock_item.quantity_on_hand < quantity
            ):
                shortages.append(
                    {
                        "product": product.pk,
                        "product_name": product.name,
                        "requested": quantity,
                        "available": stock_item.quantity_on_hand,
                    }
                )
            stock_adjustments.append((product, stock_item, quantity))

        if shortages:
            raise serializers.ValidationError(
                {
                    "detail": "Insufficient stock for checkout.",
                    "stock": shortages,
                }
            )
        return stock_adjustments

    def _record_sale_stock_movements(self, order, stock_adjustments, request):
        created_by = None
        if request is not None and request.user.is_authenticated:
            created_by = request.user

        for product, stock_item, quantity in stock_adjustments:
            before = {
                "on_hand": stock_item.quantity_on_hand,
                "committed": stock_item.quantity_committed,
                "expected": stock_item.quantity_expected,
            }
            stock_item.quantity_on_hand -= quantity
            stock_item.save(
                update_fields=[
                    "quantity_on_hand",
                    "quantity_committed",
                    "quantity_expected",
                    "updated_at",
                ],
            )
            StockMovement.objects.create(
                product=product,
                stock_item=stock_item,
                movement_type=StockMovement.Type.DECREASE,
                quantity=quantity,
                note=f"بيع {order.receipt_number}",
                created_by=created_by,
                on_hand_before=before["on_hand"],
                on_hand_after=stock_item.quantity_on_hand,
                committed_before=before["committed"],
                committed_after=stock_item.quantity_committed,
                expected_before=before["expected"],
                expected_after=stock_item.quantity_expected,
            )


class OrderAdjustmentLineInputSerializer(serializers.Serializer):
    line = serializers.PrimaryKeyRelatedField(queryset=OrderLine.objects.all())
    quantity = serializers.IntegerField(min_value=1)


class OrderAdjustmentSerializer(serializers.Serializer):
    reason = serializers.CharField(required=False, allow_blank=True, trim_whitespace=True)

    def validate(self, attrs):
        order = self.context["order"]
        if order.status != Order.Status.PAID:
            raise serializers.ValidationError(
                {"detail": "Only paid orders can be adjusted."}
            )
        if order.register_session is None:
            raise serializers.ValidationError(
                {"detail": "Order is not linked to a register session."}
            )
        request = self.context.get("request")
        if (
            request is not None
            and not user_is_manager(request.user)
            and self._cashier_window_expired(order)
        ):
            raise serializers.ValidationError(
                {"detail": "This order requires manager approval to adjust."}
            )
        return attrs

    def _cashier_window_expired(self, order):
        if order.created_at is None:
            return False
        settings = ShopSettings.load()
        deadline = order.created_at + timedelta(
            hours=settings.cashier_return_window_hours,
        )
        return timezone.now() > deadline

    def _refund_method(self, order):
        payment = order.payments.order_by("created_at").first()
        if payment is None:
            from apps.payments.models import Payment

            return Payment.Method.CASH
        return payment.method

    def _adjustment_register_session(self, order):
        return self.context.get("adjustment_register_session") or order.register_session

    def _create_adjustment(self, *, order, adjustment_type, lines, reason):
        from apps.payments.models import Payment

        request = self.context.get("request")
        created_by = request.user if request is not None and request.user.is_authenticated else None
        refund_method = self._refund_method(order)
        amount = sum(
            (line.unit_price * quantity for line, quantity in lines),
            Decimal("0.00"),
        ).quantize(Decimal("0.01"))
        if amount <= 0:
            raise serializers.ValidationError(
                {"detail": "Adjustment amount must be positive."}
            )

        adjustment = OrderAdjustment.objects.create(
            order=order,
            register_session=self._adjustment_register_session(order),
            adjustment_type=adjustment_type,
            amount=amount,
            refund_method=refund_method,
            reason=reason,
            created_by=created_by,
        )

        for line, quantity in lines:
            OrderAdjustmentLine.objects.create(
                adjustment=adjustment,
                order_line=line,
                product=line.product,
                quantity=quantity,
                unit_price=line.unit_price,
            )
            self._record_return_stock_movement(
                order=order,
                product=line.product,
                quantity=quantity,
                created_by=created_by,
            )

        Payment.objects.create(
            order=order,
            method=refund_method,
            amount=-amount,
            external_reference=f"{adjustment.adjustment_type}:{adjustment.pk}",
        )
        return adjustment

    def _record_return_stock_movement(self, *, order, product, quantity, created_by):
        stock_item, _ = StockItem.objects.select_for_update().get_or_create(
            product=product,
        )
        before = {
            "on_hand": stock_item.quantity_on_hand,
            "committed": stock_item.quantity_committed,
            "expected": stock_item.quantity_expected,
        }
        stock_item.quantity_on_hand += quantity
        stock_item.save(
            update_fields=[
                "quantity_on_hand",
                "quantity_committed",
                "quantity_expected",
                "updated_at",
            ],
        )
        StockMovement.objects.create(
            product=product,
            stock_item=stock_item,
            movement_type=StockMovement.Type.INCREASE,
            quantity=quantity,
            note=f"مرتجع {order.receipt_number}",
            created_by=created_by,
            on_hand_before=before["on_hand"],
            on_hand_after=stock_item.quantity_on_hand,
            committed_before=before["committed"],
            committed_after=stock_item.quantity_committed,
            expected_before=before["expected"],
            expected_after=stock_item.quantity_expected,
        )


class OrderVoidSerializer(OrderAdjustmentSerializer):
    @transaction.atomic
    def save(self, **kwargs):
        order = (
            Order.objects.select_for_update()
            .select_related("register_session")
            .prefetch_related("lines__product")
            .get(pk=self.context["order"].pk)
        )
        lines = [
            (line, line.returnable_quantity)
            for line in order.lines.select_related("product")
            if line.returnable_quantity > 0
        ]
        if not lines:
            raise serializers.ValidationError(
                {"detail": "No remaining items can be voided."}
            )

        adjustment = self._create_adjustment(
            order=order,
            adjustment_type=OrderAdjustment.AdjustmentType.VOID,
            lines=lines,
            reason=self.validated_data.get("reason", ""),
        )
        order.status = Order.Status.VOID
        order.save(update_fields=["status", "updated_at"])
        return adjustment


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
            requested_by_line[line.pk] = requested_by_line.get(line.pk, 0) + line_data["quantity"]

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

    @transaction.atomic
    def save(self, **kwargs):
        order = Order.objects.select_for_update().select_related("register_session").get(
            pk=self.context["order"].pk,
        )
        adjustment = self._create_adjustment(
            order=order,
            adjustment_type=OrderAdjustment.AdjustmentType.RETURN,
            lines=self.validated_data["validated_lines"],
            reason=self.validated_data.get("reason", ""),
        )

        if all(line.returnable_quantity == 0 for line in order.lines.all()):
            order.status = Order.Status.VOID
            order.save(update_fields=["status", "updated_at"])
        return adjustment
