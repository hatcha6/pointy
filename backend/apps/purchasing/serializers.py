from decimal import Decimal

from django.contrib.contenttypes.models import ContentType
from django.db.models import Sum
from rest_framework import serializers

from apps.attachments.models import Attachment
from apps.attachments.serializers import AttachmentSummarySerializer
from apps.catalog.models import ProductVariant
from apps.catalog.units import UnitConversionError, resolve_unit, unit_label_for
from apps.discounts.models import AppliedDiscount, DiscountRule, normalize_coupon_code
from apps.discounts.services import (
    DiscountContext,
    DiscountEngine,
    DiscountLineInput,
    allocate_discount_amount,
    rounding_metadata_payload,
)
from .models import (
    PurchaseLine,
    PurchaseOrder,
    PurchaseOrderAdjustment,
    PurchaseOrderAdjustmentLine,
    PurchaseOrderAdjustmentReplacementLine,
    PurchaseOrderAuditEvent,
    PurchaseOrderLandedCostEntry,
    PurchaseReceipt,
    PurchaseReceiptLine,
    Supplier,
    SupplierCredit,
    SupplierPayment,
)
from .services import (
    adjust_purchase_order_items,
    create_supplier_payment,
    latest_purchase_line_for_variant,
    purchase_adjustment_line_amount,
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
    total_bought = serializers.SerializerMethodField()
    purchase_count = serializers.SerializerMethodField()

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
            "total_bought",
            "purchase_count",
            "created_at",
            "updated_at",
        ]
        read_only_fields = (
            "id",
            "payable_balance",
            "credit_balance",
            "net_balance",
            "total_bought",
            "purchase_count",
            "created_at",
            "updated_at",
        )

    def get_total_bought(self, supplier):
        # Prefer the queryset annotation (supplier list); fall back to a direct
        # aggregate for un-annotated instances (e.g. create/update responses).
        if hasattr(supplier, "purchases_total"):
            total = supplier.purchases_total
        else:
            total = supplier.purchase_orders.exclude(
                status=PurchaseOrder.Status.CANCELLED,
            ).aggregate(total=Sum("total"))["total"]
        return money_string(total or Decimal("0.00"))

    def get_purchase_count(self, supplier):
        if hasattr(supplier, "purchases_count"):
            return supplier.purchases_count
        return supplier.purchase_orders.exclude(
            status=PurchaseOrder.Status.CANCELLED,
        ).count()


