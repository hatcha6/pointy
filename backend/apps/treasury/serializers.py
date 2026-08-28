"""API shapes for the money position.

Balances are strings, like every other money figure in this API, so a Decimal
never round-trips through a float on its way to the till.
"""

from decimal import Decimal

from rest_framework import serializers

from .models import MoneyAccount, MoneyCount, MoneyTransfer
from .position import account_is_routed, expected_balance_for

MONEY_PLACES = Decimal("0.01")


def _money(value):
    if value is None:
        return None
    return str(Decimal(value).quantize(MONEY_PLACES))


class MoneyAccountSerializer(serializers.ModelSerializer):
    is_routed = serializers.SerializerMethodField()

    class Meta:
        model = MoneyAccount
        fields = (
            "id",
            "name",
            "kind",
            "bank_name",
            "account_number",
            "opening_balance",
            "opening_at",
            "is_default",
            "is_active",
            "is_routed",
            "display_order",
            "notes",
        )

    def get_is_routed(self, account) -> bool:
        return account_is_routed(account)

    def validate(self, attrs):
        kind = attrs.get("kind", getattr(self.instance, "kind", None))
        if kind == MoneyAccount.Kind.CASH:
            # A cash box has no bank identity; silently keeping stale values
            # would show a bank number under a cash account.
            attrs["bank_name"] = ""
            attrs["account_number"] = ""
        return attrs

    def _clear_other_defaults(self, instance):
        MoneyAccount.objects.filter(kind=instance.kind, is_default=True).exclude(
            pk=instance.pk
        ).update(is_default=False)

    def create(self, validated_data):
        # The first account of a kind is its default, so a shop that adds one
        # account and never opens the settings screen still sees its money.
        if not MoneyAccount.objects.filter(kind=validated_data["kind"]).exists():
            validated_data["is_default"] = True
        instance = super().create(validated_data)
        if instance.is_default:
            self._clear_other_defaults(instance)
        return instance

    def update(self, instance, validated_data):
        instance = super().update(instance, validated_data)
        if instance.is_default:
            self._clear_other_defaults(instance)
        return instance


class MoneyCountSerializer(serializers.ModelSerializer):
    created_by_name = serializers.CharField(
        source="created_by.get_full_name",
        read_only=True,
        default="",
    )
    account_name = serializers.CharField(source="account.name", read_only=True)

    class Meta:
        model = MoneyCount
        fields = (
            "id",
            "account",
            "account_name",
            "counted_amount",
            "expected_amount",
            "variance",
            "counted_at",
            "note",
            "created_by",
            "created_by_name",
        )
        read_only_fields = (
            "expected_amount",
            "variance",
            "counted_at",
            "created_by",
        )

    def create(self, validated_data):
        account = validated_data["account"]
        expected = expected_balance_for(account)
        counted = Decimal(validated_data["counted_amount"])
        validated_data["expected_amount"] = expected
        validated_data["variance"] = (counted - expected).quantize(MONEY_PLACES)
        request = self.context.get("request")
        if request is not None and request.user.is_authenticated:
            validated_data["created_by"] = request.user
        return super().create(validated_data)


class MoneyTransferSerializer(serializers.ModelSerializer):
    kind = serializers.CharField(read_only=True)
    from_account_name = serializers.CharField(
        source="from_account.name", read_only=True, default=""
    )
    to_account_name = serializers.CharField(
        source="to_account.name", read_only=True, default=""
    )
    created_by_name = serializers.CharField(
        source="created_by.get_full_name", read_only=True, default=""
    )

    class Meta:
        model = MoneyTransfer
        fields = (
            "id",
            "kind",
            "from_account",
            "from_account_name",
            "to_account",
            "to_account_name",
            "amount",
            "moved_at",
            "reason",
            "reference",
            "created_by",
            "created_by_name",
            "created_at",
        )
        read_only_fields = ("created_by", "created_at")

    def validate(self, attrs):
        source = attrs.get("from_account", getattr(self.instance, "from_account", None))
        target = attrs.get("to_account", getattr(self.instance, "to_account", None))
        if source is None and target is None:
            raise serializers.ValidationError(
                "حدد الحساب المُحوَّل منه أو المُحوَّل إليه على الأقل."
            )
        if source is not None and target is not None and source.pk == target.pk:
            raise serializers.ValidationError("لا يمكن التحويل إلى نفس الحساب.")
        return attrs

    def create(self, validated_data):
        request = self.context.get("request")
        if request is not None and request.user.is_authenticated:
            validated_data["created_by"] = request.user
        return super().create(validated_data)


class PositionComponentSerializer(serializers.Serializer):
    code = serializers.CharField()
    amount = serializers.SerializerMethodField()
    direction = serializers.CharField()

    def get_amount(self, component) -> str:
        return _money(component["amount"])


class AccountPositionSerializer(serializers.Serializer):
    """One account card: what it should hold, and why."""

    account = MoneyAccountSerializer()
    expected_balance = serializers.SerializerMethodField()
    components = PositionComponentSerializer(many=True)
    last_count = MoneyCountSerializer(allow_null=True)
    uncounted_since = serializers.DateTimeField(allow_null=True)

    def get_expected_balance(self, position) -> str:
        return _money(position["expected_balance"])


class TreasuryTotalsSerializer(serializers.Serializer):
    cash = serializers.SerializerMethodField()
    bank = serializers.SerializerMethodField()
    total = serializers.SerializerMethodField()
    accounts_counted = serializers.IntegerField()
    accounts_total = serializers.IntegerField()
    accounts_with_variance = serializers.IntegerField()

    def get_cash(self, totals) -> str:
        return _money(totals["cash"])

    def get_bank(self, totals) -> str:
        return _money(totals["bank"])

    def get_total(self, totals) -> str:
        return _money(totals["total"])


class TreasuryPositionSerializer(serializers.Serializer):
    as_of = serializers.DateField()
    accounts = AccountPositionSerializer(many=True)
    totals = TreasuryTotalsSerializer()
