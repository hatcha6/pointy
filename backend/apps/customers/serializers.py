from django.utils import timezone
from rest_framework import serializers

from apps.sales.models import OrderAdjustment, OrderAdjustmentLine
from .models import Customer, PaymentCard


class CustomerSerializer(serializers.ModelSerializer):
    card_count = serializers.SerializerMethodField()
    # Human label for the rank (e.g. "Champion"); the slug rides in ``rfm_segment``.
    rfm_segment_display = serializers.CharField(
        source="get_rfm_segment_display",
        read_only=True,
    )
    # Contact-consent state (read-only; changed via the CRM consent endpoint so
    # every change is recorded as a ConsentEvent).
    marketing_opted_out = serializers.SerializerMethodField()
    # The ceiling that actually applies once the policy and the shop default
    # have been resolved. Null means no limit. Read-only: it is an answer, not
    # a setting — the two columns below are what an owner edits.
    effective_credit_limit = serializers.SerializerMethodField()
    # The terms that actually apply once the policy and the shop default have
    # been resolved, *including the date they produce for an invoice issued
    # today*. The date is computed here rather than in the client for the same
    # reason every other money figure is: month ends and leap years are exactly
    # the arithmetic two implementations drift on, and the till must propose the
    # date the reports will later age against.
    effective_payment_terms = serializers.SerializerMethodField()
    # Set when this is an employee's own account: what they buy on آجل is
    # deducted from their next payroll run. Null for every ordinary customer.
    staff_employee = serializers.SerializerMethodField()

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
            "marketing_opted_out",
            "do_not_contact",
            "notes",
            "is_active",
            "is_auto_created",
            "card_count",
            "staff_employee",
            # Credit (آجل) ceiling.
            "credit_limit_policy",
            "credit_limit",
            "effective_credit_limit",
            # Credit (آجل) terms.
            "payment_terms_policy",
            "payment_terms_days",
            "payment_terms_basis",
            "effective_payment_terms",
            # RFM segmentation (read-only; set by the nightly task).
            "rfm_segment",
            "rfm_segment_display",
            "rfm_score",
            "rfm_recency_score",
            "rfm_frequency_score",
            "rfm_monetary_score",
            "rfm_recency_days",
            "rfm_frequency",
            "rfm_monetary",
            "rfm_last_purchase_at",
            "rfm_calculated_at",
            "created_at",
            "updated_at",
        ]
        read_only_fields = (
            "id",
            "customer_number",
            "marketing_opted_out",
            "do_not_contact",
            "staff_employee",
            "effective_credit_limit",
            "effective_payment_terms",
            "rfm_segment",
            "rfm_segment_display",
            "rfm_score",
            "rfm_recency_score",
            "rfm_frequency_score",
            "rfm_monetary_score",
            "rfm_recency_days",
            "rfm_frequency",
            "rfm_monetary",
            "rfm_last_purchase_at",
            "rfm_calculated_at",
            "created_at",
            "updated_at",
        )

    def get_marketing_opted_out(self, obj) -> bool:
        return bool(obj.marketing_opted_out_at)

    def get_staff_employee(self, obj) -> int | None:
        # A reverse one-to-one raises when there is no row; ``getattr`` reads
        # that as "not a staff account". The viewset joins it, so a page of
        # customers costs no query per row.
        employee = getattr(obj, "staff_employee", None)
        return employee.pk if employee is not None else None

    def get_effective_credit_limit(self, obj) -> str | None:
        from apps.customers.receivables import effective_credit_limit

        limit = effective_credit_limit(obj)
        return None if limit is None else f"{limit:.2f}"

    def get_effective_payment_terms(self, obj) -> dict:
        from apps.core.timeutils import business_local_date
        from apps.customers.payment_terms import resolve_payment_terms

        terms = resolve_payment_terms(obj)
        return {
            "days": terms.days,
            "basis": terms.basis,
            "source": terms.source,
            "is_immediate": terms.is_immediate,
            "due_date_for_today": terms.due_date_for(business_local_date()).isoformat(),
        }

    def validate(self, attrs):
        # Mirrors ``Customer.clean``. The model would catch it anyway (``save``
        # calls ``full_clean``), but a DRF-shaped field error is what the form
        # can point at, where a model ValidationError surfaces as a 500-ish blob.
        policy = attrs.get(
            "credit_limit_policy",
            getattr(self.instance, "credit_limit_policy", None),
        )
        limit = attrs.get("credit_limit", getattr(self.instance, "credit_limit", None))
        if policy == Customer.CreditLimitPolicy.CUSTOM and limit is None:
            raise serializers.ValidationError(
                {"credit_limit": "A custom credit limit needs an amount."}
            )
        terms_policy = attrs.get(
            "payment_terms_policy",
            getattr(self.instance, "payment_terms_policy", None),
        )
        days = attrs.get(
            "payment_terms_days", getattr(self.instance, "payment_terms_days", None)
        )
        if terms_policy == Customer.PaymentTermsPolicy.CUSTOM and days is None:
            raise serializers.ValidationError(
                {"payment_terms_days": "Custom payment terms need a number of days."}
            )
        return attrs

    def get_card_count(self, obj):
        # Uses the list queryset's annotation when present, falling back to a
        # query for single-object responses (create/update/retrieve).
        count = getattr(obj, "card_count", None)
        return count if count is not None else obj.cards.count()

    def validate_birthday(self, value):
        if value and value > timezone.localdate():
            raise serializers.ValidationError("Birthday cannot be in the future.")
        return value


class PaymentCardSerializer(serializers.ModelSerializer):
    display_name = serializers.CharField(read_only=True)
    customer_name = serializers.CharField(source="customer.full_name", read_only=True)

    class Meta:
        model = PaymentCard
        fields = [
            "id",
            "customer",
            "customer_name",
            "fingerprint",
            "masked_pan",
            "card_scheme",
            "aid",
            "label",
            "display_name",
            "is_active",
            "first_seen_at",
            "last_seen_at",
            "last_receipt_data",
            "created_at",
            "updated_at",
        ]
        # Identity fields come from the terminal receipt and are immutable; the
        # owning customer is changed only through the explicit reassign action.
        read_only_fields = (
            "id",
            "customer",
            "fingerprint",
            "masked_pan",
            "card_scheme",
            "aid",
            "first_seen_at",
            "last_seen_at",
            "last_receipt_data",
            "created_at",
            "updated_at",
        )


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
