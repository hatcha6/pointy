from decimal import Decimal

from django.db.models import Manager
from rest_framework import serializers

from apps.catalog.models import ModifierOption, ProductVariant
from apps.catalog.units import (
    UnitConversionError,
    resolve_unit,
    unit_label_for,
    unit_sale_price,
    validate_quantity,
)
from apps.core.models import RelayInstallation, ShopSettings
from apps.core.roles import user_has_full_visibility, user_is_manager
from apps.customers.models import Customer
from apps.discounts.cache import (
    active_rules_exist as _active_discount_rules_exist,
    rules_version as discount_rules_version,
)
from apps.discounts.models import DiscountRule
from apps.discounts.services import rounding_metadata_payload
from .models import (
    Order,
    OrderExchange,
    OrderLine,
    RegisterCashMovement,
    RegisterSession,
    prime_register_session_cash_totals,
)
from .services import (
    assign_credit_invoice_customer,
    cashier_window_expired,
    can_adjust_order,
    calculate_sales_discounts,
    preview_sales_discounts,
    checkout_line_key,
    checkout_loss_lines,
    checkout_order,
    convert_quotation_to_sale,
    create_order_with_lines,
    exchange_order_items,
    expected_order_totals,
    record_customer_account_payment,
    record_customer_payment,
    return_order_items,
    unapplied_coupon_codes,
    validate_order_adjustment_allowed,
    void_order,
)
from .public_invoices import public_invoice_url_for_order


def sales_discount_rules_active() -> bool:
    return _active_discount_rules_exist(DiscountRule.Channel.SALES)


class RegisterSessionListSerializer(serializers.ListSerializer):
    """Batches the drawer aggregates for a whole page of sessions, so the list
    costs 3 queries instead of 16 per row."""

    def to_representation(self, data):
        # Materialise first (mirroring DRF's own Manager handling) and hand the
        # same list to the parent, so it serializes the instances we primed
        # rather than re-querying and getting cold ones.
        rows = data.all() if isinstance(data, Manager) else data
        if not isinstance(rows, list):
            rows = list(rows)
        if "expected_cash" in self.child.fields:
            prime_register_session_cash_totals(rows)
        return super().to_representation(rows)


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
    owner_name = serializers.SerializerMethodField()

    class Meta:
        model = RegisterSession
        list_serializer_class = RegisterSessionListSerializer
        fields = [
            "id",
            "session_number",
            "status",
            "owner_name",
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
            "owner_name",
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

    def to_representation(self, session):
        # A lone session (retrieve/current/close) still reads eight drawer fields
        # backed by four aggregates that the composites re-run, so prime it too:
        # 3 queries, not 16. ``RegisterSessionListSerializer`` primes the whole
        # page first, making this a no-op for list rows.
        if (
            "expected_cash" in self.fields
            and getattr(session, "_cash_sales_total", None) is None
        ):
            prime_register_session_cash_totals([session])
        return super().to_representation(session)

    def get_owner_name(self, session):
        """Who opened the session — the till accountability line. Falls back to
        the immutable owner_key when the user account was since deleted."""
        owner = session.owner
        if owner is None:
            return session.owner_key
        full_name = owner.get_full_name().strip()
        return full_name or owner.username

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        request = self.context.get("request")
        if request is None or not user_has_full_visibility(request.user):
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
    # The unit actually sold (transacted), falling back to the product's base unit
    # for legacy lines saved before per-line units existed.
    unit = serializers.SerializerMethodField()
    unit_label = serializers.SerializerMethodField()
    unit_factor = serializers.DecimalField(
        max_digits=18,
        decimal_places=6,
        read_only=True,
    )
    base_quantity = serializers.DecimalField(
        max_digits=12,
        decimal_places=3,
        read_only=True,
    )
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
            "unit_label",
            "unit_factor",
            "base_quantity",
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
            "notes",
        ]
        read_only_fields = ("unit_price", "unit_cost", "discount_total")

    def get_unit(self, line):
        return line.unit or line.variant.product.unit

    def get_unit_label(self, line):
        return unit_label_for(self.get_unit(line), self.context)

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


