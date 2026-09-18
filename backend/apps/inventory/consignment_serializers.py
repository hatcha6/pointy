"""The consignment API's shapes.

Two documents and one derived position. Nothing here stores a payable: every
money figure on the way out is computed by ``apps.inventory.consignment`` at
read time, which is what makes it impossible for a screen to show a number the
ledger disagrees with.
"""

from __future__ import annotations

from rest_framework import serializers

from . import consignment as figures
from .models import (
    ConsignmentAgreement,
    ConsignorPayout,
    StockUnit,
    UnitAttributeDefinition,
)
from .tracked_serializers import StockUnitSerializer


class ConsignmentItemSerializer(serializers.Serializer):
    """One article being taken in, as the intake sheet sends it."""

    variant = serializers.IntegerField(min_value=1)
    code = serializers.CharField(max_length=120, trim_whitespace=True)
    secondary_code = serializers.CharField(
        max_length=120, required=False, allow_blank=True, default=""
    )
    identifier_kind = serializers.CharField(
        max_length=16, required=False, allow_blank=True, default=""
    )
    declared_value = serializers.DecimalField(
        max_digits=10, decimal_places=2, required=False, allow_null=True
    )
    list_price = serializers.DecimalField(
        max_digits=10, decimal_places=2, required=False, allow_null=True
    )
    # Per-unit overrides of the agreement's terms. ``None`` inherits, which is
    # the ordinary case and the reason these are not required.
    consignor_payout_mode = serializers.ChoiceField(
        choices=ConsignmentAgreement.PayoutMode.choices,
        required=False,
        allow_blank=True,
        default="",
    )
    consignor_payout_rate = serializers.DecimalField(
        max_digits=10, decimal_places=2, required=False, allow_null=True
    )
    consignor_commission_pct = serializers.DecimalField(
        max_digits=5, decimal_places=2, required=False, allow_null=True
    )
    consignor_reserve_price = serializers.DecimalField(
        max_digits=10, decimal_places=2, required=False, allow_null=True
    )
    attributes = serializers.JSONField(required=False, default=dict)
    notes = serializers.CharField(required=False, allow_blank=True, default="")

    def validate(self, attrs):
        from apps.catalog.models import ProductVariant

        try:
            attrs["variant"] = ProductVariant.objects.select_related("product").get(
                pk=attrs["variant"]
            )
        except ProductVariant.DoesNotExist:
            raise serializers.ValidationError(
                {"variant": "الصنف غير موجود."}
            ) from None
        return attrs


class ConsignmentIntakeSerializer(serializers.Serializer):
    """The goods a signature is about to cover.

    Its own serializer rather than a partial of the agreement's: the terms were
    agreed and saved when the draft was written, and re-validating them on the
    submit would refuse it for a ``payout_rate`` that is already on the row.
    """

    items = ConsignmentItemSerializer(many=True, required=False, default=list)


class ConsignmentAgreementSerializer(serializers.ModelSerializer):
    consignor_name = serializers.CharField(
        source="consignor.full_name", read_only=True
    )
    consignor_phone = serializers.CharField(source="consignor.phone", read_only=True)
    # Write-only, because intake is a document *and* a stock movement and the
    # two have to be one act: a voucher that exists without its goods is a
    # promise about nothing.
    items = ConsignmentItemSerializer(many=True, write_only=True, required=False)
    unit_count = serializers.SerializerMethodField()
    units = serializers.SerializerMethodField()

    class Meta:
        model = ConsignmentAgreement
        fields = (
            "id",
            "number",
            "consignor",
            "consignor_name",
            "consignor_phone",
            "signed_at",
            "expires_on",
            "notes",
            "payout_mode",
            "payout_rate",
            "commission_pct",
            "reserve_price",
            "liability_policy",
            "liability_cap",
            "liability_clause",
            "doc_status",
            "submitted_at",
            "cancelled_at",
            "items",
            "unit_count",
            "units",
            "created_at",
            "updated_at",
        )
        read_only_fields = (
            "id",
            "number",
            # Copied from the shop's editable sentence at submit and never
            # re-read: the printed words are the contract.
            "liability_clause",
            "doc_status",
            "submitted_at",
            "cancelled_at",
            "created_at",
            "updated_at",
        )

    def get_unit_count(self, agreement):
        return agreement.units.count()

    def get_units(self, agreement):
        if self.context.get("with_units") is False:
            return []
        return StockUnitSerializer(
            agreement.units.select_related(
                "variant", "variant__product", "warehouse", "batch"
            ),
            many=True,
            context=self.context,
        ).data

    def validate(self, attrs):
        mode = attrs.get("payout_mode") or getattr(
            self.instance, "payout_mode", ConsignmentAgreement.PayoutMode.FIXED
        )
        rate = attrs.get("payout_rate", getattr(self.instance, "payout_rate", None))
        pct = attrs.get(
            "commission_pct", getattr(self.instance, "commission_pct", None)
        )
        if mode == ConsignmentAgreement.PayoutMode.FIXED and rate is None:
            # Not a nicety: the fixed-payout floor is computed from this, and a
            # null one would silently disable the guard that stops the shop
            # selling somebody's watch for less than it owes them.
            raise serializers.ValidationError(
                {"payout_rate": "المبلغ المتفق عليه مطلوب في الدفع الثابت."}
            )
        if mode == ConsignmentAgreement.PayoutMode.COMMISSION and pct is None:
            raise serializers.ValidationError(
                {"commission_pct": "نسبة العمولة مطلوبة."}
            )
        return attrs


