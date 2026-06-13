from decimal import Decimal

from django.contrib.contenttypes.models import ContentType
from rest_framework import serializers

from apps.catalog.models import ProductVariant
from apps.core.models import RelayInstallation, ShopSettings
from apps.core.roles import user_is_manager
from apps.customers.models import Customer
from apps.discounts.models import AppliedDiscount
from apps.discounts.services import rounding_metadata_payload
from .models import (
    Order,
    OrderLine,
    RegisterCashMovement,
    RegisterSession,
)
from .services import (
    cashier_window_expired,
    can_adjust_order,
    calculate_sales_discounts,
    checkout_line_key,
    checkout_loss_lines,
    checkout_order,
    create_order_with_lines,
    return_order_items,
    unapplied_coupon_codes,
    validate_order_adjustment_allowed,
    void_order,
)
from .public_invoices import public_invoice_url_for_order


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
    product = serializers.IntegerField(source="variant.product_id", read_only=True)
    variant = serializers.PrimaryKeyRelatedField(
        queryset=ProductVariant.objects.active(),
    )
    product_name = serializers.CharField(source="variant.product.name", read_only=True)
    variant_name = serializers.CharField(source="variant.display_name", read_only=True)
    line_subtotal = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        read_only=True,
    )
    line_total = serializers.DecimalField(max_digits=10, decimal_places=2, read_only=True)
    line_cost = serializers.DecimalField(max_digits=10, decimal_places=2, read_only=True)
    line_profit = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        read_only=True,
    )
    quantity = serializers.DecimalField(
        max_digits=10,
        decimal_places=3,
        coerce_to_string=False,
    )
    unit = serializers.CharField(source="variant.product.unit", read_only=True)
    returned_quantity = serializers.FloatField(read_only=True)
    returnable_quantity = serializers.FloatField(read_only=True)

    class Meta:
        model = OrderLine
        fields = [
            "id",
            "product",
            "variant",
            "product_name",
            "variant_name",
            "unit",
            "quantity",
            "returned_quantity",
            "returnable_quantity",
            "unit_price",
            "unit_cost",
            "line_subtotal",
            "discount_total",
            "line_total",
            "line_cost",
            "line_profit",
        ]
        read_only_fields = ("unit_price", "unit_cost", "discount_total")

    def validate_quantity(self, value):
        if value < 1:
            raise serializers.ValidationError("Quantity must be positive.")
        return value

    def validate(self, attrs):
        variant = attrs.get("variant")
        if variant is None:
            raise serializers.ValidationError({"variant": "Variant is required."})
        attrs["variant"] = variant
        return attrs


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
    card_receipt_data = serializers.JSONField(read_only=True)
    created_at = serializers.DateTimeField(read_only=True)


