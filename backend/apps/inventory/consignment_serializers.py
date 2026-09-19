"""The consignment API's shapes.

Two documents and one derived position. Nothing here stores a payable: every
money figure on the way out is computed by ``apps.inventory.consignment`` at
read time, which is what makes it impossible for a screen to show a number the
ledger disagrees with.
"""

from __future__ import annotations

from decimal import Decimal

from rest_framework import serializers

from . import consignment as figures
from .models import (
    ConsignmentAgreement,
    ConsignmentIncident,
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
    """سند صرف أمانة — and, with it, what the money was for.

    The articles are on the row rather than left to a second call, because this
    is a document the consignor signs at the counter: a voucher that says
    "10,000 د.ل" and does not say which watch is a receipt for nothing.
    """

    consignor_name = serializers.CharField(source="consignor.full_name", read_only=True)
    consignor_phone = serializers.CharField(source="consignor.phone", read_only=True)
    lines = serializers.SerializerMethodField()

    class Meta:
        model = ConsignorPayout
        fields = (
            "id",
            "number",
            "consignor",
            "consignor_name",
            "consignor_phone",
            "amount",
            "method",
            "paid_at",
            "reference",
            "notes",
            "register_session",
            "doc_status",
            "lines",
            "created_at",
        )
        read_only_fields = fields

    def get_lines(self, payout):
        # ``.all()`` and not ``.select_related(...)``: a related manager only
        # uses the view's prefetch when the queryset is untouched, so refining
        # it here would quietly re-query per voucher and put the list straight
        # back on an N+1. The joins live on the prefetch instead.
        #
        # ``offset`` is read off the settlement events this voucher wrote, not
        # off the unit: the advance was *consumed* when it paid, so by the
        # time anybody reads the voucher the column says zero. Without it a
        # voucher for 1,600 lists a line claiming a payout of 9,600 and no
        # explanation of the difference, which is a document that does not
        # foot.
        offsets = self._offsets(payout)
        return [
            {
                "unit": unit.pk,
                "code": unit.code,
                "product_name": unit.variant.full_name if unit.variant_id else "",
                "sold_at": unit.sold_at,
                "sold_price": unit.sold_price,
                "payout_due": figures.consignor_payout_due(unit),
                "advance_offset": offsets.get(unit.pk, Decimal("0.00")),
                "paid_here": max(
                    figures.consignor_payout_due(unit)
                    - offsets.get(unit.pk, Decimal("0.00")),
                    Decimal("0.00"),
                ),
            }
            for unit in payout.units.all()
        ]

    def _offsets(self, payout):
        """How much of each line each voucher settled against an advance.

        **One query for the whole page**, not one per voucher. The obvious
        shape — filter the events by this payout's id — is an N+1 on a list
        whose guard test exists precisely because this list had one before
        (`lifecycle-query-scaling`). So the first row resolves the whole page
        and caches it; a detail read resolves exactly its own.
        """
        cache = self.context.setdefault("_advance_offsets", {})
        if payout.pk in cache:
            return cache[payout.pk]

        from .models import StockUnitEvent

        page = getattr(getattr(self, "parent", None), "instance", None)
        payouts = list(page) if isinstance(page, (list, tuple)) else None
        if payouts is None and hasattr(page, "__iter__"):
            payouts = list(page)
        ids = [row.pk for row in payouts] if payouts else [payout.pk]

        rows = StockUnitEvent.objects.filter(
            reference_type="consignor_payout",
            reference_id__in=ids,
            kind="advance_settled",
        ).values_list("reference_id", "unit_id", "from_value")
        for payout_id in ids:
            cache.setdefault(payout_id, {})
        for payout_id, unit_id, amount in rows:
            try:
                value = Decimal(amount or "0")
            except ArithmeticError:
                continue
            per_payout = cache.setdefault(payout_id, {})
            per_payout[unit_id] = per_payout.get(unit_id, Decimal("0.00")) + value
        return cache.get(payout.pk, {})


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
    #: What the counter actually hands over, and why it differs from the
    #: payout when it does. Both are sent: a row that showed only the net
    #: would read as though the watch had earned 1,600.
    advance = serializers.DecimalField(
        source="consignor_advance", max_digits=10, decimal_places=2,
        read_only=True,
    )
    net_due = serializers.SerializerMethodField()
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
            "advance",
            "net_due",
            "invoice_number",
            "invoice_balance_due",
            "sold_on_credit",
            "days_waiting",
        )
        read_only_fields = fields

    def get_payout_due(self, unit):
        return figures.consignor_payout_due(unit)

    def get_net_due(self, unit):
        """Payout less any advance on this same article, floored at zero.

        Negative would mean the consignor owes the shop, which is a
        *receivable* and never a negative payable — see §5.8 and
        ``consignment.net_due``.
        """
        return max(figures.net_due(unit), Decimal("0.00"))

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


