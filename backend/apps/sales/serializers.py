from decimal import Decimal

from django.db.models import Manager
from rest_framework import serializers

from apps.documents.serializers import DocumentLifecycleFields
from apps.catalog.models import ModifierOption, ProductVariant
from apps.catalog.services import MIN_LINES_TO_PRELOAD, load_line_variants
from apps.integrations.fulfillment import (
    IntegrationLineSerializer,
    fulfillment_kind,
    resolve_line_integration,
    voucher_line_payload,
)
from apps.catalog.units import (
    UnitConversionError,
    resolve_unit,
    unit_label_for,
    unit_sale_price,
    validate_quantity,
)
from apps.core.models import RelayInstallation, ShopSettings
from apps.core.roles import user_has_full_visibility, user_is_manager
from apps.core.timeutils import business_local_date
from apps.customers.models import Customer
from apps.customers.payment_terms import MAX_CREDIT_DAYS
from apps.discounts.cache import (
    active_rules_exist as _active_discount_rules_exist,
    rules_version as discount_rules_version,
)
from apps.discounts.models import DiscountRule
from apps.treasury.models import MoneyAccount
from apps.discounts.services import rounding_metadata_payload
from .tracked_lines import order_line_identifiers
from .tracked_return import BUY_IN, CONSIGNMENT_ACTIONS
from .models import (
    Order,
    OrderExchange,
    OrderLine,
    RegisterCashMovement,
    RegisterProfile,
    RegisterSession,
    prime_register_session_cash_totals,
)
from .services import (
    RECEIPT_DELIVERY_CHOICES,
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
    reschedule_credit_invoice_due_date,
    return_order_items,
    clamped_manual_discount,
    manual_discount_room,
    unapplied_coupon_codes,
    validate_manual_discount_allowed,
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
        return session.owner_display_name

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
    # What identified stock this line actually issued. Empty for every line of
    # everything a shop counts rather than identifies — which is the constraint
    # this whole feature is written under — and the warranty document for the
    # lines where it is not: a receipt that does not name the IMEI is a receipt
    # that cannot settle a warranty claim two years later.
    identifiers = serializers.SerializerMethodField()
    # A top-up sold on this line: whose card, what was bought, and whether the
    # provider has actually done it. The invoice is where a shop looks when a
    # customer comes back saying their TV is still off, so it has to say more
    # than "شحن اشتراك HD Box · 240.00".
    integration = serializers.SerializerMethodField()

    def get_integration(self, line):
        fulfillment = getattr(line, "integration_fulfillment", None)
        if fulfillment is None:
            return None
        subscriber = fulfillment.subscriber
        return {
            "provider": fulfillment.provider,
            # ``voucher`` for a card off a provider's shelf — its PIN is in
            # ``receipt`` — else ``recharge``.
            "kind": fulfillment_kind(fulfillment),
            "subscriber_ref": fulfillment.subscriber_ref,
            "subscriber_label": subscriber.label if subscriber else "",
            "customer_id": subscriber.customer_id if subscriber else None,
            "option_label": fulfillment.option_label,
            "months": fulfillment.months,
            "package_name": fulfillment.package_name,
            "cost": fulfillment.cost,
            "status": fulfillment.status,
            # Present once the provider has confirmed it — either in its reply
            # or, later, in its own purchase log. The proof the customer got it.
            "provider_reference": fulfillment.provider_reference,
            "confirmed_at": fulfillment.confirmed_at,
            "provider_receipt": fulfillment.provider_receipt,
            # The provider's own printed slip, already reduced to the fields
            # worth reprinting beside Pointy's invoice.
            "receipt": (fulfillment.provider_receipt or {}).get("printed") or {},
            # Why the last attempt did not land, as a code the client can act
            # on — "top up the float" is a different screen from "try again".
            "error_code": fulfillment.last_error_code,
            "attempt_count": fulfillment.attempt_count,
            # A write went out and we never learned what it did. Nothing may
            # retry it; somebody has to look at the card.
            "needs_attention": (
                fulfillment.status == fulfillment.Status.SUBMITTED
            ),
        }

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
            "identifiers",
            "integration",
            "notes",
        ]
        read_only_fields = ("unit_price", "unit_cost", "discount_total")

    def get_identifiers(self, line):
        """The serials and lots this line moved, for the printed document.

        Read from the units the sale stamped and from the allocations the
        ledger wrote, in that order, because they answer two different
        questions: a serialized line names *its own articles*, while a
        lot-tracked line names the cohorts the FEFO pick actually drew from —
        which may be two of them for one line, and is what a pharmacy is
        legally required to print.
        """
        return order_line_identifiers(line)

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
    # Which bank took this money, spelled out rather than left as an id: the
    # invoice details screen draws the bank's own mark beside the tender, and
    # a details surface that had to fetch an account per payment row would be
    # the list-row-is-not-a-document trap in a new place.
    money_account = serializers.IntegerField(
        source="money_account_id", read_only=True
    )
    money_account_name = serializers.CharField(
        source="money_account.name", read_only=True, default=""
    )
    money_account_bank_slug = serializers.CharField(
        source="money_account.bank_slug", read_only=True, default=""
    )
    money_account_bank_name = serializers.CharField(
        source="money_account.bank_name", read_only=True, default=""
    )
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


