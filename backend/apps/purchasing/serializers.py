from decimal import Decimal

from rest_framework import serializers

from apps.catalog.models import Product
from .models import (
    PurchaseLine,
    PurchaseOrder,
    PurchaseOrderAdjustment,
    PurchaseOrderAdjustmentLine,
    PurchaseOrderAdjustmentReplacementLine,
    PurchaseReceipt,
    PurchaseReceiptLine,
    Supplier,
    SupplierCredit,
    SupplierPayment,
)
from .services import (
    adjust_purchase_order_items,
    create_supplier_payment,
    latest_purchase_line_for_product,
    save_purchase_order_with_lines,
    validate_purchase_order_adjustment_allowed,
)


class SupplierSerializer(serializers.ModelSerializer):
    payable_balance = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        read_only=True,
    )
    credit_balance = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        read_only=True,
    )
    net_balance = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        read_only=True,
    )

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
            "payable_balance",
            "credit_balance",
            "net_balance",
            "created_at",
            "updated_at",
        ]
        read_only_fields = (
            "id",
            "payable_balance",
            "credit_balance",
            "net_balance",
            "created_at",
            "updated_at",
        )


class PurchaseLineSerializer(serializers.ModelSerializer):
    product_name = serializers.CharField(source="product.name", read_only=True)
    product_sku = serializers.CharField(source="product.sku", read_only=True)
    line_total = serializers.DecimalField(max_digits=10, decimal_places=2, read_only=True)
    effective_line_total = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        read_only=True,
    )
    previous_unit_cost = serializers.SerializerMethodField()
    unit_cost_change = serializers.SerializerMethodField()
    unit_cost_change_percent = serializers.SerializerMethodField()
    unit_cost_changed = serializers.SerializerMethodField()
    allocated_landed_cost = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        read_only=True,
    )
    landed_unit_cost = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        read_only=True,
    )
    effective_unit_cost = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        read_only=True,
    )
    adjusted_quantity = serializers.IntegerField(read_only=True)
    accepted_quantity = serializers.IntegerField(read_only=True)
    damaged_quantity = serializers.IntegerField(read_only=True)
    cancelled_quantity = serializers.IntegerField(read_only=True)
    received_quantity = serializers.IntegerField(read_only=True)
    adjustable_quantity = serializers.IntegerField(read_only=True)
    outstanding_quantity = serializers.IntegerField(read_only=True)
    backordered_quantity = serializers.IntegerField(read_only=True)
    over_received_quantity = serializers.IntegerField(read_only=True)

    class Meta:
        model = PurchaseLine
        fields = [
            "id",
            "product",
            "product_name",
            "product_sku",
            "quantity",
            "adjusted_quantity",
            "accepted_quantity",
            "damaged_quantity",
            "cancelled_quantity",
            "received_quantity",
            "adjustable_quantity",
            "outstanding_quantity",
            "backordered_quantity",
            "over_received_quantity",
            "unit_cost",
            "previous_unit_cost",
            "unit_cost_change",
            "unit_cost_change_percent",
            "unit_cost_changed",
            "allocated_landed_cost",
            "landed_unit_cost",
            "effective_unit_cost",
            "effective_line_total",
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
            "allocated_landed_cost",
            "landed_unit_cost",
            "effective_unit_cost",
            "effective_line_total",
            "adjusted_quantity",
            "accepted_quantity",
            "damaged_quantity",
            "cancelled_quantity",
            "received_quantity",
            "adjustable_quantity",
            "outstanding_quantity",
            "backordered_quantity",
            "over_received_quantity",
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


class PurchaseReceiptLineSerializer(serializers.ModelSerializer):
    product_name = serializers.CharField(source="product.name", read_only=True)
    product_sku = serializers.CharField(source="product.sku", read_only=True)
    received_quantity = serializers.IntegerField(read_only=True)
    backordered_quantity = serializers.IntegerField(read_only=True)

    class Meta:
        model = PurchaseReceiptLine
        fields = [
            "id",
            "purchase_line",
            "product",
            "product_name",
            "product_sku",
            "ordered_quantity",
            "outstanding_before",
            "accepted_quantity",
            "damaged_quantity",
            "cancelled_quantity",
            "received_quantity",
            "expected_reduction_quantity",
            "over_received_quantity",
            "outstanding_after",
            "backordered_quantity",
            "notes",
            "created_at",
        ]
        read_only_fields = fields


class PurchaseReceiptSerializer(serializers.ModelSerializer):
    lines = PurchaseReceiptLineSerializer(many=True, read_only=True)
    created_by_username = serializers.CharField(
        source="created_by.username",
        read_only=True,
    )

    class Meta:
        model = PurchaseReceipt
        fields = [
            "id",
            "purchase_order",
            "notes",
            "received_at",
            "created_by",
            "created_by_username",
            "lines",
            "created_at",
            "updated_at",
        ]
        read_only_fields = fields


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


class PurchaseOrderAdjustmentReplacementLineSerializer(serializers.ModelSerializer):
    product_name = serializers.CharField(source="product.name", read_only=True)
    line_total = serializers.DecimalField(max_digits=10, decimal_places=2, read_only=True)

    class Meta:
        model = PurchaseOrderAdjustmentReplacementLine
        fields = [
            "id",
            "product",
            "product_name",
            "quantity",
            "unit_cost",
            "line_total",
        ]
        read_only_fields = fields


class SupplierCreditSerializer(serializers.ModelSerializer):
    class Meta:
        model = SupplierCredit
        fields = [
            "id",
            "supplier",
            "purchase_order",
            "adjustment",
            "amount",
            "remaining_amount",
            "status",
            "reason",
            "created_at",
        ]
        read_only_fields = fields


class PurchaseOrderAdjustmentSerializer(serializers.ModelSerializer):
    lines = PurchaseOrderAdjustmentLineSerializer(many=True, read_only=True)
    replacement_lines = PurchaseOrderAdjustmentReplacementLineSerializer(
        many=True,
        read_only=True,
    )
    created_by_username = serializers.CharField(
        source="created_by.username",
        read_only=True,
    )
    supplier_credit = SupplierCreditSerializer(read_only=True)
    credits = serializers.SerializerMethodField()

    class Meta:
        model = PurchaseOrderAdjustment
        fields = [
            "id",
            "adjustment_type",
            "amount",
            "outbound_amount",
            "replacement_amount",
            "net_amount",
            "settlement_method",
            "reason",
            "created_by",
            "created_by_username",
            "lines",
            "replacement_lines",
            "supplier_credit",
            "credits",
            "created_at",
            "updated_at",
        ]
        read_only_fields = fields

    def get_credits(self, adjustment):
        credit = getattr(adjustment, "supplier_credit", None)
        if credit is None:
            return []
        return [SupplierCreditSerializer(credit).data]


class PurchaseOrderSerializer(serializers.ModelSerializer):
    lines = PurchaseLineSerializer(many=True, allow_empty=False)
    receipts = PurchaseReceiptSerializer(many=True, read_only=True)
    adjustments = PurchaseOrderAdjustmentSerializer(many=True, read_only=True)
    supplier_name = serializers.CharField(source="supplier.name", read_only=True)
    landed_cost_total = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        read_only=True,
    )
    supplier_reference = serializers.CharField(
        source="supplier_invoice_number",
        required=False,
        allow_blank=True,
        trim_whitespace=True,
    )
    can_return = serializers.SerializerMethodField()
    can_refund = serializers.SerializerMethodField()
    can_exchange = serializers.SerializerMethodField()
    paid_total = serializers.DecimalField(max_digits=10, decimal_places=2, read_only=True)
    credit_applied_total = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        read_only=True,
    )
    adjustment_credit_total = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        read_only=True,
    )
    balance_due = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        read_only=True,
    )
    payment_status = serializers.CharField(read_only=True)
    is_overdue = serializers.BooleanField(read_only=True)

    class Meta:
        model = PurchaseOrder
        fields = [
            "id",
            "order_number",
            "supplier",
            "supplier_name",
            "supplier_invoice_number",
            "supplier_invoice_date",
            "supplier_reference",
            "status",
            "notes",
            "due_date",
            "lines",
            "receipts",
            "adjustments",
            "subtotal",
            "shipping_amount",
            "customs_amount",
            "handling_amount",
            "landed_cost_allocation_method",
            "landed_cost_total",
            "total",
            "paid_total",
            "credit_applied_total",
            "adjustment_credit_total",
            "balance_due",
            "payment_status",
            "is_overdue",
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
            "receipts",
            "subtotal",
            "landed_cost_total",
            "total",
            "paid_total",
            "credit_applied_total",
            "adjustment_credit_total",
            "balance_due",
            "payment_status",
            "is_overdue",
            "can_return",
            "can_refund",
            "can_exchange",
            "submitted_at",
            "received_at",
            "created_at",
            "updated_at",
        )
        validators = []

    def validate_shipping_amount(self, value):
        return self._validate_landed_cost_amount(value, "Shipping amount")

    def validate_customs_amount(self, value):
        return self._validate_landed_cost_amount(value, "Customs amount")

    def validate_handling_amount(self, value):
        return self._validate_landed_cost_amount(value, "Handling amount")

    def _validate_landed_cost_amount(self, value, label):
        if value < Decimal("0.00"):
            raise serializers.ValidationError(f"{label} cannot be negative.")
        return value

    def to_internal_value(self, data):
        if isinstance(data, dict):
            data = data.copy()
            self._normalize_landed_cost_aliases(data)
            legacy_number = data.get("supplier_reference")
            invoice_number = data.get("supplier_invoice_number")
            if (
                legacy_number is not None
                and invoice_number is not None
                and str(legacy_number).strip() != str(invoice_number).strip()
            ):
                raise serializers.ValidationError(
                    {
                        "supplier_reference": (
                            "Use supplier_invoice_number; legacy supplier_reference "
                            "must match when both are provided."
                        )
                    }
                )
            if legacy_number is not None and invoice_number is None:
                data["supplier_invoice_number"] = legacy_number
        return super().to_internal_value(data)

    def _normalize_landed_cost_aliases(self, data):
        for canonical, alias in (
            ("shipping_amount", "shipping_cost"),
            ("customs_amount", "customs_cost"),
            ("handling_amount", "handling_cost"),
        ):
            alias_value = data.get(alias)
            canonical_value = data.get(canonical)
            if (
                alias_value is not None
                and canonical_value is not None
                and str(alias_value).strip() != str(canonical_value).strip()
            ):
                raise serializers.ValidationError(
                    {alias: f"Use {canonical}; aliases must match when both are provided."}
                )
            if alias_value is not None and canonical_value is None:
                data[canonical] = alias_value

        allocation_method = data.get("landed_cost_allocation_method")
        allocation_aliases = {
            "by_line_value": PurchaseOrder.LandedCostAllocationMethod.LINE_VALUE,
            "by_quantity": PurchaseOrder.LandedCostAllocationMethod.QUANTITY,
        }
        if allocation_method in allocation_aliases:
            data["landed_cost_allocation_method"] = allocation_aliases[allocation_method]

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

    def validate(self, attrs):
        supplier = attrs.get(
            "supplier",
            None if self.instance is None else self.instance.supplier,
        )
        invoice_number = attrs.get(
            "supplier_invoice_number",
            "" if self.instance is None else self.instance.supplier_invoice_number,
        )
        if supplier is not None and invoice_number:
            matches = PurchaseOrder.objects.filter(
                supplier=supplier,
                supplier_invoice_number=invoice_number,
            )
            if self.instance is not None:
                matches = matches.exclude(pk=self.instance.pk)
            if matches.exists():
                raise serializers.ValidationError(
                    {
                        "supplier_invoice_number": (
                            "Supplier invoice number already exists for this supplier."
                        )
                    }
                )
        return attrs

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