class ExchangeReplacementOrderSerializer(serializers.ModelSerializer):
    """Lightweight summary of the replacement sale an exchange created — avoids
    recursing into the full ``OrderSerializer``."""

    class Meta:
        model = Order
        fields = ["id", "receipt_number", "total", "created_at"]
        read_only_fields = fields


class OrderExchangeSerializer(serializers.ModelSerializer):
    created_by_username = serializers.CharField(
        source="created_by.username",
        read_only=True,
    )
    replacement_order = ExchangeReplacementOrderSerializer(read_only=True)

    class Meta:
        model = OrderExchange
        fields = [
            "id",
            "outbound_amount",
            "replacement_amount",
            "net_amount",
            "settlement_method",
            "reason",
            "return_adjustment",
            "replacement_order",
            "created_by",
            "created_by_username",
            "created_at",
        ]
        read_only_fields = fields


class OrderSerializer(serializers.ModelSerializer):
    lines = OrderLineSerializer(many=True, allow_empty=False)
    payments = OrderPaymentSerializer(many=True, read_only=True)
    exchanges = OrderExchangeSerializer(many=True, read_only=True)
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
    can_exchange = serializers.SerializerMethodField()
    can_assign_customer = serializers.SerializerMethodField()
    requires_manager_adjustment = serializers.SerializerMethodField()
    applied_discounts = serializers.SerializerMethodField()
    public_invoice_url = serializers.SerializerMethodField()
    total_cost = serializers.DecimalField(max_digits=10, decimal_places=2, read_only=True)
    total_profit = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        read_only=True,
    )
    amount_paid = serializers.DecimalField(
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

    class Meta:
        model = Order
        fields = [
            "id",
            "receipt_number",
            "status",
            "sale_type",
            "valid_until",
            "amount_paid",
            "balance_due",
            "payment_status",
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
            "exchanges",
            "subtotal",
            "discount_total",
            "total",
            "applied_discounts",
            "public_invoice_url",
            "total_cost",
            "total_profit",
            "can_void",
            "can_return",
            "can_exchange",
            "can_assign_customer",
            "requires_manager_adjustment",
            "created_at",
            "updated_at",
        ]
        read_only_fields = (
            "receipt_number",
            "sale_type",
            "valid_until",
            "amount_paid",
            "balance_due",
            "payment_status",
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
            "can_exchange",
            "can_assign_customer",
            "requires_manager_adjustment",
            "created_at",
            "updated_at",
        )

    def get_can_void(self, order):
        return self._can_adjust_order(order)

    def get_can_return(self, order):
        return self._can_adjust_order(order)

    def get_can_exchange(self, order):
        # An exchange is a return + a new sale, so it is offered exactly when the
        # order can be adjusted. The frontend additionally gates the button on the
        # operator's checkout capability.
        return self._can_adjust_order(order)

    def get_can_assign_customer(self, order):
        # Who owes a debt invoice is fixable only while nothing has been
        # collected — mirrors ``assign_credit_invoice_customer``. Reads the
        # prefetched ``payments`` cache instead of issuing an EXISTS per row.
        return (
            order.sale_type == Order.SaleType.CREDIT
            and order.status != Order.Status.VOID
            and len(order.payments.all()) == 0
        )

    def get_requires_manager_adjustment(self, order):
        return cashier_window_expired(order, settings=self._shop_settings())

    def _can_adjust_order(self, order):
        return can_adjust_order(
            order,
            is_manager=self._is_manager(),
            settings=self._shop_settings(),
        )

    def _shop_settings(self):
        # Cache the singleton in the shared serializer context so a page of
        # orders loads it once instead of once per row.
        settings = self.context.get("shop_settings")
        if settings is None:
            settings = ShopSettings.load()
            self.context["shop_settings"] = settings
        return settings

    def _is_manager(self):
        if "_is_manager" not in self.context:
            request = self.context.get("request")
            user = request.user if request is not None else None
            self.context["_is_manager"] = bool(
                user is not None and user_is_manager(user)
            )
        return self.context["_is_manager"]

    def get_applied_discounts(self, order):
        # ``applied_discounts`` is a GenericRelation prefetched by the viewset,
        # so this reuses the prefetch cache instead of querying per order row.
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
            for discount in order.applied_discounts.all()
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


class OrderListSerializer(OrderSerializer):
    """List/summary variant of OrderSerializer: a line COUNT instead of the full
    line items (the detail screen re-fetches the order on open). Serialising
    every line — each with product/variant names and a dozen cost/return fields
    — was the bulk of the invoices-list payload. ``line_count`` comes from a
    queryset annotation; everything else (totals, customer, can_*, payments) is
    unchanged."""

    lines = None  # dropped from the payload (see line_count)
    line_count = serializers.SerializerMethodField()

    class Meta(OrderSerializer.Meta):
        fields = [
            field for field in OrderSerializer.Meta.fields if field != "lines"
        ] + ["line_count"]

    def get_line_count(self, order):
        # The order still carries a light `lines` prefetch (total_cost/profit
        # read it), so count from the cache rather than the serialized array.
        return len(order.lines.all())


class OrderSessionSerializer(OrderListSerializer):
    """List variant for the register-session orders strip. Adds a
    ``has_returnable_items`` flag (the row's manager-adjust affordance needs it)
    computed from the prefetched lines, so the client no longer scans a full
    line array — nor does the line's returnable_quantity fire an adjustment-line
    query per row."""

    has_returnable_items = serializers.SerializerMethodField()

    class Meta(OrderListSerializer.Meta):
        fields = OrderListSerializer.Meta.fields + ["has_returnable_items"]

    def get_has_returnable_items(self, order):
        return any(line.returnable_quantity > 0 for line in order.lines.all())


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


class CheckoutLineModifierSerializer(serializers.Serializer):
    option = serializers.PrimaryKeyRelatedField(
        queryset=ModifierOption.objects.filter(is_active=True).select_related(
            "group",
        ),
    )
    quantity = serializers.IntegerField(min_value=1, default=1)


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
    notes = serializers.CharField(
        required=False,
        allow_blank=True,
        max_length=255,
        trim_whitespace=True,
        default="",
    )
    # The unit this line is sold in (a UnitOfMeasure.code). Blank = the product's
    # base unit. The price and stock conversion are resolved server-side.
    unit = serializers.CharField(
        required=False,
        allow_blank=True,
        max_length=32,
        trim_whitespace=True,
        default="",
    )
    modifiers = CheckoutLineModifierSerializer(
        many=True,
        required=False,
        default=list,
    )

    def validate(self, attrs):
        variant = attrs.get("variant")
        if variant is None:
            raise serializers.ValidationError({"variant": "Variant is required."})
        try:
            resolved = resolve_unit(variant.product, attrs.get("unit") or "", field="unit")
        except UnitConversionError as error:
            raise serializers.ValidationError({error.field: error.message})

        quantity = attrs.get("quantity")
        # Fractional quantities are allowed for every unit — ringing up 2.5 of any
        # product is the cashier's choice. validate_quantity is the shared seam
        # that could re-enable per-unit whole-number rules if a shop wants them.
        if quantity is not None:
            try:
                validate_quantity(quantity, resolved, field="quantity")
            except UnitConversionError as error:
                raise serializers.ValidationError({error.field: error.message})

        attrs["variant"] = variant
        attrs["unit"] = resolved.code
        attrs["unit_factor"] = resolved.factor
        # Validate the chosen modifiers against the product's assigned groups and
        # price them server-side; the client price is never trusted. The effective
        # per-unit price (the selected unit's price + modifier deltas) rides on the
        # line data so the discount engine and OrderLine creation both use it.
        delta = self._validate_and_price_modifiers(variant, attrs.get("modifiers", []))
        attrs["effective_unit_price"] = unit_sale_price(variant, resolved) + delta
        return attrs

    def _validate_and_price_modifiers(self, variant, selections):
        assigned_groups = {
            group.id: group
            for group in variant.product.modifier_groups.filter(is_active=True)
        }
        delta = Decimal("0.00")
        seen_option_ids = set()
        selected_by_group = {}
        for selection in selections:
            option = selection["option"]
            quantity = selection["quantity"]
            group = assigned_groups.get(option.group_id)
            if group is None:
                raise serializers.ValidationError(
                    {"modifiers": f"'{option.name}' is not available for this product."}
                )
            if option.id in seen_option_ids:
                raise serializers.ValidationError(
                    {"modifiers": f"'{option.name}' was selected more than once; use a quantity."}
                )
            if quantity > option.max_quantity:
                raise serializers.ValidationError(
                    {"modifiers": f"'{option.name}' allows at most {option.max_quantity}."}
                )
            seen_option_ids.add(option.id)
            selected_by_group.setdefault(group.id, []).append(option)
            delta += option.price_delta * quantity

        for group in assigned_groups.values():
            chosen = len(selected_by_group.get(group.id, []))
            if chosen < group.min_select:
                raise serializers.ValidationError(
                    {"modifiers": f"'{group.name}' requires at least {group.min_select} choice(s)."}
                )
            if group.max_select is not None and chosen > group.max_select:
                raise serializers.ValidationError(
                    {"modifiers": f"'{group.name}' allows at most {group.max_select} choice(s)."}
                )
        return delta


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
        # Empty is allowed: a fully-on-credit (آجل) or quotation sale takes no
        # payment, and the POS sends `payments: []` for it. validate() still
        # enforces the per-sale-type rules (a standard sale must cover the total).
        allow_empty=True,
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
    sale_type = serializers.ChoiceField(
        choices=Order.SaleType.choices,
        required=False,
        default=Order.SaleType.STANDARD,
    )
    # Quotation/credit expiry; for a quotation it also bounds any stock hold.
    valid_until = serializers.DateField(required=False, allow_null=True)
    # Quotation-only: hold the quoted quantities until valid_until.
    reserve_stock = serializers.BooleanField(required=False, default=False)

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
        # The amount to tender is the order's total, not the discount engine's:
        # the two round a half-cent line differently, and gating payments on the
        # engine's figure asks for a cent the order then refuses (see
        # expected_order_totals).
        _, _, total = expected_order_totals(attrs["lines"], discount_result)

        from apps.payments.models import Payment

        sale_type = attrs.get("sale_type", Order.SaleType.STANDARD)
        # A quotation (عرض سعر) or credit/debt invoice (آجل) can be required to
        # name a customer so the receivable stays collectable.
        if (
            sale_type in (Order.SaleType.QUOTATION, Order.SaleType.CREDIT)
            and settings.require_customer_for_credit
            and attrs.get("customer") is None
        ):
            raise serializers.ValidationError(
                {"customer": "A customer is required for a quotation or debt invoice."}
            )

        # A stock hold must be bounded. ``release_expired_quote_reservations``
        # only ever sees quotations with a ``valid_until`` in the past, and an
        # OPEN quotation cannot be voided, so a hold placed without a deadline
        # has no release path at all — the quoted units stay committed, and
        # therefore unsellable, forever. Refuse it here rather than strand it.
        if (
            sale_type == Order.SaleType.QUOTATION
            and attrs.get("reserve_stock")
            and attrs.get("valid_until") is None
        ):
            raise serializers.ValidationError(
                {
                    "valid_until": (
                        "A quotation that reserves stock must set valid_until: "
                        "the hold is released when the offer lapses."
                    )
                }
            )

        payments = attrs.get("payments")
        if payments is None:
            payment_method = attrs.get("payment_method", Payment.Method.CASH)
            # Default tender by sale type: a standard sale is paid in full; a
            # credit sale takes only the optional down-payment (default none); a
            # quotation takes nothing.
            if sale_type == Order.SaleType.QUOTATION:
                default_amount = Decimal("0.00")
            elif sale_type == Order.SaleType.CREDIT:
                default_amount = attrs.get("amount_received") or Decimal("0.00")
            else:
                default_amount = attrs.get("amount_received", total)
            if default_amount > 0:
                if not settings.payment_method_enabled(payment_method):
                    raise serializers.ValidationError(
                        {"payment_method": "Payment method is disabled."}
                    )
                payments = [{"method": payment_method, "amount": default_amount}]
            else:
                payments = []

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
        # Payment rules by sale type: a quotation takes no money; a credit sale
        # allows a partial (or zero) down-payment but never an overpayment; a
        # standard sale must be paid exactly in full.
        if sale_type == Order.SaleType.QUOTATION:
            if paid_total > 0:
                raise serializers.ValidationError(
                    {"payments": "A quotation cannot take a payment."}
                )
        elif sale_type == Order.SaleType.CREDIT:
            if paid_total > total:
                raise serializers.ValidationError(
                    {"payments": "Payment total cannot exceed the order total."}
                )
        else:
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
            sale_type=validated_data.get("sale_type", Order.SaleType.STANDARD),
            valid_until=validated_data.get("valid_until"),
            reserve_stock=validated_data.get("reserve_stock", False),
            request=self.context.get("request"),
        )