class PurchaseLineSerializer(serializers.ModelSerializer):
    product = serializers.IntegerField(source="variant.product_id", read_only=True)
    variant = serializers.PrimaryKeyRelatedField(
        queryset=ProductVariant.objects.all(),
    )
    product_name = serializers.CharField(source="variant.product.name", read_only=True)
    variant_sku = serializers.CharField(source="variant.sku", read_only=True)
    variant_name = serializers.CharField(source="variant.display_name", read_only=True)
    tracks_expiry = serializers.BooleanField(
        source="variant.product.tracks_expiry",
        read_only=True,
    )
    line_total = serializers.DecimalField(max_digits=10, decimal_places=2, read_only=True)
    discount_amount = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        read_only=True,
    )
    net_line_total = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        read_only=True,
    )
    net_unit_cost = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        read_only=True,
    )
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
    # The purchase unit is sent as a code; its base-conversion factor and the
    # base-unit equivalents are resolved/derived server-side and read-only.
    unit = serializers.CharField(
        required=False,
        allow_blank=True,
        max_length=32,
        trim_whitespace=True,
        default="",
    )
    unit_factor = serializers.DecimalField(
        max_digits=18,
        decimal_places=6,
        read_only=True,
    )
    unit_label = serializers.SerializerMethodField()
    base_quantity = serializers.SerializerMethodField()
    base_unit_cost = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        read_only=True,
    )

    class Meta:
        model = PurchaseLine
        fields = [
            "id",
            "product",
            "variant",
            "product_name",
            "variant_sku",
            "variant_name",
            "tracks_expiry",
            "quantity",
            "unit",
            "unit_factor",
            "unit_label",
            "base_quantity",
            "base_unit_cost",
            "expiry_date",
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
            "discount_amount",
            "net_unit_cost",
            "previous_unit_cost",
            "unit_cost_change",
            "unit_cost_change_percent",
            "unit_cost_changed",
            "allocated_landed_cost",
            "landed_unit_cost",
            "effective_unit_cost",
            "effective_line_total",
            "net_line_total",
            "line_total",
        ]
        read_only_fields = (
            "id",
            "product_name",
            "variant_sku",
            "tracks_expiry",
            "unit_factor",
            "unit_label",
            "base_quantity",
            "base_unit_cost",
            "previous_unit_cost",
            "unit_cost_change",
            "unit_cost_change_percent",
            "unit_cost_changed",
            "discount_amount",
            "net_unit_cost",
            "allocated_landed_cost",
            "landed_unit_cost",
            "effective_unit_cost",
            "effective_line_total",
            "net_line_total",
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
            previous_line = latest_purchase_line_for_variant(
                line.variant_id,
                before_line=line,
            )
            self._previous_unit_cost_cache[line.pk] = (
                None if previous_line is None else previous_line.unit_cost
            )
        return self._previous_unit_cost_cache[line.pk]

    def get_base_quantity(self, line):
        return str(line.to_base_quantity(line.quantity))

    def get_unit_label(self, line):
        return unit_label_for(line.unit or line.variant.product.unit, self.context)

    def validate_quantity(self, value):
        if value < 1:
            raise serializers.ValidationError("Quantity must be positive.")
        return value

    def validate_unit_cost(self, value):
        if value < Decimal("0.00"):
            raise serializers.ValidationError("Unit cost cannot be negative.")
        return value

    def validate(self, attrs):
        variant = attrs.get("variant", getattr(self.instance, "variant", None))
        if variant is None:
            raise serializers.ValidationError({"variant": "Variant is required."})
        expiry_date = attrs.get(
            "expiry_date",
            getattr(self.instance, "expiry_date", None),
        )
        if variant.product.tracks_expiry and expiry_date is None:
            raise serializers.ValidationError(
                {
                    "expiry_date": (
                        "Expiry date is required for products that track expiry."
                    )
                }
            )
        attrs["variant"] = variant
        # Resolve the purchase unit + snapshot its base-conversion factor. Purchase
        # quantities stay whole (you buy whole packs); the factor only converts to
        # base units when stock is touched at submit/receive time.
        requested_unit = attrs.get("unit")
        if requested_unit is None:
            requested_unit = getattr(self.instance, "unit", "") or ""
        try:
            resolved = resolve_unit(
                variant.product, requested_unit, field="unit", for_purchase=True
            )
        except UnitConversionError as error:
            raise serializers.ValidationError({error.field: error.message})
        attrs["unit"] = resolved.code
        attrs["unit_factor"] = resolved.factor
        return attrs


class PurchaseOrderLandedCostEntrySerializer(serializers.ModelSerializer):
    class Meta:
        model = PurchaseOrderLandedCostEntry
        fields = ["id", "name", "amount"]
        read_only_fields = ("id",)

    def validate_name(self, value):
        name = value.strip()
        if not name:
            raise serializers.ValidationError("Name is required.")
        return name

    def validate_amount(self, value):
        if value < Decimal("0.00"):
            raise serializers.ValidationError("Amount cannot be negative.")
        return value


def money_string(value):
    return str(value.quantize(Decimal("0.01")))


class PurchaseReceiptLineSerializer(serializers.ModelSerializer):
    product = serializers.IntegerField(source="variant.product_id", read_only=True)
    product_name = serializers.CharField(source="variant.product.name", read_only=True)
    variant_sku = serializers.CharField(source="variant.sku", read_only=True)
    variant_name = serializers.CharField(source="variant.display_name", read_only=True)
    tracks_expiry = serializers.BooleanField(
        source="variant.product.tracks_expiry",
        read_only=True,
    )
    received_quantity = serializers.IntegerField(read_only=True)
    backordered_quantity = serializers.IntegerField(read_only=True)

    class Meta:
        model = PurchaseReceiptLine
        fields = [
            "id",
            "purchase_line",
            "product",
            "variant",
            "product_name",
            "variant_sku",
            "variant_name",
            "tracks_expiry",
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
            "expiry_date",
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
    product = serializers.IntegerField(source="variant.product_id", read_only=True)
    product_name = serializers.CharField(source="variant.product.name", read_only=True)
    variant_sku = serializers.CharField(source="variant.sku", read_only=True)
    variant_name = serializers.CharField(source="variant.display_name", read_only=True)
    line_total = serializers.DecimalField(max_digits=10, decimal_places=2, read_only=True)

    class Meta:
        model = PurchaseOrderAdjustmentLine
        fields = [
            "id",
            "purchase_line",
            "product",
            "variant",
            "product_name",
            "variant_sku",
            "variant_name",
            "quantity",
            "unit_cost",
            "line_total",
        ]
        read_only_fields = fields


class ProductCostHistorySerializer(serializers.ModelSerializer):
    product = serializers.IntegerField(
        source="variant.product_id",
        read_only=True,
    )
    variant = serializers.IntegerField(
        source="variant_id",
        read_only=True,
    )
    variant_name = serializers.CharField(source="variant.display_name", read_only=True)
    purchase_order = serializers.IntegerField(
        source="purchase_order_id",
        read_only=True,
    )
    order_number = serializers.CharField(
        source="purchase_order.order_number",
        read_only=True,
    )
    supplier = serializers.IntegerField(
        source="purchase_order.supplier_id",
        read_only=True,
    )
    supplier_name = serializers.CharField(
        source="purchase_order.supplier.name",
        read_only=True,
    )
    received_at = serializers.DateTimeField(
        source="purchase_order.received_at",
        read_only=True,
    )
    submitted_at = serializers.DateTimeField(
        source="purchase_order.submitted_at",
        read_only=True,
    )

    class Meta:
        model = PurchaseLine
        fields = [
            "id",
            "product",
            "variant",
            "variant_name",
            "purchase_order",
            "order_number",
            "supplier",
            "supplier_name",
            "quantity",
            "unit_cost",
            "effective_unit_cost",
            "landed_unit_cost",
            "expiry_date",
            "received_at",
            "submitted_at",
            "created_at",
        ]
        read_only_fields = fields


class PurchaseAdjustmentHistorySerializer(serializers.ModelSerializer):
    adjustment = serializers.IntegerField(source="adjustment_id", read_only=True)
    adjustment_type = serializers.CharField(
        source="adjustment.adjustment_type",
        read_only=True,
    )
    settlement_method = serializers.CharField(
        source="adjustment.settlement_method",
        read_only=True,
    )
    reason = serializers.CharField(source="adjustment.reason", read_only=True)
    adjustment_amount = serializers.DecimalField(
        source="adjustment.amount",
        max_digits=10,
        decimal_places=2,
        read_only=True,
    )
    outbound_amount = serializers.DecimalField(
        source="adjustment.outbound_amount",
        max_digits=10,
        decimal_places=2,
        read_only=True,
    )
    replacement_amount = serializers.DecimalField(
        source="adjustment.replacement_amount",
        max_digits=10,
        decimal_places=2,
        read_only=True,
    )
    net_amount = serializers.DecimalField(
        source="adjustment.net_amount",
        max_digits=10,
        decimal_places=2,
        read_only=True,
    )
    purchase_order = serializers.IntegerField(
        source="adjustment.purchase_order_id",
        read_only=True,
    )
    order_number = serializers.CharField(
        source="adjustment.purchase_order.order_number",
        read_only=True,
    )
    supplier = serializers.IntegerField(
        source="adjustment.purchase_order.supplier_id",
        read_only=True,
    )
    supplier_name = serializers.CharField(
        source="adjustment.purchase_order.supplier.name",
        read_only=True,
    )
    product = serializers.IntegerField(source="variant.product_id", read_only=True)
    product_name = serializers.CharField(source="variant.product.name", read_only=True)
    variant_sku = serializers.CharField(source="variant.sku", read_only=True)
    variant_name = serializers.CharField(source="variant.display_name", read_only=True)
    line_total = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        read_only=True,
    )
    created_at = serializers.DateTimeField(
        source="adjustment.created_at",
        read_only=True,
    )

    class Meta:
        model = PurchaseOrderAdjustmentLine
        fields = [
            "id",
            "adjustment",
            "adjustment_type",
            "settlement_method",
            "reason",
            "adjustment_amount",
            "outbound_amount",
            "replacement_amount",
            "net_amount",
            "purchase_order",
            "order_number",
            "supplier",
            "supplier_name",
            "purchase_line",
            "product",
            "product_name",
            "variant_sku",
            "variant",
            "variant_name",
            "quantity",
            "unit_cost",
            "line_total",
            "created_at",
        ]
        read_only_fields = fields


class PurchaseOrderAdjustmentReplacementLineSerializer(serializers.ModelSerializer):
    product = serializers.IntegerField(source="variant.product_id", read_only=True)
    product_name = serializers.CharField(source="variant.product.name", read_only=True)
    variant_sku = serializers.CharField(source="variant.sku", read_only=True)
    variant_name = serializers.CharField(source="variant.display_name", read_only=True)
    line_total = serializers.DecimalField(max_digits=10, decimal_places=2, read_only=True)

    class Meta:
        model = PurchaseOrderAdjustmentReplacementLine
        fields = [
            "id",
            "product",
            "variant",
            "product_name",
            "variant_sku",
            "variant_name",
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


class PurchaseDiscountPreviewLineSerializer(serializers.Serializer):
    variant = serializers.PrimaryKeyRelatedField(
        queryset=ProductVariant.objects.all(),
    )
    quantity = serializers.IntegerField(min_value=1)
    unit_cost = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        min_value=Decimal("0.00"),
    )

    def validate(self, attrs):
        variant = attrs.get("variant")
        if variant is None:
            raise serializers.ValidationError({"variant": "Variant is required."})
        attrs["variant"] = variant
        return attrs


class PurchaseDiscountPreviewSerializer(serializers.Serializer):
    supplier = serializers.PrimaryKeyRelatedField(queryset=Supplier.objects.all())
    lines = PurchaseDiscountPreviewLineSerializer(many=True, allow_empty=False)
    discount_code = serializers.CharField(
        required=False,
        allow_blank=True,
        trim_whitespace=True,
        write_only=True,
    )
    discount_codes = serializers.ListField(
        child=serializers.CharField(allow_blank=False, trim_whitespace=True),
        required=False,
        allow_empty=True,
        write_only=True,
    )
    landed_cost_entries = PurchaseOrderLandedCostEntrySerializer(
        many=True,
        required=False,
        allow_empty=True,
    )
    landed_cost_allocation_method = serializers.ChoiceField(
        choices=PurchaseOrder.LandedCostAllocationMethod.choices,
        required=False,
        default=PurchaseOrder.LandedCostAllocationMethod.LINE_VALUE,
    )

    def to_internal_value(self, data):
        if isinstance(data, dict):
            reject_legacy_landed_cost_fields(data)
        return super().to_internal_value(data)

    def validate(self, attrs):
        coupon_codes = normalized_purchase_discount_codes(attrs)
        discount_lines = tuple(
            DiscountLineInput(
                key=str(index),
                product_id=line["variant"].product_id,
                variant_id=line["variant"].pk,
                quantity=line["quantity"],
                unit_amount=line["unit_cost"],
                category_ids=tuple(
                    line["variant"].product.categories.values_list("id", flat=True)
                ),
            )
            for index, line in enumerate(attrs["lines"])
        )
        discount_result = DiscountEngine().calculate(
            DiscountContext(
                channel=DiscountRule.Channel.PURCHASING,
                supplier_id=attrs["supplier"].pk,
                coupon_codes=coupon_codes,
                lines=discount_lines,
            )
        )
        attrs["coupon_codes"] = coupon_codes
        attrs["discount_result"] = discount_result
        return attrs

    @property
    def preview_data(self):
        discount_result = self.validated_data["discount_result"]
        landed_cost_total = landed_cost_total_from_validated_data(
            self.validated_data
        )
        coupon_codes = self.validated_data.get("coupon_codes", ())
        return {
            "subtotal": f"{discount_result.subtotal:.2f}",
            "discount_total": f"{discount_result.discount_total:.2f}",
            "landed_cost_total": f"{landed_cost_total:.2f}",
            "total": f"{(discount_result.total + landed_cost_total):.2f}",
            "lines": purchase_preview_line_payloads(
                lines=self.validated_data["lines"],
                discount_result=discount_result,
                landed_cost_total=landed_cost_total,
                landed_cost_allocation_method=self.validated_data[
                    "landed_cost_allocation_method"
                ],
            ),
            "applied_discounts": [
                {
                    "rule_id": application.rule_id,
                    "rule_name": application.rule_name,
                    "coupon_code": application.coupon_code,
                    "source": application.source,
                    "scope": application.scope,
                    "value_type": application.value_type,
                    "value": f"{application.value:.4f}",
                    "discount_amount": f"{application.amount:.2f}",
                    **application.metadata_dict(),
                    "allocations": application.allocation_dicts(),
                }
                for application in discount_result.applications
            ],
            "unapplied_discount_codes": unapplied_purchase_discount_codes(
                discount_result,
                coupon_codes,
            ),
        }


def normalized_purchase_discount_codes(attrs):
    discount_codes = list(attrs.get("discount_codes") or [])
    single_code = attrs.get("discount_code")
    if single_code:
        discount_codes.append(single_code)
    normalized_codes = []
    for code in discount_codes:
        normalized = normalize_coupon_code(code)
        if normalized and normalized not in normalized_codes:
            normalized_codes.append(normalized)
    return tuple(normalized_codes)


def reject_legacy_landed_cost_fields(data):
    legacy_fields = (
        "shipping_amount",
        "shipping_cost",
        "customs_amount",
        "customs_cost",
        "handling_amount",
        "handling_cost",
        "landed_costs",
    )
    errors = {
        field: "Use landed_cost_entries."
        for field in legacy_fields
        if field in data
    }
    if errors:
        raise serializers.ValidationError(errors)


def landed_cost_total_from_validated_data(data):
    return sum(
        (entry["amount"] for entry in data.get("landed_cost_entries", ())),
        Decimal("0.00"),
    ).quantize(Decimal("0.01"))


def unapplied_purchase_discount_codes(discount_result, discount_codes):
    requested_codes = {
        normalize_coupon_code(code)
        for code in discount_codes or ()
        if normalize_coupon_code(code)
    }
    applied_codes = {
        normalize_coupon_code(application.coupon_code)
        for application in discount_result.applications
        if application.source == DiscountRule.ApplicationType.COUPON_CODE
    }
    return sorted(requested_codes - applied_codes)


def purchase_preview_line_payloads(
    *,
    lines,
    discount_result,
    landed_cost_total,
    landed_cost_allocation_method,
):
    discounts_by_key = {str(index): Decimal("0.00") for index in range(len(lines))}
    for application in discount_result.applications:
        for allocation in application.allocations:
            discounts_by_key[allocation.line_key] = (
                discounts_by_key[allocation.line_key] + allocation.amount
            ).quantize(Decimal("0.01"))

    net_totals_by_key = {}
    quantities_by_key = {}
    for index, line in enumerate(lines):
        key = str(index)
        line_total = (line["unit_cost"] * Decimal(line["quantity"])).quantize(
            Decimal("0.01")
        )
        net_totals_by_key[key] = (line_total - discounts_by_key[key]).quantize(
            Decimal("0.01")
        )
        quantities_by_key[key] = Decimal(line["quantity"])

    if landed_cost_allocation_method == PurchaseOrder.LandedCostAllocationMethod.QUANTITY:
        weights = quantities_by_key
    elif (
        landed_cost_allocation_method
        == PurchaseOrder.LandedCostAllocationMethod.RETAIL_VALUE
    ):
        weights = {
            str(index): (line["variant"].unit_price * Decimal(line["quantity"]))
            .quantize(Decimal("0.01"))
            for index, line in enumerate(lines)
        }
    elif landed_cost_allocation_method == PurchaseOrder.LandedCostAllocationMethod.EQUAL:
        weights = {str(index): Decimal("1.00") for index in range(len(lines))}
    else:
        weights = net_totals_by_key
        if sum(weights.values(), Decimal("0.00")) == Decimal("0.00"):
            weights = quantities_by_key
    landed_allocations = {
        allocation.line_key: allocation.amount
        for allocation in allocate_discount_amount(landed_cost_total, weights)
    }

    payloads = []
    for index, line in enumerate(lines):
        key = str(index)
        variant = line["variant"]
        product = variant.product
        quantity = Decimal(line["quantity"])
        line_total = (line["unit_cost"] * quantity).quantize(Decimal("0.01"))
        discount_amount = discounts_by_key[key]
        net_line_total = net_totals_by_key[key]
        allocated_landed_cost = landed_allocations.get(key, Decimal("0.00"))
        net_unit_cost = (net_line_total / quantity).quantize(Decimal("0.01"))
        landed_unit_cost = (allocated_landed_cost / quantity).quantize(Decimal("0.01"))
        effective_unit_cost = (net_unit_cost + landed_unit_cost).quantize(
            Decimal("0.01")
        )
        payloads.append(
            {
                "product": product.pk,
                "variant": variant.pk,
                "product_name": product.name,
                "variant_sku": variant.sku,
                "variant_name": variant.display_name,
                "quantity": int(quantity),
                "unit_cost": f"{line['unit_cost']:.2f}",
                "line_total": f"{line_total:.2f}",
                "discount_amount": f"{discount_amount:.2f}",
                "net_line_total": f"{net_line_total:.2f}",
                "net_unit_cost": f"{net_unit_cost:.2f}",
                "allocated_landed_cost": f"{allocated_landed_cost:.2f}",
                "landed_unit_cost": f"{landed_unit_cost:.2f}",
                "effective_unit_cost": f"{effective_unit_cost:.2f}",
                "effective_line_total": (
                    f"{(net_line_total + allocated_landed_cost):.2f}"
                ),
            }
        )
    return payloads


class PurchaseOrderAuditEventSerializer(serializers.ModelSerializer):
    created_by_username = serializers.CharField(
        source="created_by.username",
        read_only=True,
    )

    class Meta:
        model = PurchaseOrderAuditEvent
        fields = [
            "id",
            "purchase_order",
            "order_number",
            "action",
            "message",
            "details",
            "created_by",
            "created_by_username",
            "created_at",
        ]
        read_only_fields = fields


class PurchaseOrderListSerializer(serializers.ModelSerializer):
    """Lightweight serializer for the purchase-order list. Carries the summary
    fields, the lines (the UI shows a line count), and the payment status, but
    omits the heavy receipt/adjustment/audit/attachment trees the detail screen
    re-fetches on open."""

    lines = PurchaseLineSerializer(many=True, read_only=True)
    supplier_name = serializers.CharField(source="supplier.name", read_only=True)
    supplier_reference = serializers.CharField(
        source="supplier_invoice_number",
        read_only=True,
    )
    balance_due = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        read_only=True,
    )
    payment_status = serializers.CharField(read_only=True)

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
            "due_date",
            "lines",
            "subtotal",
            "discount_total",
            "total",
            "balance_due",
            "payment_status",
            "submitted_at",
            "received_at",
            "created_at",
            "updated_at",
        ]
        read_only_fields = fields