class PurchaseReceiptLineInputSerializer(serializers.Serializer):
    line = serializers.PrimaryKeyRelatedField(
        queryset=PurchaseLine.objects.all(),
        required=False,
    )
    purchase_line = serializers.PrimaryKeyRelatedField(
        queryset=PurchaseLine.objects.all(),
        required=False,
    )
    quantity = serializers.IntegerField(min_value=0, required=False)
    accepted_quantity = serializers.IntegerField(min_value=0, required=False)
    quantity_received = serializers.IntegerField(min_value=0, required=False)
    damaged_quantity = serializers.IntegerField(min_value=0, required=False)
    quantity_damaged = serializers.IntegerField(min_value=0, required=False)
    cancelled_quantity = serializers.IntegerField(min_value=0, required=False)
    quantity_rejected = serializers.IntegerField(min_value=0, required=False)
    notes = serializers.CharField(required=False, allow_blank=True, trim_whitespace=True)
    note = serializers.CharField(required=False, allow_blank=True, trim_whitespace=True)

    def validate(self, attrs):
        line = attrs.get("line")
        purchase_line = attrs.get("purchase_line")
        if line is None and purchase_line is None:
            raise serializers.ValidationError(
                {"line": "Purchase line is required."}
            )
        if (
            line is not None
            and purchase_line is not None
            and line.pk != purchase_line.pk
        ):
            raise serializers.ValidationError(
                {"purchase_line": "Line aliases must reference the same purchase line."}
            )
        attrs["line"] = line or purchase_line
        attrs.pop("purchase_line", None)

        accepted_keys = [
            key
            for key in ("quantity", "accepted_quantity", "quantity_received")
            if key in attrs
        ]
        if len(accepted_keys) > 1:
            raise serializers.ValidationError(
                {
                    "accepted_quantity": (
                        "Use only one accepted quantity field per receipt line."
                    )
                }
            )
        attrs["accepted_quantity"] = (
            attrs.get("accepted_quantity")
            if "accepted_quantity" in attrs
            else attrs.get("quantity_received", attrs.get("quantity", 0))
        )
        attrs.pop("quantity", None)
        attrs.pop("quantity_received", None)

        if "quantity_damaged" in attrs:
            if (
                "damaged_quantity" in attrs
                and attrs["damaged_quantity"] != attrs["quantity_damaged"]
            ):
                raise serializers.ValidationError(
                    {"damaged_quantity": "Damaged quantity aliases must match."}
                )
            attrs["damaged_quantity"] = attrs["quantity_damaged"]
            attrs.pop("quantity_damaged", None)

        if "quantity_rejected" in attrs:
            if (
                "cancelled_quantity" in attrs
                and attrs["cancelled_quantity"] != attrs["quantity_rejected"]
            ):
                raise serializers.ValidationError(
                    {"cancelled_quantity": "Rejected quantity aliases must match."}
                )
            attrs["cancelled_quantity"] = attrs["quantity_rejected"]
            attrs.pop("quantity_rejected", None)

        if "note" in attrs:
            attrs["notes"] = attrs.get("notes", attrs["note"])
            attrs.pop("note", None)
        return attrs


