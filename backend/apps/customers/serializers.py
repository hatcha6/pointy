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
            "notes",
            "is_active",
            "is_auto_created",
            "card_count",
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