def normalized_checkout_coupon_codes(attrs):
    coupon_codes = list(attrs.get("coupon_codes") or [])
    single_code = attrs.get("coupon_code")
    if single_code:
        coupon_codes.append(single_code)
    return tuple(coupon_codes)


class CustomerInvoicePaymentSerializer(serializers.Serializer):
    """Record a single payment against one invoice's balance. Mirrors the PO
    supplier-payment dialog. Context: ``order``, ``register_session``, ``request``."""

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
    )

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        from apps.payments.models import Payment

        self.fields["method"].choices = Payment.Method.choices

    def save(self, **kwargs):
        return record_customer_payment(
            self.context["order"],
            method=self.validated_data["method"],
            amount=self.validated_data["amount"],
            card_receipt_url=self.validated_data.get("card_receipt_url", ""),
            register_session=self.context["register_session"],
            request=self.context.get("request"),
        )


class CustomerAccountPaymentSerializer(serializers.Serializer):
    """Record a payment against a customer's account, allocated oldest-first
    across their open debt invoices. Cash, transfer, or card — a card swipe is one
    receipt for the whole collection, validated once against the total then split.
    Context: ``customer``, ``register_session``, ``request``."""

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
    )

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        from apps.payments.models import Payment

        self.fields["method"].choices = [
            (Payment.Method.CASH, "Cash"),
            (Payment.Method.TRANSFER, "Transfer"),
            (Payment.Method.CARD, "Card"),
        ]

    def save(self, **kwargs):
        return record_customer_account_payment(
            self.context["customer"],
            method=self.validated_data["method"],
            amount=self.validated_data["amount"],
            card_receipt_url=self.validated_data.get("card_receipt_url", ""),
            register_session=self.context["register_session"],
            request=self.context.get("request"),
        )


