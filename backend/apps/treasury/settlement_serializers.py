"""API shapes for held card takings and the settlements that pay them out.

Money is sent as strings, like every other figure in this API.
"""

from decimal import Decimal

from rest_framework import serializers

from apps.documents.serializers import DocumentLifecycleFields

from .models import CardSettlement, MoneyAccount
from .settlements import SettlementError, record_settlement

MONEY_PLACES = Decimal("0.01")


def _money(value) -> str:
    return str(Decimal(value or 0).quantize(MONEY_PLACES))


class CardSettlementSerializer(DocumentLifecycleFields, serializers.ModelSerializer):
    clearing_account_name = serializers.CharField(
        source="clearing_account.name", read_only=True
    )
    bank_account_name = serializers.CharField(source="bank_account.name", read_only=True)
    bank_account_bank_slug = serializers.CharField(
        source="bank_account.bank_slug", read_only=True
    )
    created_by_name = serializers.CharField(
        source="created_by.get_full_name", read_only=True, default=""
    )

    class Meta:
        model = CardSettlement
        fields = (
            "id",
            "clearing_account",
            "clearing_account_name",
            "bank_account",
            "bank_account_name",
            "bank_account_bank_slug",
            "settled_on",
            "amount_received",
            "expected_amount",
            "gross_amount",
            "commission_amount",
            "difference",
            "payment_count",
            "first_day",
            "last_day",
            "reference",
            "note",
            "created_by_name",
            "created_at",
            *DocumentLifecycleFields.LIFECYCLE_FIELDS,
        )
        read_only_fields = fields


class RecordCardSettlementSerializer(serializers.Serializer):
    """What the owner confirms: the deposit, and what it paid for.

    ``days`` is the usual answer — whole processor days. ``exclude_payment_ids``
    leaves out a sale the processor did not include (a held or disputed one);
    ``payment_ids`` names the payments outright instead. ``expected_amount`` is
    the held total the owner saw: if the held takings changed since, the
    settlement is refused rather than stored against a different figure.
    """

    clearing_account = serializers.PrimaryKeyRelatedField(
        queryset=MoneyAccount.objects.filter(kind=MoneyAccount.Kind.CLEARING)
    )
    settled_on = serializers.DateField()
    amount_received = serializers.DecimalField(max_digits=12, decimal_places=2)
    days = serializers.ListField(child=serializers.DateField(), required=False)
    payment_ids = serializers.ListField(
        child=serializers.IntegerField(min_value=1), required=False
    )
    exclude_payment_ids = serializers.ListField(
        child=serializers.IntegerField(min_value=1), required=False
    )
    expected_amount = serializers.DecimalField(
        max_digits=12, decimal_places=2, required=False, allow_null=True
    )
    reference = serializers.CharField(
        max_length=128, required=False, allow_blank=True, default=""
    )
    note = serializers.CharField(required=False, allow_blank=True, default="")

    def validate(self, attrs):
        if not attrs.get("days") and not attrs.get("payment_ids"):
            raise serializers.ValidationError(
                {"days": "اختر يومًا واحدًا على الأقل من المبالغ قيد التسوية."}
            )
        return attrs

    def create(self, validated_data):
        request = self.context.get("request")
        try:
            return record_settlement(
                clearing_account=validated_data["clearing_account"],
                settled_on=validated_data["settled_on"],
                amount_received=validated_data["amount_received"],
                days=validated_data.get("days"),
                payment_ids=validated_data.get("payment_ids"),
                exclude_payment_ids=validated_data.get("exclude_payment_ids"),
                expected_amount=validated_data.get("expected_amount"),
                reference=validated_data.get("reference", ""),
                note=validated_data.get("note", ""),
                actor=getattr(request, "user", None),
            )
        except SettlementError as exc:
            raise serializers.ValidationError(
                {"detail": str(exc), "code": exc.code}
            ) from exc


def held_day_payload(day, *, today):
    """One held processor day, as the settlement screen draws it."""
    return {
        "day": day.day.isoformat(),
        "expected_on": day.expected_on.isoformat(),
        "overdue": day.expected_on < today,
        "gross": _money(day.gross),
        "commission": _money(day.commission),
        "net": _money(day.net),
        "count": day.count,
    }


def suggestion_payload(suggestion):
    return {
        "days": [day.isoformat() for day in suggestion.days],
        "match": suggestion.match,
        "expected": _money(suggestion.expected),
        "difference": (
            None if suggestion.difference is None else _money(suggestion.difference)
        ),
    }


def held_payment_payload(row):
    return {
        "id": row["id"],
        "order_id": row["order_id"],
        "invoice_number": row["invoice_number"],
        "paid_at": row["paid_at"].isoformat(),
        "amount": _money(row["amount"]),
        "commission": _money(row["commission"]),
        "net": _money(row["net"]),
        "reverses_id": row["reverses_id"],
        "terminal_id": row["terminal_id"],
        "masked_pan": row["masked_pan"],
        "batch": row["batch"],
        "rrn": row["rrn"],
    }


__all__ = [
    "CardSettlementSerializer",
    "RecordCardSettlementSerializer",
    "held_day_payload",
    "held_payment_payload",
    "suggestion_payload",
]