class OrderSerializer(DocumentLifecycleFields, serializers.ModelSerializer):
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
    # Who rang the sale up. Derived from the drawer session rather than stored
    # on the order: the session already owns that fact, and a second copy is a
    # second thing that can disagree with the Z-Report.
    cashier = serializers.IntegerField(
        source="register_session.owner_id",
        read_only=True,
    )
    cashier_name = serializers.CharField(
        source="register_session.owner_display_name",
        read_only=True,
    )
    sales_channel_name = serializers.CharField(source="sales_channel.name", read_only=True)
    sales_channel_slug = serializers.CharField(source="sales_channel.slug", read_only=True)
    card_receipt_status = serializers.SerializerMethodField()
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
            *DocumentLifecycleFields.LIFECYCLE_FIELDS,
            "sale_type",
            "valid_until",
            "due_date",
            "is_overdue",
            "days_overdue",
            "amount_paid",
            "balance_due",
            "payment_status",
            "register_session",
            "register_session_number",
            "cashier",
            "cashier_name",
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
            "card_receipt_status",
            "exchanges",
            "subtotal",
            "discount_total",
            "extra_discount_amount",
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
            "due_date",
            "is_overdue",
            "days_overdue",
            "amount_paid",
            "balance_due",
            "payment_status",
            "register_session",
            "register_session_number",
            "cashier",
            "cashier_name",
            "sales_channel",
            "sales_channel_name",
            "sales_channel_slug",
            "customer_number",
            "customer_name",
            "customer_phone",
            "customer_email",
            "subtotal",
            "discount_total",
            "extra_discount_amount",
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

    def get_card_receipt_status(self, order):
        """One word for how well this invoice's CARD money is backed by receipts.

        Worst state wins, because the badge exists to surface the invoices that
        need a human: an invoice with one proved receipt and one the issuer
        disowned is a problem, not a success. Reads the prefetched payments, so
        it costs the list no extra query.

        ``none`` means there is nothing to say -- no card payment, or a shop
        that does not scan receipts -- and the client shows no badge at all
        rather than an empty tick.
        """
        from apps.payments.card_receipts.base import (
            MISMATCH,
            PENDING,
            REJECTED,
            SETTLED,
            UNAVAILABLE,
        )
        from apps.payments.models import Payment

        states = set()
        for payment in order.payments.all():
            if payment.method != Payment.Method.CARD or payment.amount <= 0:
                continue
            data = payment.card_receipt_data or {}
            if not data:
                states.add("no_receipt")
                continue
            # A receipt stored before verification states existed was checked at
            # the counter against its own decoded payload.
            states.add(data.get("verification_state") or SETTLED)

        if not states:
            return "none"
        for state, label in (
            (MISMATCH, "flagged"),
            (REJECTED, "flagged"),
            (PENDING, "pending"),
            (UNAVAILABLE, "unavailable"),
            ("no_receipt", "no_receipt"),
        ):
            if state in states:
                return label
        return "verified"

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
            "extra_discount_amount",
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


