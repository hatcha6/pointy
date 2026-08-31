"""API shapes for currencies, rates, and repricing.

Two things every rate payload carries beyond the number itself, because the UI
is expected to show them rather than hide them:

* **where the rate came from** — the feed, or a number the owner typed;
* **whether it is the series they asked for**, so a shop configured for its
  bank's rate that is being served the cash rate is told, not quietly costed
  off the wrong instrument.
"""

from __future__ import annotations

from rest_framework import serializers

from apps.core.models import ShopSettings

from . import currencies as ref
from .models import Currency, ExchangeRate


class CurrencySerializer(serializers.ModelSerializer):
    class Meta:
        model = Currency
        fields = (
            "code",
            "name_en",
            "name_ar",
            "symbol_en",
            "symbol_ar",
            "decimals",
            "display_order",
            "is_enabled",
        )
        read_only_fields = ("decimals",)


class ExchangeRateSerializer(serializers.ModelSerializer):
    from_code = serializers.CharField(source="from_currency_id", read_only=True)
    to_code = serializers.CharField(source="to_currency_id", read_only=True)

    class Meta:
        model = ExchangeRate
        fields = (
            "id",
            "from_code",
            "to_code",
            "instrument",
            "bank_code",
            "effective_at",
            "rate",
            "source",
            "note",
            "created_at",
        )
        read_only_fields = fields


class ManualRateSerializer(serializers.Serializer):
    """A rate the owner is typing in."""

    from_code = serializers.CharField(max_length=8)
    to_code = serializers.CharField(max_length=8, required=False)
    rate = serializers.DecimalField(max_digits=18, decimal_places=8, min_value=0)
    instrument = serializers.ChoiceField(
        choices=ref.INSTRUMENTS, default=ref.INSTRUMENT_CASH
    )
    bank_code = serializers.CharField(max_length=32, required=False, allow_blank=True)
    effective_at = serializers.DateTimeField(required=False)
    note = serializers.CharField(max_length=240, required=False, allow_blank=True)

    def validate_rate(self, value):
        if value <= 0:
            raise serializers.ValidationError(
                "سعر الصرف يجب أن يكون أكبر من صفر."
            )
        return value

    def validate(self, attrs):
        attrs.setdefault("to_code", ShopSettings.load().currency_code)
        source = str(attrs["from_code"]).strip().upper()
        target = str(attrs["to_code"]).strip().upper()
        if source == target:
            raise serializers.ValidationError(
                {"from_code": "لا يمكن تحويل العملة إلى نفسها."}
            )
        for code, field in ((source, "from_code"), (target, "to_code")):
            if not Currency.objects.filter(pk=code).exists():
                raise serializers.ValidationError({field: f"عملة غير معروفة: {code}"})
        attrs["from_code"] = source
        attrs["to_code"] = target
        return attrs


class ResolvedRateSerializer(serializers.Serializer):
    """A resolved rate plus its provenance, as the apps consume it."""

    from_code = serializers.CharField()
    to_code = serializers.CharField()
    rate = serializers.DecimalField(max_digits=18, decimal_places=8)
    effective_at = serializers.DateTimeField()
    source = serializers.CharField()
    instrument = serializers.CharField()
    bank_code = serializers.CharField()
    requested_instrument = serializers.CharField()
    requested_bank_code = serializers.CharField()
    inverted = serializers.BooleanField()
    is_identity = serializers.BooleanField()
    is_substituted = serializers.BooleanField()
    is_stale = serializers.SerializerMethodField()
    age_hours = serializers.SerializerMethodField()

    def get_is_stale(self, obj) -> bool:
        return obj.is_stale(self.context.get("staleness_hours", 24))

    def get_age_hours(self, obj) -> float:
        return round(obj.age().total_seconds() / 3600, 2)


class PriceProposalSerializer(serializers.Serializer):
    """One row's foreign price restated at a new rate."""

    kind = serializers.CharField()
    target_id = serializers.IntegerField()
    product_id = serializers.IntegerField()
    label = serializers.CharField()
    currency_code = serializers.CharField()
    price_amount = serializers.DecimalField(max_digits=10, decimal_places=2)
    current_base_price = serializers.DecimalField(max_digits=10, decimal_places=2)
    proposed_base_price = serializers.DecimalField(
        max_digits=10, decimal_places=2, allow_null=True
    )
    old_rate = serializers.DecimalField(
        max_digits=18, decimal_places=8, allow_null=True
    )
    new_rate = serializers.DecimalField(
        max_digits=18, decimal_places=8, allow_null=True
    )
    rate_effective_at = serializers.DateTimeField(allow_null=True)
    unpriceable = serializers.BooleanField()
    changed = serializers.BooleanField()
    delta = serializers.DecimalField(max_digits=12, decimal_places=2)
    delta_percent = serializers.DecimalField(max_digits=8, decimal_places=2)


class ApplyRepriceSerializer(serializers.Serializer):
    """Which proposals the owner approved.

    Identified by ``kind`` and ``target_id`` rather than re-sent wholesale: the
    server re-derives the proposal so a client cannot post an arbitrary price,
    but it re-derives it *at the rate the client was shown*, so the confirmation
    dialog stays honest.
    """

    targets = serializers.ListField(
        child=serializers.DictField(), allow_empty=False, max_length=5000
    )
    # The instant the preview resolved at, echoed back by the client.
    resolved_at = serializers.DateTimeField(required=False)