def _cameras():
    """The camera queryset, without importing ``apps.surveillance`` up front.

    The registry knows the model by name, which is enough for a related field
    and avoids an import that runs the other way round.
    """
    from django.apps import apps as django_apps

    return django_apps.get_model("surveillance", "Camera").objects.all()


class ConsignmentIncidentSerializer(serializers.ModelSerializer):
    """§6.2.2's record, as a screen reads it.

    ``suggested_value`` and ``liability_cap`` are sent beside the assessment
    rather than instead of it: the matrix is a default the shop can argue away
    from, and showing both is what makes the argument visible.
    """

    unit_code = serializers.CharField(source="unit.code", read_only=True)
    product_name = serializers.CharField(
        source="unit.variant.full_name", read_only=True
    )
    consignor = serializers.IntegerField(source="unit.consignor_id", read_only=True)
    consignor_name = serializers.CharField(
        source="unit.consignor.full_name", read_only=True
    )
    consignor_phone = serializers.CharField(
        source="unit.consignor.phone", read_only=True
    )
    agreement_number = serializers.CharField(
        source="agreement.number", read_only=True
    )
    liability_policy = serializers.CharField(
        source="agreement.liability_policy", read_only=True
    )
    reported_by_name = serializers.CharField(
        source="reported_by.username", read_only=True
    )
    declared_value = serializers.DecimalField(
        source="unit.declared_value",
        max_digits=10,
        decimal_places=2,
        read_only=True,
    )
    liability_cap = serializers.SerializerMethodField()
    suggested_value = serializers.SerializerMethodField()
    is_open = serializers.BooleanField(read_only=True)
    days_open = serializers.SerializerMethodField()

    class Meta:
        model = ConsignmentIncident
        fields = (
            "id",
            "number",
            "unit",
            "unit_code",
            "product_name",
            "consignor",
            "consignor_name",
            "consignor_phone",
            "agreement",
            "agreement_number",
            "liability_policy",
            "liability_cap",
            "declared_value",
            "kind",
            "occurred_on",
            "discovered_at",
            "reported_by",
            "reported_by_name",
            "narrative",
            "responsibility",
            "assessed_value",
            "is_assessed",
            "suggested_value",
            "resolution",
            "resolved_at",
            "settlement_ref",
            "settlement_payout",
            "replacement_unit",
            "camera",
            "is_open",
            "days_open",
            "doc_status",
            "created_at",
            "updated_at",
        )
        read_only_fields = fields

    def get_liability_cap(self, incident):
        from .custody import liability_bound

        return liability_bound(incident.unit, incident.agreement)

    def get_suggested_value(self, incident):
        from .custody import default_assessment

        value, _assessed = default_assessment(
            incident.unit,
            responsibility=incident.responsibility,
            agreement=incident.agreement,
        )
        return value

    def get_days_open(self, incident):
        from django.utils import timezone

        end = incident.resolved_at or timezone.now()
        return (end - incident.discovered_at).days


class ReportIncidentSerializer(serializers.Serializer):
    kind = serializers.ChoiceField(choices=ConsignmentIncident.Kind.choices)
    narrative = serializers.CharField()
    occurred_on = serializers.DateField(required=False, allow_null=True)
    discovered_at = serializers.DateTimeField(required=False, allow_null=True)
    responsibility = serializers.ChoiceField(
        choices=ConsignmentIncident.Responsibility.choices, required=False
    )
    #: The camera that was pointing at it, so the timeline can reach the
    #: footage of the moment (§8.3). Resolved lazily: ``apps.surveillance``
    #: imports this app, and a queryset evaluated at class-definition time
    #: would close the circle.
    camera = serializers.PrimaryKeyRelatedField(
        queryset=_cameras(), required=False, allow_null=True
    )


class AssessIncidentSerializer(serializers.Serializer):
    responsibility = serializers.ChoiceField(
        choices=ConsignmentIncident.Responsibility.choices
    )
    #: Left out to take the matrix's own answer, which is the ordinary case.
    assessed_value = serializers.DecimalField(
        max_digits=10, decimal_places=2, required=False, allow_null=True
    )
    note = serializers.CharField(required=False, allow_blank=True)


class SettleIncidentSerializer(serializers.Serializer):
    resolution = serializers.ChoiceField(
        choices=[
            choice
            for choice in ConsignmentIncident.Resolution.choices
            if choice[0] != ConsignmentIncident.Resolution.PENDING
        ]
    )
    method = serializers.ChoiceField(
        choices=ConsignorPayout.Method.choices,
        default=ConsignorPayout.Method.CASH,
    )
    replacement_unit = serializers.PrimaryKeyRelatedField(
        queryset=StockUnit.objects.all(), required=False, allow_null=True
    )
    reference = serializers.CharField(required=False, allow_blank=True)
    notes = serializers.CharField(required=False, allow_blank=True)


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