class ConsignorPayoutSerializer(serializers.ModelSerializer):
    consignor_name = serializers.CharField(source="consignor.full_name", read_only=True)

    class Meta:
        model = ConsignorPayout
        fields = (
            "id",
            "number",
            "consignor",
            "consignor_name",
            "amount",
            "method",
            "paid_at",
            "reference",
            "notes",
            "register_session",
            "doc_status",
            "created_at",
        )
        read_only_fields = fields


class DisbursePayoutSerializer(serializers.Serializer):
    units = serializers.ListField(
        child=serializers.IntegerField(min_value=1), allow_empty=False
    )
    method = serializers.ChoiceField(
        choices=ConsignorPayout.Method.choices,
        default=ConsignorPayout.Method.CASH,
    )
    reference = serializers.CharField(
        max_length=120, required=False, allow_blank=True, default=""
    )
    notes = serializers.CharField(required=False, allow_blank=True, default="")


class ConsignmentPayableSerializer(serializers.ModelSerializer):
    """One line of *«مستحقات الأمانات»*: what is owed, to whom, for what.

    Carries the invoice's own balance alongside the payout. A consignment sold
    on آجل owes the consignor cash before the shop has collected any, and the
    person disbursing should be told that in the row rather than discover it
    when the drawer is short.
    """

    consignor_name = serializers.CharField(source="consignor.full_name", read_only=True)
    consignor_phone = serializers.CharField(source="consignor.phone", read_only=True)
    product_name = serializers.CharField(source="variant.full_name", read_only=True)
    payout_due = serializers.SerializerMethodField()
    invoice_number = serializers.SerializerMethodField()
    invoice_balance_due = serializers.SerializerMethodField()
    sold_on_credit = serializers.SerializerMethodField()
    days_waiting = serializers.SerializerMethodField()

    class Meta:
        model = StockUnit
        fields = (
            "id",
            "code",
            "product_name",
            "consignor",
            "consignor_name",
            "consignor_phone",
            "agreement",
            "sold_at",
            "sold_price",
            "payout_due",
            "invoice_number",
            "invoice_balance_due",
            "sold_on_credit",
            "days_waiting",
        )
        read_only_fields = fields

    def get_payout_due(self, unit):
        return figures.consignor_payout_due(unit)

    def _order(self, unit):
        line = unit.sold_order_line
        return getattr(line, "order", None) if line is not None else None

    def get_invoice_number(self, unit):
        order = self._order(unit)
        return getattr(order, "receipt_number", "") if order is not None else ""

    def get_invoice_balance_due(self, unit):
        order = self._order(unit)
        return getattr(order, "balance_due", None) if order is not None else None

    def get_sold_on_credit(self, unit):
        from apps.sales.models import Order

        order = self._order(unit)
        return order is not None and order.sale_type == Order.SaleType.CREDIT

    def get_days_waiting(self, unit):
        """How long this money has been sitting here uncollected.

        The consignor who never came back is the other half of this screen, and
        an ageing that is only visible in a report is one nobody acts on.
        """
        from django.utils import timezone

        if unit.sold_at is None:
            return None
        return (timezone.now() - unit.sold_at).days


class UnitAttributeDefinitionSerializer(serializers.ModelSerializer):
    """One typed fact a kind of article records — the attribute editor's row."""

    class Meta:
        model = UnitAttributeDefinition
        fields = (
            "id",
            "asset_type",
            "key",
            "label",
            "data_type",
            "choices",
            "suffix",
            "is_required",
            "show_in_picker",
            "show_on_label",
            "show_on_receipt",
            "is_filterable",
            "display_order",
        )