class OrderAssignCustomerSerializer(serializers.Serializer):
    """Assign or change the customer who owes a debt (آجل) invoice — allowed
    only while no payment has been recorded against it. Context: ``order``,
    ``request``."""

    customer = serializers.PrimaryKeyRelatedField(queryset=Customer.objects.all())

    def save(self, **kwargs):
        return assign_credit_invoice_customer(
            self.context["order"],
            customer=self.validated_data["customer"],
            request=self.context.get("request"),
        )


class ConvertQuotationSerializer(serializers.Serializer):
    """Convert a quotation into a standard or credit sale, optionally taking a
    down-payment. Context: ``quotation``, ``register_session``, ``request``."""

    sale_type = serializers.ChoiceField(
        choices=[
            (Order.SaleType.STANDARD, "Standard"),
            (Order.SaleType.CREDIT, "Credit"),
        ],
    )
    payments = CheckoutPaymentSerializer(many=True, required=False, allow_empty=True)
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

    def validate(self, attrs):
        payments = attrs.get("payments")
        if payments is None:
            amount = attrs.get("amount_received") or Decimal("0.00")
            if amount > 0:
                from apps.payments.models import Payment

                method = attrs.get("payment_method", Payment.Method.CASH)
                payments = [{"method": method, "amount": amount}]
            else:
                payments = []
        attrs["payments_data"] = payments
        return attrs

    def save(self, **kwargs):
        return convert_quotation_to_sale(
            self.context["quotation"],
            sale_type=self.validated_data["sale_type"],
            payments_data=self.validated_data["payments_data"],
            register_session=self.context["register_session"],
            request=self.context.get("request"),
        )


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
        # Preview runs on every cart edit -> use the Redis-guarded path. Checkout
        # (above) stays on the live calculate_sales_discounts.
        discount_result = preview_sales_discounts(
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
        # The cart figures the cashier reads — and then tenders — must be the
        # ones the order will store, so the preview can never quote a total
        # checkout would reject (see expected_order_totals).
        subtotal, discount_total, total = expected_order_totals(
            self.validated_data["lines"], discount_result
        )
        return {
            "subtotal": f"{subtotal:.2f}",
            "discount_total": f"{discount_total:.2f}",
            "total": f"{total:.2f}",
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
            # Gate state for the POS: when no active rule targets sales, the
            # client latches "no rules @ this version" and stops previewing on
            # every cart edit until the pushed X-Pointy-Discounts-Version
            # changes — the preview becomes local arithmetic, so its failure
            # mode (تعذر تحديث الخصومات) can no longer occur for shops that
            # run no promotions. Fail-open: Redis trouble reports active=True.
            "rules_active": sales_discount_rules_active(),
            "rules_version": discount_rules_version(),
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


def validate_returnable_lines(order, lines):
    """Validate ``[{line, quantity}]`` adjustment input against an order: each
    line must belong to the order and the (summed) requested quantity must not
    exceed its remaining ``returnable_quantity``. Returns ``[(OrderLine, qty)]``.
    Shared by the return and exchange serializers.
    """
    requested_by_line = {}
    for line_data in lines:
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
    return validated_lines


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
        attrs["validated_lines"] = validate_returnable_lines(
            self.context["order"], attrs["lines"]
        )
        return attrs

    def save(self, **kwargs):
        return return_order_items(
            order=self.context["order"],
            lines=self.validated_data["validated_lines"],
            reason=self.validated_data.get("reason", ""),
            request=self.context.get("request"),
            register_session=self.context.get("adjustment_register_session"),
        )


class OrderExchangeInputSerializer(serializers.Serializer):
    """Return the chosen original line(s) and ring up replacement item(s) at
    current price in one operation. ``lines`` are returnable outbound lines (same
    shape as a return); ``replacement_lines`` reuse the checkout line serializer
    so the replacement is priced and validated exactly like a normal sale.
    """

    lines = OrderAdjustmentLineInputSerializer(many=True, allow_empty=False)
    replacement_lines = CheckoutLineSerializer(many=True, allow_empty=False)
    settlement_method = serializers.ChoiceField(choices=[], required=False)
    reason = serializers.CharField(required=False, allow_blank=True, trim_whitespace=True)

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        from apps.payments.models import Payment

        self.fields["settlement_method"].choices = Payment.Method.choices
        self.fields["settlement_method"].default = Payment.Method.CASH

    def validate(self, attrs):
        from apps.payments.models import Payment

        order = self.context["order"]
        request = self.context.get("request")
        # A trusted returns-desk operator (holds ``sales.process_return_lookup``)
        # may adjust any looked-up invoice regardless of the cashier window.
        allow_window_override = bool(
            request is not None
            and request.user.has_perm("sales.process_return_lookup")
        )
        validate_order_adjustment_allowed(
            order,
            request=request,
            allow_window_override=allow_window_override,
        )
        attrs["validated_lines"] = validate_returnable_lines(order, attrs["lines"])
        attrs["allow_window_override"] = allow_window_override
        attrs["settlement_method"] = (
            attrs.get("settlement_method") or Payment.Method.CASH
        )
        return attrs

    def save(self, **kwargs):
        return exchange_order_items(
            order=self.context["order"],
            outbound_lines=self.validated_data["validated_lines"],
            replacement_lines=self.validated_data["replacement_lines"],
            settlement_method=self.validated_data["settlement_method"],
            reason=self.validated_data.get("reason", ""),
            request=self.context.get("request"),
            register_session=self.context.get("adjustment_register_session"),
            allow_window_override=self.validated_data["allow_window_override"],
        )