class OrderSerializer(serializers.ModelSerializer):
    lines = OrderLineSerializer(many=True, allow_empty=False)
    payments = OrderPaymentSerializer(many=True, read_only=True)
    customer_number = serializers.CharField(
        source="customer.customer_number",
        read_only=True,
    )
    customer_name = serializers.CharField(source="customer.full_name", read_only=True)
    customer_phone = serializers.CharField(source="customer.phone", read_only=True)
    customer_email = serializers.CharField(source="customer.email", read_only=True)
    register_session_number = serializers.CharField(
        source="register_session.session_number",
        read_only=True,
    )
    sales_channel_name = serializers.CharField(source="sales_channel.name", read_only=True)
    sales_channel_slug = serializers.CharField(source="sales_channel.slug", read_only=True)
    can_void = serializers.SerializerMethodField()
    can_return = serializers.SerializerMethodField()
    requires_manager_adjustment = serializers.SerializerMethodField()
    applied_discounts = serializers.SerializerMethodField()
    public_invoice_url = serializers.SerializerMethodField()
    total_cost = serializers.DecimalField(max_digits=10, decimal_places=2, read_only=True)
    total_profit = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
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
            "sales_channel",
            "sales_channel_name",
            "sales_channel_slug",
            "customer",
            "customer_number",
            "customer_name",
            "customer_phone",
            "customer_email",
            "lines",
            "payments",
            "subtotal",
            "discount_total",
            "total",
            "applied_discounts",
            "public_invoice_url",
            "total_cost",
            "total_profit",
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
            "sales_channel",
            "sales_channel_name",
            "sales_channel_slug",
            "customer_number",
            "customer_name",
            "customer_phone",
            "customer_email",
            "subtotal",
            "discount_total",
            "total",
            "applied_discounts",
            "public_invoice_url",
            "total_cost",
            "total_profit",
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

    def get_applied_discounts(self, order):
        document_content_type = ContentType.objects.get_for_model(
            order,
            for_concrete_model=False,
        )
        discounts = AppliedDiscount.objects.filter(
            document_content_type=document_content_type,
            document_object_id=order.pk,
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

    def get_public_invoice_url(self, order):
        settings = self.context.get("shop_settings")
        if settings is None:
            settings = ShopSettings.load()
            self.context["shop_settings"] = settings
        if not settings.enable_online_invoices:
            return ""
        if "_relay_installation" not in self.context:
            self.context["_relay_installation"] = RelayInstallation.load()
        return public_invoice_url_for_order(
            order,
            shop_settings=settings,
            relay_installation=self.context["_relay_installation"],
        )

    def create(self, validated_data):
        lines_data = validated_data.pop("lines", [])
        return create_order_with_lines(lines_data=lines_data, **validated_data)


class PublicInvoiceLineSerializer(serializers.ModelSerializer):
    product_name = serializers.CharField(source="variant.product.name", read_only=True)
    variant_name = serializers.CharField(source="variant.display_name", read_only=True)
    quantity = serializers.DecimalField(
        max_digits=10,
        decimal_places=3,
        coerce_to_string=False,
        read_only=True,
    )
    line_subtotal = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        read_only=True,
    )
    line_total = serializers.DecimalField(max_digits=10, decimal_places=2, read_only=True)

    class Meta:
        model = OrderLine
        fields = [
            "product_name",
            "variant_name",
            "quantity",
            "unit_price",
            "line_subtotal",
            "discount_total",
            "line_total",
        ]


class PublicInvoiceSerializer(serializers.ModelSerializer):
    shop_name = serializers.SerializerMethodField()
    receipt_header = serializers.SerializerMethodField()
    receipt_footer = serializers.SerializerMethodField()
    shop_logo_data_uri = serializers.SerializerMethodField()
    customer_name = serializers.CharField(source="customer.full_name", read_only=True)
    lines = PublicInvoiceLineSerializer(many=True, read_only=True)

    class Meta:
        model = Order
        fields = [
            "shop_name",
            "receipt_header",
            "receipt_footer",
            "shop_logo_data_uri",
            "receipt_number",
            "status",
            "customer_name",
            "lines",
            "subtotal",
            "discount_total",
            "total",
            "created_at",
        ]

    def _settings(self):
        settings = self.context.get("shop_settings")
        if settings is None:
            settings = ShopSettings.load()
            self.context["shop_settings"] = settings
        return settings

    def get_shop_name(self, order):
        return self._settings().shop_name

    def get_receipt_header(self, order):
        return self._settings().receipt_header

    def get_receipt_footer(self, order):
        return self._settings().receipt_footer

    def get_shop_logo_data_uri(self, order):
        # Embedded as a data URI because the public invoice page is served
        # through the relay: a signed LAN content URL would not be reachable
        # from the visitor's browser.
        if "shop_logo_data_uri" not in self.context:
            from apps.attachments.models import Attachment
            from apps.attachments.services import active_attachments_for
            from apps.printing.services import shop_logo_base64

            settings = self._settings()
            encoded = shop_logo_base64(settings)
            attachment = (
                active_attachments_for(
                    settings,
                    role=Attachment.Role.SHOP_LOGO,
                )
                .filter(is_primary=True)
                .first()
                if encoded is not None
                else None
            )
            if encoded is None or attachment is None:
                self.context["shop_logo_data_uri"] = ""
            else:
                content_type = attachment.content_type or "image/png"
                self.context["shop_logo_data_uri"] = (
                    f"data:{content_type};base64,{encoded}"
                )
        return self.context["shop_logo_data_uri"]