class PurchaseReceiptInputSerializer(serializers.Serializer):
    lines = PurchaseReceiptLineInputSerializer(many=True, allow_empty=False)
    notes = serializers.CharField(required=False, allow_blank=True, trim_whitespace=True)
    note = serializers.CharField(required=False, allow_blank=True, trim_whitespace=True)

    def validate(self, attrs):
        if "note" in attrs:
            attrs["notes"] = attrs.get("notes", attrs["note"])
            attrs.pop("note", None)
        purchase_order = self.context["purchase_order"]
        requested_by_line = {}
        for line_data in attrs["lines"]:
            line = line_data["line"]
            if line.purchase_order_id != purchase_order.pk:
                raise serializers.ValidationError(
                    {"lines": "Receipt line does not belong to this purchase order."}
                )
            if line.pk in requested_by_line:
                raise serializers.ValidationError(
                    {"lines": "Each purchase line can be received only once per receipt."}
                )
            requested_by_line[line.pk] = line_data

        validated_lines = []
        lines_by_id = {
            line.pk: line
            for line in PurchaseLine.objects.filter(
                pk__in=requested_by_line,
                purchase_order=purchase_order,
            )
            .select_related("product")
            .prefetch_related("receipt_lines")
        }
        for line_id, line_data in requested_by_line.items():
            line = lines_by_id[line_id]
            accepted_quantity = line_data.get("accepted_quantity", 0)
            damaged_quantity = line_data.get("damaged_quantity", 0)
            cancelled_quantity = line_data.get("cancelled_quantity", 0)
            if accepted_quantity + damaged_quantity + cancelled_quantity <= 0:
                raise serializers.ValidationError(
                    {
                        "lines": (
                            "At least one received, damaged, or cancelled quantity "
                            "is required."
                        )
                    }
                )
            if cancelled_quantity > 0 and (
                accepted_quantity + damaged_quantity + cancelled_quantity
                > line.outstanding_quantity
            ):
                raise serializers.ValidationError(
                    {
                        "lines": (
                            "Cancelled quantity cannot exceed the outstanding "
                            "quantity after received and damaged quantities."
                        )
                    }
                )
            validated_lines.append(
                {
                    "line": line,
                    "accepted_quantity": accepted_quantity,
                    "damaged_quantity": damaged_quantity,
                    "cancelled_quantity": cancelled_quantity,
                    "notes": line_data.get("notes", ""),
                }
            )

        attrs["validated_lines"] = validated_lines
        return attrs


