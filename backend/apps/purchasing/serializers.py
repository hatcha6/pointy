from decimal import Decimal

from rest_framework import serializers

from .models import (
    PurchaseLine,
    PurchaseOrder,
    PurchaseOrderAdjustment,
    PurchaseOrderAdjustmentLine,
    Supplier,
)
from .services import (
    adjust_purchase_order_items,
    latest_purchase_line_for_product,
    save_purchase_order_with_lines,
    validate_purchase_order_adjustment_allowed,
)


class SupplierSerializer(serializers.ModelSerializer):
    class Meta:
        model = Supplier
        fields = [
            "id",
            "name",
            "contact_name",
            "phone",
            "email",
            "address",
            "notes",
            "is_active",
            "created_at",
            "updated_at",
        ]
        read_only_fields = ("id", "created_at", "updated_at")


class PurchaseLineSerializer(serializers.ModelSerializer):
    product_name = serializers.CharField(source="product.name", read_only=True)
    product_sku = serializers.CharField(source="product.sku", read_only=True)
    line_total = serializers.DecimalField(max_digits=10, decimal_places=2, read_only=True)
    previous_unit_cost = serializers.SerializerMethodField()
    unit_cost_change = serializers.SerializerMethodField()
    unit_cost_change_percent = serializers.SerializerMethodField()
    unit_cost_changed = serializers.SerializerMethodField()
    adjusted_quantity = serializers.IntegerField(read_only=True)
    adjustable_quantity = serializers.IntegerField(read_only=True)

    class Meta:
        model = PurchaseLine
        fields = [
            "id",
            "product",
            "product_name",
            "product_sku",
            "quantity",
            "adjusted_quantity",
            "adjustable_quantity",
            "unit_cost",
            "previous_unit_cost",
            "unit_cost_change",
            "unit_cost_change_percent",
            "unit_cost_changed",
            "line_total",
        ]
        read_only_fields = (
            "id",
            "product_name",
            "product_sku",
            "previous_unit_cost",
            "unit_cost_change",
            "unit_cost_change_percent",
            "unit_cost_changed",
            "adjusted_quantity",
            "adjustable_quantity",
            "line_total",
        )

    def get_previous_unit_cost(self, line):
        previous_cost = self._previous_unit_cost(line)
        return None if previous_cost is None else money_string(previous_cost)

    def get_unit_cost_change(self, line):
        previous_cost = self._previous_unit_cost(line)
        if previous_cost is None:
            return None
        return money_string(line.unit_cost - previous_cost)

    def get_unit_cost_change_percent(self, line):
        previous_cost = self._previous_unit_cost(line)
        if previous_cost in (None, Decimal("0.00")):
            return None
        percent = ((line.unit_cost - previous_cost) / previous_cost * Decimal("100"))
        return money_string(percent)

    def get_unit_cost_changed(self, line):
        previous_cost = self._previous_unit_cost(line)
        return False if previous_cost is None else line.unit_cost != previous_cost

    def _previous_unit_cost(self, line):
        if not hasattr(self, "_previous_unit_cost_cache"):
            self._previous_unit_cost_cache = {}
        if line.pk not in self._previous_unit_cost_cache:
            previous_line = latest_purchase_line_for_product(
                line.product_id,
                before_line=line,
            )
            self._previous_unit_cost_cache[line.pk] = (
                None if previous_line is None else previous_line.unit_cost
            )
        return self._previous_unit_cost_cache[line.pk]

    def validate_quantity(self, value):
        if value < 1:
            raise serializers.ValidationError("Quantity must be positive.")
        return value

    def validate_unit_cost(self, value):
        if value < Decimal("0.00"):
            raise serializers.ValidationError("Unit cost cannot be negative.")
        return value


def money_string(value):
    return str(value.quantize(Decimal("0.01")))


class PurchaseOrderAdjustmentLineSerializer(serializers.ModelSerializer):
    product_name = serializers.CharField(source="product.name", read_only=True)
    line_total = serializers.DecimalField(max_digits=10, decimal_places=2, read_only=True)

    class Meta:
        model = PurchaseOrderAdjustmentLine
        fields = [
            "id",
            "purchase_line",
            "product",
            "product_name",
            "quantity",
            "unit_cost",
            "line_total",
        ]
        read_only_fields = fields


class PurchaseOrderAdjustmentSerializer(serializers.ModelSerializer):
    lines = PurchaseOrderAdjustmentLineSerializer(many=True, read_only=True)
    created_by_username = serializers.CharField(
        source="created_by.username",
        read_only=True,
    )

    class Meta:
        model = PurchaseOrderAdjustment
        fields = [
            "id",
            "adjustment_type",
            "amount",
            "reason",
            "created_by",
            "created_by_username",
            "lines",
            "created_at",
            "updated_at",
        ]
        read_only_fields = fields