def _variant_pks(raw_lines):
    """The variant pks raw cart lines name. Preloading runs before field
    validation, so anything that is not a plain pk is skipped here and left for
    the field itself to reject."""
    for raw_line in raw_lines:
        try:
            yield int(raw_line["variant"])
        except (TypeError, ValueError, KeyError):
            continue


def load_line_stock_units(raw_lines):
    """``{pk: unit}`` for every identified article the raw cart lines name.

    Runs before field validation, like the variant preload above, so anything
    that is not a plain pk is skipped here and left for the field to reject.
    """
    from apps.inventory.models import StockUnit

    ids = set()
    for raw_line in raw_lines:
        for value in raw_line.get("stock_units") or []:
            try:
                ids.add(int(value))
            except (TypeError, ValueError):
                continue
    if not ids:
        return {}
    return StockUnit.objects.in_bulk(ids)


class CheckoutLineListSerializer(serializers.ListSerializer):
    """Resolve every cart line's variant in one bulk load, before the lines
    validate.

    ``CheckoutLineSerializer.validate`` reads its variant's product modifier
    groups and units, and the discount engine then reads the product's
    categories — but DRF's ``PrimaryKeyRelatedField`` hands the child a bare
    instance, so each of those cost a query *per line* on the two busiest till
    endpoints: checkout, and the discount preview the POS fires on every cart
    edit. The child's ``validate`` swaps in the enriched instance from here.

    It has to happen before the children run: by the time the parent
    serializer's own ``validate`` (or ``checkout_order``) could preload, every
    line has already paid for its own reads.
    """

    def to_internal_value(self, data):
        self.preloaded_variants = {}
        self.preloaded_units = {}
        if isinstance(data, list):
            lines = [line for line in data if isinstance(line, dict)]
            if len(data) >= MIN_LINES_TO_PRELOAD:
                self.preloaded_variants = load_line_variants(_variant_pks(lines))
            # Unconditionally, unlike the variants above: a serialized cart is
            # very often one line, and that line's price comes off the article
            # rather than off the product (§5.7). One query, and none at all for
            # the shop that identifies nothing.
            self.preloaded_units = load_line_stock_units(lines)
        return super().to_internal_value(data)


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
    # Identified stock, when the till knows which article it is ringing up: the
    # IMEI the cashier scanned, the units a picker chose, the lot a customer
    # asked for. All optional and all absent for every product that is a number
    # in a bin, which is the constraint this whole feature is written under — a
    # shop that sells Coca-Cola must not be able to tell that it shipped.
    stock_units = serializers.ListField(
        child=serializers.IntegerField(min_value=1),
        required=False,
        default=list,
    )
    stock_unit_codes = serializers.ListField(
        child=serializers.CharField(max_length=120, trim_whitespace=True),
        required=False,
        default=list,
    )
    stock_batches = serializers.ListField(
        child=serializers.IntegerField(min_value=1),
        required=False,
        default=list,
    )
    # A top-up bought from an outside provider (apps.integrations). Present
    # only on the provider's own service product; the price it sells at is
    # computed from the shop's markup setting, never taken from this payload.
    integration = IntegrationLineSerializer(required=False)

    # What a cashier repriced this line to, per unit, in the cart.
    #
    # The ONE place a client price is believed, and only from somebody holding
    # `sales.override_line_price`. Everything else on this line is priced
    # server-side precisely so a till cannot assert a margin; this is the
    # deliberate exception, and it is recorded rather than waved through: the
    # line keeps what it would have sold for, and the shop's
    # prevent_selling_at_loss guard still reads the overridden figure, so
    # repricing below cost is refused exactly as a discount to the same number
    # would be.
    unit_price = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        min_value=Decimal("0"),
        required=False,
        allow_null=True,
    )

    class Meta:
        list_serializer_class = CheckoutLineListSerializer

    def validate(self, attrs):
        variant = attrs.get("variant")
        if variant is None:
            raise serializers.ValidationError({"variant": "Variant is required."})
        # Use the cart-wide bulk load when there is one (see
        # CheckoutLineListSerializer): the units, modifier groups and categories
        # read below are prefetched on that instance and would each cost a query
        # on the bare one the field resolved.
        preloaded = getattr(self.parent, "preloaded_variants", None)
        if preloaded:
            variant = preloaded.get(variant.pk, variant)
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
        # ``is None``, not ``or``: a unit priced at zero is a real thing — a
        # warranty replacement handed over at no charge — and ``or`` would
        # quietly charge the variant's price for it.
        asking = self._unit_asking_price(attrs, resolved)
        if asking is None:
            asking = unit_sale_price(variant, resolved)
        attrs["effective_unit_price"] = asking + delta

        # A top-up is priced from the provider's live quote plus the shop's own
        # markup, not from the service product's standing price (which is zero
        # on purpose — a price nobody maintains is a price that goes stale).
        # Applied AFTER the ordinary price resolution above, so what the
        # cashier typed is what the line sells at — the number they were
        # looking at in the cart already included the unit and any modifiers,
        # and quietly re-adding a modifier delta on top would charge more than
        # the screen said.
        override = attrs.pop("unit_price", None)
        if override is not None:
            if not self._may_override_price():
                raise serializers.ValidationError(
                    {
                        "unit_price": (
                            "You do not have permission to change a price at "
                            "the till."
                        )
                    }
                )
            previous = attrs["effective_unit_price"]
            if override != previous:
                attrs["original_unit_price"] = previous
                attrs["effective_unit_price"] = override

        integration = attrs.get("integration")
        # A card off a provider's shelf carries its fulfillment whether or not
        # the till sent one: which card, whose shelf and what it costs are the
        # server's own record of this variant, so nothing a till sends — or
        # leaves out — can change what is bought.
        voucher = voucher_line_payload(variant)
        if voucher is not None:
            integration = voucher
        if integration:
            resolved_integration = resolve_line_integration(integration, variant)
            attrs["integration"] = resolved_integration
            attrs["effective_unit_price"] = resolved_integration["price"]
        return attrs

    def _may_override_price(self):
        """Whether this caller may set a line's price.

        Absent a request — a direct service call, a script — nothing is
        permitted, because there is nobody to hold the right.
        """
        request = self.context.get("request")
        user = getattr(request, "user", None)
        if user is None or not user.is_authenticated:
            return False
        return user.has_perm("sales.override_line_price")

    def _unit_asking_price(self, attrs, resolved):
        """This particular article's own price, when it has one.

        ``line price = unit.list_price ?? variant unit price``. Two handsets of
        the same model were bought at two prices and sell at two prices, and
        that is the ordinary case in a used-goods trade rather than an
        exception. Everything downstream — FX, the discount engine, the loss
        guard, every report — sees a resolved price and needs to know nothing
        about units, which is the point of resolving it here.

        Only for a line sold in the base unit: a serialized article is one
        thing, and a per-carton price for a single handset is a contradiction
        rather than a case to handle.
        """
        units = getattr(self.parent, "preloaded_units", None)
        if not units or resolved.factor != 1:
            return None
        named = [
            units.get(unit_id)
            for unit_id in (attrs.get("stock_units") or [])
        ]
        named = [unit for unit in named if unit is not None]
        if len(named) != 1:
            return None
        return named[0].list_price

    def _validate_and_price_modifiers(self, variant, selections):
        # ``.all()`` + a Python filter (not ``.filter(is_active=True)``, which
        # builds a fresh queryset and ignores the prefetch) so a preloaded cart
        # answers this without a query per line.
        assigned_groups = {
            group.id: group
            for group in variant.product.modifier_groups.all()
            if group.is_active
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
    # Which bank account this tender lands in. Absent from a shop that has not
    # created one, from a till too old to say, and from every cash line — all
    # of which route exactly as they did before the field existed.
    money_account = serializers.PrimaryKeyRelatedField(
        queryset=MoneyAccount.objects.all(),
        required=False,
        allow_null=True,
        write_only=True,
    )

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        from apps.payments.models import Payment

        self.fields["method"].choices = Payment.till_method_choices()


class CheckoutSerializer(serializers.Serializer):
    lines = CheckoutLineSerializer(many=True, allow_empty=False)
    # How this till will deliver the receipt. "local" means it prints the
    # document itself and no queue row should be created for the sale — see
    # apps.sales.services.create_receipt_print_job. Absent from clients too old
    # to say, which fall back to whether an agent is reading the queue.
    receipt_delivery = serializers.ChoiceField(
        choices=RECEIPT_DELIVERY_CHOICES,
        required=False,
        write_only=True,
    )
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
    # The old handset the customer is handing over as part of the payment. A
    # normal purchase-order payload: one supplier (them), one line at the agreed
    # value, and the identifier captured on that line. Absent from every sale
    # that is only a sale.
    trade_in = serializers.JSONField(required=False, write_only=True)
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
    # The haggle: one discount the cashier takes off this invoice, on top of
    # whatever the engine's rules and coupons already did. Bounded by the
    # shop's per-invoice ceiling (ShopSettings.max_invoice_discount_amount) and
    # by the cart itself.
    extra_discount_amount = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        min_value=Decimal("0.00"),
        required=False,
        default=Decimal("0.00"),
    )
    sale_type = serializers.ChoiceField(
        choices=Order.SaleType.choices,
        required=False,
        default=Order.SaleType.STANDARD,
    )
    # Quotation-only: how long the offer stands, and the bound on any stock hold.
    valid_until = serializers.DateField(required=False, allow_null=True)
    # Credit-only (آجل): when the debt is to be settled. Omit the key entirely to
    # take the customer's standing terms; send it as null to leave the tab open
    # with no date. The two are different instructions, which is why this is not
    # defaulted here — ``resolve_credit_due_date`` is told which one arrived.
    due_date = serializers.DateField(required=False, allow_null=True)
    # Quotation-only: hold the quoted quantities until valid_until.
    reserve_stock = serializers.BooleanField(required=False, default=False)

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        from apps.payments.models import Payment

        self.fields["payment_method"].choices = Payment.till_method_choices()
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
        # Judge the ceiling against what the cashier asked for, then clamp to
        # what the cart can carry. That order matters: clamping first would let
        # an over-ceiling discount through whenever the cart happened to be
        # small enough to absorb it, which is the case the ceiling exists for.
        validate_manual_discount_allowed(
            attrs.get("extra_discount_amount"), settings=settings
        )
        extra_discount_amount = clamped_manual_discount(
            attrs["lines"], discount_result, attrs.get("extra_discount_amount")
        )
        attrs["extra_discount_amount"] = extra_discount_amount
        # The amount to tender is the order's total, not the discount engine's:
        # the two round a half-cent line differently, and gating payments on the
        # engine's figure asks for a cent the order then refuses (see
        # expected_order_totals).
        _, _, total = expected_order_totals(
            attrs["lines"], discount_result, extra_discount_amount
        )

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

        # A due date belongs to a debt. Refused rather than ignored on the other
        # sale types: a client sending one has misunderstood which field it
        # wants (``valid_until`` bounds a quotation), and silently dropping it
        # would leave a cashier believing they had set a term.
        if "due_date" in attrs and sale_type != Order.SaleType.CREDIT:
            raise serializers.ValidationError(
                {
                    "due_date": (
                        "Only a credit invoice has a due date. A quotation's "
                        "offer is bounded by valid_until."
                    )
                }
            )
        due_date = attrs.get("due_date")
        if due_date is not None:
            today = business_local_date()
            # An invoice cannot be born overdue. ERPNext refuses the same thing
            # (``validate_due_date``), and here it is nearly always a mis-typed
            # year on the date picker.
            if due_date < today:
                raise serializers.ValidationError(
                    {"due_date": "A due date cannot be before the invoice date."}
                )
            if (due_date - today).days > MAX_CREDIT_DAYS:
                raise serializers.ValidationError(
                    {
                        "due_date": (
                            f"A due date more than {MAX_CREDIT_DAYS} days out is "
                            "almost certainly a typo."
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
        if attrs.get("trade_in"):
            attrs["trade_in"] = self._validated_trade_in(attrs["trade_in"])
        return attrs

    def _validated_trade_in(self, payload):
        """Run the incoming article through the purchasing serializer.

        Not a parallel shape: the same validation any counter purchase takes,
        including the cost guard that blocks an implausible figure outright and
        the unit conversion that keeps a pack cost from being read as a piece
        cost. A trade-in is a purchase, so it is validated as one.
        """
        from apps.purchasing.serializers import PurchaseOrderSerializer

        serializer = PurchaseOrderSerializer(
            data=payload, context={**self.context, "pos_cash_purchase": True}
        )
        try:
            serializer.is_valid(raise_exception=True)
        except serializers.ValidationError as error:
            raise serializers.ValidationError({"trade_in": error.detail}) from None
        return serializer.validated_data

    def create(self, validated_data):
        trade_in = validated_data.get("trade_in")
        sale = lambda: checkout_order(  # noqa: E731 - deferred so a trade-in can wrap it
            register_session=self.context["register_session"],
            lines_data=validated_data["lines"],
            payments_data=validated_data["payments"],
            customer=validated_data.get("customer"),
            coupon_codes=validated_data.get("coupon_codes", ()),
            discount_result=validated_data.get("discount_result"),
            extra_discount_amount=validated_data.get("extra_discount_amount"),
            sale_type=validated_data.get("sale_type", Order.SaleType.STANDARD),
            valid_until=validated_data.get("valid_until"),
            due_date=validated_data.get("due_date"),
            due_date_supplied="due_date" in validated_data,
            reserve_stock=validated_data.get("reserve_stock", False),
            request=self.context.get("request"),
        )
        if not trade_in:
            return sale()
        # The customer handed a handset over as part of the payment. That is a
        # purchase and a sale in one act, and both have to stand or fall
        # together — so the sale runs inside the trade-in's transaction rather
        # than beside it.
        from .trade_in import record_trade_in, refuse_trade_in_above_sale

        refuse_trade_in_above_sale(
            trade_in_total=self._trade_in_total(trade_in),
            sale_total=validated_data["computed_total"],
        )
        _, order = record_trade_in(
            purchase_payload=trade_in,
            checkout=sale,
            request=self.context.get("request"),
        )
        return order

    @staticmethod
    def _trade_in_total(purchase_payload):
        return sum(
            (
                Decimal(str(line["unit_cost"])) * Decimal(str(line["quantity"]))
                for line in purchase_payload.get("lines", [])
            ),
            Decimal("0.00"),
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
    money_account = serializers.PrimaryKeyRelatedField(
        queryset=MoneyAccount.objects.all(),
        required=False,
        allow_null=True,
    )

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        from apps.payments.models import Payment

        self.fields["method"].choices = Payment.till_method_choices()

    def save(self, **kwargs):
        return record_customer_payment(
            self.context["order"],
            method=self.validated_data["method"],
            amount=self.validated_data["amount"],
            card_receipt_url=self.validated_data.get("card_receipt_url", ""),
            money_account=self.validated_data.get("money_account"),
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
    money_account = serializers.PrimaryKeyRelatedField(
        queryset=MoneyAccount.objects.all(),
        required=False,
        allow_null=True,
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
            money_account=self.validated_data.get("money_account"),
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


class OrderDueDateSerializer(serializers.Serializer):
    """Reschedule (or clear) the due date on an outstanding credit invoice.
    Context: ``order``, ``request``.

    ``due_date`` is required-but-nullable rather than optional: clearing the
    date and forgetting to send one are different intentions, and only the first
    should empty the field.
    """

    due_date = serializers.DateField(allow_null=True)

    def validate_due_date(self, value):
        if value is None:
            return value
        today = business_local_date()
        # An extension into the past is not an extension. Unlike checkout, the
        # floor here is today rather than the invoice date: a two-month-old
        # invoice may legitimately be given a due date that has already passed
        # relative to its issue, just not one that is already behind us.
        if value < today:
            raise serializers.ValidationError(
                "A due date cannot be set in the past."
            )
        if (value - today).days > MAX_CREDIT_DAYS:
            raise serializers.ValidationError(
                f"A due date more than {MAX_CREDIT_DAYS} days out is almost "
                "certainly a typo."
            )
        return value

    def save(self, **kwargs):
        return reschedule_credit_invoice_due_date(
            self.context["order"],
            due_date=self.validated_data["due_date"],
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

        self.fields["payment_method"].choices = Payment.till_method_choices()

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


class LineCostRequestSerializer(serializers.Serializer):
    """The variants a till wants the cost of.

    Capped because this is an authenticated endpoint that reads the valuation
    ledger, and a cart is a cart — nobody rings up two hundred distinct
    products at a counter, so a request that claims to is not a cart.
    """

    variants = serializers.ListField(
        child=serializers.IntegerField(min_value=1),
        allow_empty=False,
        max_length=200,
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
    # Previewed on the same terms it is charged on, so the total on the screen
    # is the total the drawer asks for.
    extra_discount_amount = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        min_value=Decimal("0.00"),
        required=False,
        default=Decimal("0.00"),
    )

    def validate(self, attrs):
        coupon_codes = normalized_checkout_coupon_codes(attrs)
        # The same ceiling checkout enforces, refused at the same moment the
        # cashier types it rather than held back until they try to take money.
        validate_manual_discount_allowed(attrs.get("extra_discount_amount"))
        # Preview runs on every cart edit -> use the Redis-guarded path. Checkout
        # (above) stays on the live calculate_sales_discounts.
        discount_result = preview_sales_discounts(
            lines_data=attrs["lines"],
            customer=attrs.get("customer"),
            coupon_codes=coupon_codes,
        )
        attrs["coupon_codes"] = coupon_codes
        attrs["discount_result"] = discount_result
        attrs["extra_discount_amount"] = clamped_manual_discount(
            attrs["lines"], discount_result, attrs.get("extra_discount_amount")
        )
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
        extra_discount_amount = self.validated_data.get(
            "extra_discount_amount"
        ) or Decimal("0.00")
        subtotal, discount_total, total = expected_order_totals(
            self.validated_data["lines"], discount_result, extra_discount_amount
        )
        return {
            "subtotal": f"{subtotal:.2f}",
            "discount_total": f"{discount_total:.2f}",
            "total": f"{total:.2f}",
            # What the cart can still carry, and what of the typed amount
            # actually landed. The till reads these back: a cashier who typed 50
            # on a cart that then lost a line sees the discount shrink to what
            # the sale can bear instead of watching checkout refuse it.
            "extra_discount_amount": f"{extra_discount_amount:.2f}",
            "max_extra_discount_amount": (
                f"{manual_discount_room(self.validated_data['lines'], discount_result):.2f}"
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
                extra_discount_amount=extra_discount_amount,
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
    # Only consulted when a returned article is a consignment whose owner has
    # already been paid, and then it is the whole question: does the shop keep
    # the watch it paid ten thousand for, or does it go back on the shelf as the
    # consignor's with a receivable against them? Both are defensible; the
    # default is the one where the shop owns what it paid for (§5.8).
    consignment_action = serializers.ChoiceField(
        choices=CONSIGNMENT_ACTIONS, required=False, default=BUY_IN
    )

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
            consignment_action=self.validated_data.get("consignment_action", BUY_IN),
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

        self.fields["settlement_method"].choices = Payment.till_method_choices()
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


class RegisterProfileSerializer(serializers.ModelSerializer):
    """What one till is set up to do."""

    warehouse_name = serializers.CharField(source="warehouse.name", read_only=True)
    warehouse_kind = serializers.CharField(source="warehouse.kind", read_only=True)

    class Meta:
        model = RegisterProfile
        fields = [
            "id",
            "device_id",
            "name",
            "warehouse",
            "warehouse_name",
            "warehouse_kind",
            "last_seen_at",
            "created_at",
            "updated_at",
        ]
        read_only_fields = ("device_id", "last_seen_at", "created_at", "updated_at")

    def validate_warehouse(self, value):
        """A till cannot be pointed at the road, or at a place that is shut."""
        from apps.inventory.models import Warehouse

        if value.kind == Warehouse.Kind.TRANSIT:
            raise serializers.ValidationError(
                "لا يمكن للصندوق أن يبيع من المخزن العابر."
            )
        if not value.is_active:
            raise serializers.ValidationError("هذا المخزن غير مفعّل.")
        return value