class CheckoutLineSerializer(serializers.Serializer):
    variant = serializers.PrimaryKeyRelatedField(
        queryset=ProductVariant.objects.active().select_related("product"),
    )
    quantity = serializers.DecimalField(
        max_digits=10,
        decimal_places=3,
        min_value=Decimal("0.001"),
        coerce_to_string=False,
    )

    def validate(self, attrs):
        variant = attrs.get("variant")
        if variant is None:
            raise serializers.ValidationError({"variant": "Variant is required."})
        quantity = attrs.get("quantity")
        # Only metric (weighted/volume) products sell in fractions; pieces
        # stay whole so a scanner glitch can never ring up 0.5 of a phone.
        if (
            quantity is not None
            and variant.product.unit == "piece"
            and quantity != quantity.to_integral_value()
        ):
            raise serializers.ValidationError(
                {"quantity": "Piece products sell in whole units."}
            )
        attrs["variant"] = variant
        return attrs


class CheckoutPaymentSerializer(serializers.Serializer):
    method = serializers.ChoiceField(choices=[])
    amount = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        min_value=Decimal("0.01"),
    )
    card_receipt_url = serializers.CharField(
        required=False,
        allow_blank=True,
        trim_whitespace=True,
        write_only=True,
    )

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        from apps.payments.models import Payment

        self.fields["method"].choices = Payment.Method.choices


class CheckoutSerializer(serializers.Serializer):
    lines = CheckoutLineSerializer(many=True, allow_empty=False)
    customer = serializers.PrimaryKeyRelatedField(
        queryset=Customer.objects.all(),
        required=False,
        allow_null=True,
    )
    payments = CheckoutPaymentSerializer(
        many=True,
        allow_empty=False,
        required=False,
    )
    payment_method = serializers.ChoiceField(required=False, choices=[])
    amount_received = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        min_value=Decimal("0.00"),
        required=False,
    )
    coupon_code = serializers.CharField(
        required=False,
        allow_blank=True,
        trim_whitespace=True,
        write_only=True,
    )
    coupon_codes = serializers.ListField(
        child=serializers.CharField(allow_blank=False, trim_whitespace=True),
        required=False,
        allow_empty=True,
        write_only=True,
    )

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        from apps.payments.models import Payment

        self.fields["payment_method"].choices = Payment.Method.choices
        self.fields["payment_method"].default = Payment.Method.CASH

    def validate(self, attrs):
        settings = ShopSettings.load()
        coupon_codes = normalized_checkout_coupon_codes(attrs)
        discount_result = calculate_sales_discounts(
            lines_data=attrs["lines"],
            customer=attrs.get("customer"),
            coupon_codes=coupon_codes,
        )
        missing_coupon_codes = unapplied_coupon_codes(discount_result, coupon_codes)
        if missing_coupon_codes:
            raise serializers.ValidationError(
                {"coupon_codes": "Coupon code is invalid or unavailable."}
            )
        total = discount_result.total

        payments = attrs.get("payments")
        if payments is None:
            from apps.payments.models import Payment

            payment_method = attrs.get("payment_method", Payment.Method.CASH)
            if not settings.payment_method_enabled(payment_method):
                raise serializers.ValidationError(
                    {"payment_method": "Payment method is disabled."}
                )
            payments = [
                {
                    "method": payment_method,
                    "amount": attrs.get("amount_received", total),
                }
            ]

        disabled_methods = [
            payment["method"]
            for payment in payments
            if not settings.payment_method_enabled(payment["method"])
        ]
        if disabled_methods:
            raise serializers.ValidationError(
                {"payments": "One or more payment methods are disabled."}
            )

        paid_total = sum(
            (payment["amount"] for payment in payments),
            Decimal("0.00"),
        ).quantize(Decimal("0.01"))
        if paid_total < total:
            raise serializers.ValidationError(
                {"payments": "Payment total must cover the order total."}
            )
        if paid_total > total:
            raise serializers.ValidationError(
                {"payments": "Payment total cannot exceed the order total."}
            )

        attrs["computed_total"] = total
        attrs["discount_result"] = discount_result
        attrs["coupon_codes"] = coupon_codes
        attrs["payments"] = payments
        return attrs

    def create(self, validated_data):
        return checkout_order(
            register_session=self.context["register_session"],
            lines_data=validated_data["lines"],
            payments_data=validated_data["payments"],
            customer=validated_data.get("customer"),
            coupon_codes=validated_data.get("coupon_codes", ()),
            discount_result=validated_data.get("discount_result"),
            request=self.context.get("request"),
        )