class PurchaseOrderAdjustmentLineInputSerializer(serializers.Serializer):
    line = serializers.PrimaryKeyRelatedField(queryset=PurchaseLine.objects.all())
    quantity = serializers.IntegerField(min_value=1)


class PurchaseOrderReplacementLineInputSerializer(serializers.Serializer):
    product = serializers.PrimaryKeyRelatedField(queryset=Product.objects.all())
    quantity = serializers.IntegerField(min_value=1)
    unit_cost = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        min_value=Decimal("0.00"),
    )


class PurchaseOrderAdjustmentInputSerializer(serializers.Serializer):
    lines = PurchaseOrderAdjustmentLineInputSerializer(many=True, allow_empty=False)
    reason = serializers.CharField(required=False, allow_blank=True, trim_whitespace=True)
    settlement_method = serializers.ChoiceField(
        choices=PurchaseOrderAdjustment.SettlementMethod.choices,
        required=False,
        allow_blank=True,
    )
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
        attrs["settlement_method"] = self._settlement_method(attrs)
        return attrs

    def _settlement_method(self, attrs):
        settlement_method = attrs.get("settlement_method", "")
        if settlement_method:
            return settlement_method
        if self.adjustment_type == PurchaseOrderAdjustment.AdjustmentType.RETURN:
            return PurchaseOrderAdjustment.SettlementMethod.SUPPLIER_CREDIT
        if self.adjustment_type == PurchaseOrderAdjustment.AdjustmentType.REFUND:
            return PurchaseOrderAdjustment.SettlementMethod.REFUND
        return ""

    def save(self, **kwargs):
        return adjust_purchase_order_items(
            purchase_order=self.context["purchase_order"],
            adjustment_type=self.adjustment_type,
            lines=self.validated_data["validated_lines"],
            replacement_lines=None,
            reason=self.validated_data.get("reason", ""),
            request=self.context.get("request"),
            settlement_method=self.validated_data.get("settlement_method", ""),
        )