class PurchaseOrderSerializer(serializers.ModelSerializer):
    lines = PurchaseLineSerializer(many=True, allow_empty=False)
    adjustments = PurchaseOrderAdjustmentSerializer(many=True, read_only=True)
    supplier_name = serializers.CharField(source="supplier.name", read_only=True)
    can_return = serializers.SerializerMethodField()
    can_refund = serializers.SerializerMethodField()
    can_exchange = serializers.SerializerMethodField()

    class Meta:
        model = PurchaseOrder
        fields = [
            "id",
            "order_number",
            "supplier",
            "supplier_name",
            "supplier_reference",
            "status",
            "notes",
            "lines",
            "adjustments",
            "subtotal",
            "total",
            "can_return",
            "can_refund",
            "can_exchange",
            "submitted_at",
            "received_at",
            "created_at",
            "updated_at",
        ]
        read_only_fields = (
            "id",
            "order_number",
            "supplier_name",
            "status",
            "adjustments",
            "subtotal",
            "total",
            "can_return",
            "can_refund",
            "can_exchange",
            "submitted_at",
            "received_at",
            "created_at",
            "updated_at",
        )

    def get_can_return(self, purchase_order):
        return self._can_adjust(purchase_order)

    def get_can_refund(self, purchase_order):
        return self._can_adjust(purchase_order)

    def get_can_exchange(self, purchase_order):
        return self._can_adjust(purchase_order)

    def _can_adjust(self, purchase_order):
        try:
            validate_purchase_order_adjustment_allowed(purchase_order)
        except serializers.ValidationError:
            return False
        return True

    def validate_lines(self, value):
        product_ids = [line["product"].pk for line in value]
        if len(product_ids) != len(set(product_ids)):
            raise serializers.ValidationError(
                "Each product can appear only once per purchase order."
            )
        return value

    def create(self, validated_data):
        lines_data = validated_data.pop("lines", [])
        return save_purchase_order_with_lines(
            lines_data=lines_data,
            **validated_data,
        )

    def update(self, instance, validated_data):
        lines_data = validated_data.pop("lines", None)
        return save_purchase_order_with_lines(
            purchase_order=instance,
            lines_data=lines_data,
            **validated_data,
        )


class PurchaseOrderAdjustmentLineInputSerializer(serializers.Serializer):
    line = serializers.PrimaryKeyRelatedField(queryset=PurchaseLine.objects.all())
    quantity = serializers.IntegerField(min_value=1)


class PurchaseOrderAdjustmentInputSerializer(serializers.Serializer):
    lines = PurchaseOrderAdjustmentLineInputSerializer(many=True, allow_empty=False)
    reason = serializers.CharField(required=False, allow_blank=True, trim_whitespace=True)
    adjustment_type = PurchaseOrderAdjustment.AdjustmentType.RETURN

    def validate(self, attrs):
        purchase_order = self.context["purchase_order"]
        validate_purchase_order_adjustment_allowed(purchase_order)

        requested_by_line = {}
        for line_data in attrs["lines"]:
            line = line_data["line"]
            if line.purchase_order_id != purchase_order.pk:
                raise serializers.ValidationError(
                    {"lines": "Adjustment line does not belong to this purchase order."}
                )
            requested_by_line[line.pk] = (
                requested_by_line.get(line.pk, 0) + line_data["quantity"]
            )

        lines_by_id = {
            line.pk: line
            for line in PurchaseLine.objects.filter(
                pk__in=requested_by_line,
                purchase_order=purchase_order,
            ).select_related("product")
        }
        validated_lines = []
        for line_id, quantity in requested_by_line.items():
            line = lines_by_id[line_id]
            if quantity > line.adjustable_quantity:
                raise serializers.ValidationError(
                    {
                        "lines": (
                            f"Cannot adjust more than {line.adjustable_quantity} "
                            "remaining items."
                        )
                    }
                )
            validated_lines.append((line, quantity))

        attrs["validated_lines"] = validated_lines
        return attrs

    def save(self, **kwargs):
        return adjust_purchase_order_items(
            purchase_order=self.context["purchase_order"],
            adjustment_type=self.adjustment_type,
            lines=self.validated_data["validated_lines"],
            reason=self.validated_data.get("reason", ""),
            request=self.context.get("request"),
        )


class PurchaseOrderReturnSerializer(PurchaseOrderAdjustmentInputSerializer):
    adjustment_type = PurchaseOrderAdjustment.AdjustmentType.RETURN


class PurchaseOrderRefundSerializer(PurchaseOrderAdjustmentInputSerializer):
    adjustment_type = PurchaseOrderAdjustment.AdjustmentType.REFUND


class PurchaseOrderExchangeSerializer(PurchaseOrderAdjustmentInputSerializer):
    adjustment_type = PurchaseOrderAdjustment.AdjustmentType.EXCHANGE