def normalized_checkout_coupon_codes(attrs):
    coupon_codes = list(attrs.get("coupon_codes") or [])
    single_code = attrs.get("coupon_code")
    if single_code:
        coupon_codes.append(single_code)
    return tuple(coupon_codes)


class DiscountPreviewSerializer(serializers.Serializer):
    lines = CheckoutLineSerializer(many=True, allow_empty=False)
    customer = serializers.PrimaryKeyRelatedField(
        queryset=Customer.objects.all(),
        required=False,
        allow_null=True,
    )
    coupon_code = serializers.CharField(
        required=False,
        allow_blank=True,
        trim_whitespace=True,
        write_only=True,
    )
    coupon_codes = serializers.ListField(
        child=serializers.CharField(allow_blank=False, trim_whitespace=True),
        required=False,
        allow_empty=True,
        write_only=True,
    )

    def validate(self, attrs):
        coupon_codes = normalized_checkout_coupon_codes(attrs)
        discount_result = calculate_sales_discounts(
            lines_data=attrs["lines"],
            customer=attrs.get("customer"),
            coupon_codes=coupon_codes,
        )
        attrs["coupon_codes"] = coupon_codes
        attrs["discount_result"] = discount_result
        return attrs

    @property
    def preview_data(self):
        discount_result = self.validated_data["discount_result"]
        coupon_codes = self.validated_data.get("coupon_codes", ())
        lines_by_key = {
            checkout_line_key(line_data): line_data
            for line_data in self.validated_data["lines"]
        }
        return {
            "subtotal": f"{discount_result.subtotal:.2f}",
            "discount_total": f"{discount_result.discount_total:.2f}",
            "total": f"{discount_result.total:.2f}",
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
                    "allocations": preview_allocation_dicts(
                        application,
                        lines_by_key,
                    ),
                }
                for application in discount_result.applications
            ],
            "unapplied_coupon_codes": unapplied_coupon_codes(
                discount_result,
                coupon_codes,
            ),
            "loss_lines": checkout_loss_lines(
                self.validated_data["lines"],
                discount_result,
            ),
        }


def preview_allocation_dicts(application, lines_by_key):
    allocations = []
    for allocation in application.allocations:
        data = allocation.as_dict()
        line_data = lines_by_key.get(allocation.line_key)
        if line_data is not None:
            variant = line_data["variant"]
            data.update(
                {
                    "product_id": variant.product_id,
                    "variant_id": variant.pk,
                    "product_name": variant.full_name,
                    "parent_product_name": variant.product.name,
                    "variant_name": variant.name.strip() or variant.display_name,
                    "sku": variant.sku,
                    "barcode": variant.barcode,
                }
            )
        allocations.append(data)
    return allocations


class OrderAdjustmentLineInputSerializer(serializers.Serializer):
    line = serializers.PrimaryKeyRelatedField(queryset=OrderLine.objects.all())
    quantity = serializers.DecimalField(
        max_digits=10,
        decimal_places=3,
        min_value=Decimal("0.001"),
    )


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
            ).select_related("variant", "variant__product")
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