class PurchaseOrderReturnSerializer(PurchaseOrderAdjustmentInputSerializer):
    adjustment_type = PurchaseOrderAdjustment.AdjustmentType.RETURN


class PurchaseOrderRefundSerializer(PurchaseOrderAdjustmentInputSerializer):
    adjustment_type = PurchaseOrderAdjustment.AdjustmentType.REFUND


class PurchaseOrderExchangeSerializer(PurchaseOrderAdjustmentInputSerializer):
    adjustment_type = PurchaseOrderAdjustment.AdjustmentType.EXCHANGE
    replacement_lines = PurchaseOrderReplacementLineInputSerializer(
        many=True,
        required=False,
        allow_empty=False,
    )

    def to_internal_value(self, data):
        if isinstance(data, dict) and "replacement_items" in data:
            data = data.copy()
            if (
                "replacement_lines" in data
                and data["replacement_lines"] != data["replacement_items"]
            ):
                raise serializers.ValidationError(
                    {
                        "replacement_items": (
                            "Use replacement_lines; aliases must match when both are provided."
                        )
                    }
                )
            data.setdefault("replacement_lines", data["replacement_items"])
        return super().to_internal_value(data)

    def validate(self, attrs):
        attrs = super().validate(attrs)
        replacement_lines = attrs.get("replacement_lines")
        if replacement_lines is None:
            replacement_lines = [
                {
                    "product": line.product,
                    "quantity": quantity,
                    "unit_cost": line.unit_cost,
                }
                for line, quantity in attrs["validated_lines"]
            ]
        attrs["validated_replacement_lines"] = [
            (
                line_data["product"],
                line_data["quantity"],
                line_data["unit_cost"],
            )
            for line_data in replacement_lines
        ]
        return attrs

    def save(self, **kwargs):
        return adjust_purchase_order_items(
            purchase_order=self.context["purchase_order"],
            adjustment_type=self.adjustment_type,
            lines=self.validated_data["validated_lines"],
            replacement_lines=self.validated_data["validated_replacement_lines"],
            reason=self.validated_data.get("reason", ""),
            request=self.context.get("request"),
            settlement_method=self.validated_data.get("settlement_method", ""),
        )


class SupplierPaymentSerializer(serializers.ModelSerializer):
    supplier_name = serializers.CharField(source="supplier.name", read_only=True)
    purchase_order_number = serializers.SerializerMethodField()
    created_by_username = serializers.CharField(
        source="created_by.username",
        read_only=True,
    )

    class Meta:
        model = SupplierPayment
        fields = [
            "id",
            "supplier",
            "supplier_name",
            "purchase_order",
            "purchase_order_number",
            "amount",
            "method",
            "reference",
            "notes",
            "paid_at",
            "created_by_username",
            "created_at",
            "updated_at",
        ]
        read_only_fields = (
            "id",
            "supplier_name",
            "purchase_order_number",
            "created_by_username",
            "created_at",
            "updated_at",
        )

    def get_purchase_order_number(self, payment):
        if payment.purchase_order_id is None:
            return None
        return payment.purchase_order.order_number

    def create(self, validated_data):
        request = self.context.get("request")
        created_by = (
            request.user
            if request is not None and request.user.is_authenticated
            else None
        )
        return create_supplier_payment(created_by=created_by, **validated_data)