class PurchaseOrderSerializer(serializers.ModelSerializer):
    lines = PurchaseLineSerializer(many=True, allow_empty=False)
    receipts = PurchaseReceiptSerializer(many=True, read_only=True)
    adjustments = PurchaseOrderAdjustmentSerializer(many=True, read_only=True)
    audit_events = PurchaseOrderAuditEventSerializer(many=True, read_only=True)
    landed_cost_entries = PurchaseOrderLandedCostEntrySerializer(
        many=True,
        required=False,
        allow_empty=True,
    )
    supplier_name = serializers.CharField(source="supplier.name", read_only=True)
    supplier_contact_name = serializers.CharField(
        source="supplier.contact_name",
        read_only=True,
    )
    supplier_phone = serializers.CharField(source="supplier.phone", read_only=True)
    supplier_email = serializers.CharField(source="supplier.email", read_only=True)
    supplier_address = serializers.CharField(source="supplier.address", read_only=True)
    landed_cost_total = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        read_only=True,
    )
    discount_codes = serializers.ListField(
        child=serializers.CharField(allow_blank=False, trim_whitespace=True),
        required=False,
        allow_empty=True,
    )
    applied_discounts = serializers.SerializerMethodField()
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
    attachments = serializers.SerializerMethodField()
    supplier_invoice_attachments = serializers.SerializerMethodField()

    class Meta:
        model = PurchaseOrder
        fields = [
            "id",
            "order_number",
            "supplier",
            "supplier_name",
            "supplier_contact_name",
            "supplier_phone",
            "supplier_email",
            "supplier_address",
            "supplier_invoice_number",
            "supplier_invoice_date",
            "supplier_reference",
            "status",
            "notes",
            "due_date",
            "lines",
            "receipts",
            "adjustments",
            "audit_events",
            "subtotal",
            "discount_codes",
            "discount_total",
            "applied_discounts",
            "landed_cost_entries",
            "landed_cost_allocation_method",
            "landed_cost_total",
            "total",
            "paid_total",
            "credit_applied_total",
            "adjustment_credit_total",
            "balance_due",
            "payment_status",
            "is_overdue",
            "attachments",
            "supplier_invoice_attachments",
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
            "supplier_contact_name",
            "supplier_phone",
            "supplier_email",
            "supplier_address",
            "status",
            "adjustments",
            "audit_events",
            "receipts",
            "subtotal",
            "discount_total",
            "applied_discounts",
            "landed_cost_total",
            "total",
            "paid_total",
            "credit_applied_total",
            "adjustment_credit_total",
            "balance_due",
            "payment_status",
            "is_overdue",
            "attachments",
            "supplier_invoice_attachments",
            "can_return",
            "can_refund",
            "can_exchange",
            "submitted_at",
            "received_at",
            "created_at",
            "updated_at",
        )
        validators = []

    def to_internal_value(self, data):
        if isinstance(data, dict):
            data = data.copy()
            reject_legacy_landed_cost_fields(data)
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

    def get_can_return(self, purchase_order):
        return self._can_adjust(purchase_order)

    def get_attachments(self, purchase_order):
        return self._attachment_summaries(purchase_order)

    def get_supplier_invoice_attachments(self, purchase_order):
        return self._attachment_summaries(
            purchase_order,
            role=Attachment.Role.SUPPLIER_INVOICE_SCAN,
        )

    def _attachment_summaries(self, purchase_order, role=None):
        cached = getattr(purchase_order, "_prefetched_objects_cache", {}).get(
            "attachments"
        )
        if cached is not None:
            attachments = [
                attachment
                for attachment in cached
                if attachment.status == Attachment.Status.ACTIVE
                and (role is None or attachment.role == role)
            ]
        else:
            queryset = purchase_order.attachments.active().select_related(
                "owner_content_type",
                "storage_volume",
                "created_by",
            )
            if role is not None:
                queryset = queryset.filter(role=role)
            attachments = list(queryset)
        return AttachmentSummarySerializer(
            attachments,
            many=True,
            context=self.context,
        ).data

    def get_applied_discounts(self, purchase_order):
        document_content_type = ContentType.objects.get_for_model(
            purchase_order,
            for_concrete_model=False,
        )
        discounts = AppliedDiscount.objects.filter(
            document_content_type=document_content_type,
            document_object_id=purchase_order.pk,
        )
        return [
            {
                "id": discount.pk,
                "rule_name": discount.rule_name,
                "coupon_code": discount.coupon_code,
                "source": discount.source,
                "scope": discount.scope,
                "value_type": discount.value_type,
                "value": f"{discount.value:.4f}",
                "discount_amount": f"{discount.discount_amount:.2f}",
                "allocations": discount.allocations,
                **rounding_metadata_payload(discount.metadata),
            }
            for discount in discounts
        ]

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
        variant_ids = [line["variant"].pk for line in value]
        if len(variant_ids) != len(set(variant_ids)):
            raise serializers.ValidationError(
                "Each variant can appear only once per purchase order."
            )
        return value

    def validate_discount_codes(self, value):
        normalized_codes = []
        for code in value:
            normalized = code.strip().upper()
            if normalized and normalized not in normalized_codes:
                normalized_codes.append(normalized)
        return normalized_codes

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
        landed_cost_entries_data = validated_data.pop("landed_cost_entries", None)
        return save_purchase_order_with_lines(
            lines_data=lines_data,
            landed_cost_entries_data=landed_cost_entries_data,
            request=self.context.get("request"),
            **validated_data,
        )

    def update(self, instance, validated_data):
        lines_data = validated_data.pop("lines", None)
        landed_cost_entries_data = validated_data.pop("landed_cost_entries", None)
        return save_purchase_order_with_lines(
            purchase_order=instance,
            lines_data=lines_data,
            landed_cost_entries_data=landed_cost_entries_data,
            request=self.context.get("request"),
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
    expiry_date = serializers.DateField(required=False, allow_null=True)
    expiration_date = serializers.DateField(required=False, allow_null=True)
    expires_on = serializers.DateField(required=False, allow_null=True)
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

        expiry_keys = [
            key for key in ("expiry_date", "expiration_date", "expires_on") if key in attrs
        ]
        if len(expiry_keys) > 1:
            expiry_values = {attrs[key] for key in expiry_keys}
            if len(expiry_values) > 1:
                raise serializers.ValidationError(
                    {"expiry_date": "Expiry date aliases must match."}
                )
        if "expiration_date" in attrs:
            attrs["expiry_date"] = attrs["expiration_date"]
            attrs.pop("expiration_date", None)
        if "expires_on" in attrs:
            attrs["expiry_date"] = attrs["expires_on"]
            attrs.pop("expires_on", None)

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
            .select_related("variant", "variant__product")
            .prefetch_related("receipt_lines")
        }
        for line_id, line_data in requested_by_line.items():
            line = lines_by_id[line_id]
            accepted_quantity = line_data.get("accepted_quantity", 0)
            damaged_quantity = line_data.get("damaged_quantity", 0)
            cancelled_quantity = line_data.get("cancelled_quantity", 0)
            expiry_date = line_data.get("expiry_date", line.expiry_date)
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
            if (
                accepted_quantity > 0
                and line.variant.product.tracks_expiry
                and expiry_date is None
            ):
                raise serializers.ValidationError(
                    {
                        "expiry_date": (
                            "Expiry date is required for received products that "
                            "track expiry."
                        )
                    }
                )
            validated_lines.append(
                {
                    "line": line,
                    "accepted_quantity": accepted_quantity,
                    "damaged_quantity": damaged_quantity,
                    "cancelled_quantity": cancelled_quantity,
                    "allowed_over_receipt_quantity": max(
                        accepted_quantity
                        + damaged_quantity
                        - line.outstanding_quantity,
                        0,
                    ),
                    "expiry_date": expiry_date,
                    "notes": line_data.get("notes", ""),
                }
            )

        attrs["validated_lines"] = validated_lines
        return attrs


class PurchaseOrderAdjustmentLineInputSerializer(serializers.Serializer):
    line = serializers.PrimaryKeyRelatedField(queryset=PurchaseLine.objects.all())
    quantity = serializers.IntegerField(min_value=1)


class PurchaseOrderReplacementLineInputSerializer(serializers.Serializer):
    variant = serializers.PrimaryKeyRelatedField(
        queryset=ProductVariant.objects.all(),
    )
    quantity = serializers.IntegerField(min_value=1)
    unit_cost = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        min_value=Decimal("0.00"),
    )

    def validate(self, attrs):
        variant = attrs.get("variant")
        if variant is None:
            raise serializers.ValidationError({"variant": "Variant is required."})
        attrs["variant"] = variant
        return attrs


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
            ).select_related("variant", "variant__product")
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
                    "variant": line.variant,
                    "quantity": quantity,
                    "unit_cost": (
                        purchase_adjustment_line_amount(line, quantity)
                        / Decimal(quantity)
                    ).quantize(Decimal("0.01")),
                }
                for line, quantity in attrs["validated_lines"]
            ]
        attrs["validated_replacement_lines"] = [
            (
                line_data["variant"],
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
