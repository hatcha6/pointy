"""API shapes for the money position.

Balances are strings, like every other money figure in this API, so a Decimal
never round-trips through a float on its way to the till.
"""

from datetime import timedelta
from decimal import Decimal

from django.db import transaction
from rest_framework import serializers

from apps.core.period_lock import assert_period_open
from apps.core.timeutils import business_local_date

from .models import CardSettlement, MoneyAccount, MoneyCount, MoneyTransfer
from .position import account_is_routed, expected_balance_for, routed_account
from .settlement_calendar import format_weekdays, parse_weekdays

MONEY_PLACES = Decimal("0.01")
# How far back a clearing account may start holding. Far enough to cover the
# days the processor has not paid yet — a weekend, a long Eid closure — and no
# further: every card sale since the start becomes "held" again, and a year of
# takings the processor paid long ago would vanish from the bank until each
# deposit was recorded again.
CLEARING_MAX_BACKDATE_DAYS = 31


def _money(value):
    if value is None:
        return None
    return str(Decimal(value).quantize(MONEY_PLACES))


class MoneyAccountSerializer(serializers.ModelSerializer):
    is_routed = serializers.SerializerMethodField()
    settles_into = serializers.PrimaryKeyRelatedField(
        queryset=MoneyAccount.objects.filter(kind=MoneyAccount.Kind.BANK),
        required=False,
        allow_null=True,
    )
    settles_into_name = serializers.CharField(
        source="settles_into.name", read_only=True, default=""
    )

    class Meta:
        model = MoneyAccount
        fields = (
            "id",
            "name",
            "kind",
            "bank_name",
            "bank_slug",
            "account_number",
            "iban",
            "opening_balance",
            "opening_at",
            "is_default",
            "is_active",
            "is_routed",
            "display_order",
            "notes",
            # Clearing accounts only.
            "settles_into",
            "settles_into_name",
            "holds_untagged_card",
            "settlement_cutoff",
            "settlement_weekdays",
            "settlement_lag_days",
            "closed_on",
        )
        read_only_fields = ("holds_untagged_card", "closed_on")
        # DRF reads the model's ``treasury_one_default_account_per_kind``
        # constraint as "kind is unique" and drops its ``is_default`` condition,
        # so every edit to a *second* cash box or bank answered 400 "money
        # account with this kind already exists" — whatever was typed. That is
        # how an imported "الخزينة الرئيسية" could not have its opening balance
        # set to zero. The generated check lands on the ``kind`` field, so that
        # is where it is switched off; the invariant is kept by
        # ``_take_default`` below, which moves the flag rather than refusing the
        # save, and the database constraint is still there behind it.
        extra_kwargs = {"kind": {"validators": []}}

    def get_is_routed(self, account) -> bool:
        return account_is_routed(account)

    def validate(self, attrs):
        kind = attrs.get("kind", getattr(self.instance, "kind", None))
        if self.instance is not None and kind != self.instance.kind and (
            MoneyAccount.Kind.CLEARING in (kind, self.instance.kind)
        ):
            # What a clearing account holds is a rule about one bank; turning
            # one into a bank (or a bank into one) would move every card sale
            # it ever held.
            raise serializers.ValidationError(
                {"kind": "لا يمكن تغيير نوع حساب قيد التسوية."}
            )
        if kind in (MoneyAccount.Kind.CASH, MoneyAccount.Kind.CLEARING):
            # A cash box has no bank identity; silently keeping stale values
            # would show a bank number — or worse, an IBAN a customer might be
            # asked to transfer to — under a cash account. Neither has money
            # held by a processor: its bank is the one it settles into.
            attrs["bank_name"] = ""
            attrs["bank_slug"] = ""
            attrs["account_number"] = ""
            attrs["iban"] = ""
        if kind == MoneyAccount.Kind.CLEARING:
            return self._validate_clearing(attrs)
        attrs["settles_into"] = None
        return attrs

    def validate_settlement_weekdays(self, value):
        days = parse_weekdays(value)
        if not days:
            raise serializers.ValidationError(
                "اختر يومًا واحدًا على الأقل تُودِع فيه شركة الدفع."
            )
        return format_weekdays(days)

    def _validate_clearing(self, attrs):
        instance = self.instance
        bank = attrs.get("settles_into", getattr(instance, "settles_into", None))
        if bank is None:
            raise serializers.ValidationError(
                {"settles_into": "حدّد المصرف الذي تُودِع فيه شركة الدفع."}
            )
        if instance is not None and bank.pk != instance.settles_into_id:
            raise serializers.ValidationError(
                {"settles_into": "لا يمكن تغيير مصرف حساب قيد التسوية بعد إنشائه."}
            )
        if instance is None and not bank.is_active:
            raise serializers.ValidationError(
                {"settles_into": "هذا الحساب المصرفي غير نشط."}
            )
        # Never an opening balance: the takings it holds are already in Pointy
        # as card sales, so a figure typed here would count them twice.
        attrs["opening_balance"] = Decimal("0.00")
        attrs["is_default"] = False

        today = business_local_date()
        starts = attrs.get("opening_at", getattr(instance, "opening_at", None)) or today
        attrs["opening_at"] = starts
        if starts > today:
            raise serializers.ValidationError(
                {"opening_at": "لا يمكن أن يبدأ الاحتجاز في تاريخ لم يأتِ بعد."}
            )
        if starts < today - timedelta(days=CLEARING_MAX_BACKDATE_DAYS):
            raise serializers.ValidationError(
                {
                    "opening_at": (
                        "ابدأ من أقدم يوم لم تُحوِّل شركة الدفع مبالغه بعد، "
                        f"وفي حدود {CLEARING_MAX_BACKDATE_DAYS} يومًا."
                    )
                }
            )
        if (
            instance is not None
            and starts != instance.opening_at
            and CardSettlement.objects.live()
            .filter(clearing_account=instance)
            .exists()
        ):
            raise serializers.ValidationError(
                {"opening_at": "سُجّلت تسويات على هذا الحساب، فلا يمكن تغيير تاريخ بدايته."}
            )
        siblings = MoneyAccount.objects.filter(
            kind=MoneyAccount.Kind.CLEARING, settles_into=bank
        )
        if instance is not None:
            siblings = siblings.exclude(pk=instance.pk)
        if siblings.filter(closed_on__isnull=True).exists():
            raise serializers.ValidationError(
                {"settles_into": "لهذا المصرف حساب قيد تسوية مفتوح بالفعل."}
            )
        overlapping = siblings.filter(closed_on__gte=starts)
        if overlapping.exists():
            raise serializers.ValidationError(
                {
                    "opening_at": (
                        "يجب أن يبدأ بعد آخر يوم احتجزه حساب التسوية السابق لهذا المصرف."
                    )
                }
            )

        if instance is not None and "is_active" in attrs:
            if attrs["is_active"] and not instance.is_active:
                # Reopening would hold again the takings of the closed gap,
                # which went straight to the bank meanwhile.
                raise serializers.ValidationError(
                    {"is_active": "لا يمكن إعادة فتح حساب تسوية مغلق. أنشئ حسابًا جديدًا."}
                )
            if not attrs["is_active"] and instance.is_active:
                # Stops holding after today; what it holds now stays held and
                # is still settled from this account.
                attrs["closed_on"] = today
        return attrs

    def validate_iban(self, value):
        # Stored the way it is compared and shown: no spaces, upper case. A
        # shop copies an IBAN off a statement that prints it in groups of four.
        return "".join(str(value or "").split()).upper()

    @staticmethod
    def _take_default(kind, *, exclude_pk=None):
        """Take the default flag off every other account of ``kind``.

        Runs *before* the save, not after: the one-default-per-kind constraint
        is checked on write, so clearing the old default afterwards meant a
        second account being made the default hit an IntegrityError first.
        """
        others = MoneyAccount.objects.filter(kind=kind, is_default=True)
        if exclude_pk is not None:
            others = others.exclude(pk=exclude_pk)
        others.update(is_default=False)

    @transaction.atomic
    def create(self, validated_data):
        if validated_data["kind"] == MoneyAccount.Kind.CLEARING:
            return self._create_clearing(validated_data)
        # The first account of a kind is its default, so a shop that adds one
        # account and never opens the settings screen still sees its money.
        if not MoneyAccount.objects.filter(kind=validated_data["kind"]).exists():
            validated_data["is_default"] = True
        if validated_data.get("is_default"):
            self._take_default(validated_data["kind"])
        return super().create(validated_data)

    def _create_clearing(self, validated_data):
        """Open a clearing account; it is never anyone's default.

        It also holds the card payments that name no bank when its bank is the
        one those fall back to today — decided now and frozen, so a later
        change of default bank cannot move takings after the fact.
        """
        bank = validated_data["settles_into"]
        default_bank = routed_account(MoneyAccount.Kind.BANK)
        untagged_taken = MoneyAccount.objects.filter(
            kind=MoneyAccount.Kind.CLEARING,
            holds_untagged_card=True,
            closed_on__isnull=True,
        ).exists()
        validated_data["holds_untagged_card"] = bool(
            default_bank is not None
            and default_bank.pk == bank.pk
            and not untagged_taken
        )
        validated_data["is_default"] = False
        return super().create(validated_data)

    @transaction.atomic
    def update(self, instance, validated_data):
        kind = validated_data.get("kind", instance.kind)
        if validated_data.get("is_default"):
            self._take_default(kind, exclude_pk=instance.pk)
        return super().update(instance, validated_data)


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
        # ``moved_at`` is backdatable, so a transfer is one of the few ways a
        # month that has already been reported can be made to move.
        request = self.context.get("request")
        assert_period_open(
            attrs.get("moved_at", getattr(self.instance, "moved_at", None)),
            user=getattr(request, "user", None),
            entity_type="money_transfer",
            entity_id=getattr(self.instance, "pk", None),
            action="treasury.transfer",
        )
        source = attrs.get("from_account", getattr(self.instance, "from_account", None))
        target = attrs.get("to_account", getattr(self.instance, "to_account", None))
        if source is None and target is None:
            raise serializers.ValidationError(
                "حدد الحساب المُحوَّل منه أو المُحوَّل إليه على الأقل."
            )
        if source is not None and target is not None and source.pk == target.pk:
            raise serializers.ValidationError("لا يمكن التحويل إلى نفس الحساب.")
        if (
            source is not None
            and target is not None
            and source.kind == MoneyAccount.Kind.PROVIDER
            and target.kind == MoneyAccount.Kind.PROVIDER
        ):
            # One provider's credit cannot pay another: LNET does not pay HD
            # Box. The money comes back to the shop and goes out again, each
            # its own transfer on its own day. The top-up screen refuses the
            # same thing.
            raise serializers.ValidationError(
                "لا يمكن التحويل من رصيد مزوّد إلى رصيد مزوّد آخر."
            )
        if any(
            account is not None and account.is_clearing for account in (source, target)
        ):
            # Held card money leaves only by a settlement that names the sales
            # it paid for. A free-typed transfer out would leave a balance
            # nobody could take apart, which is the drift this account exists
            # to prevent.
            raise serializers.ValidationError(
                "مبالغ البطاقات قيد التسوية لا تُحوَّل يدويًا؛ سجّل وصول تحويل شركة الدفع بدلًا من ذلك."
            )
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


class HeldSummarySerializer(serializers.Serializer):
    """A clearing account's held days at a glance: how many, and how late."""

    days = serializers.IntegerField()
    payments = serializers.IntegerField()
    oldest_day = serializers.DateField(allow_null=True)
    next_expected_on = serializers.DateField(allow_null=True)
    overdue_days = serializers.IntegerField()
    overdue_amount = serializers.SerializerMethodField()

    def get_overdue_amount(self, summary) -> str:
        return _money(summary["overdue_amount"])


class AccountPositionSerializer(serializers.Serializer):
    """One account card: what it should hold, and why."""

    account = MoneyAccountSerializer()
    expected_balance = serializers.SerializerMethodField()
    components = PositionComponentSerializer(many=True)
    last_count = MoneyCountSerializer(allow_null=True)
    uncounted_since = serializers.DateTimeField(allow_null=True)
    # Clearing accounts only, and only on today's position: which held days
    # are waiting and whether any is late. ``None`` everywhere else.
    held = serializers.SerializerMethodField()

    def get_expected_balance(self, position) -> str:
        return _money(position["expected_balance"])

    def get_held(self, position):
        summary = position.get("held")
        if summary is None:
            return None
        return HeldSummarySerializer(summary).data


class TreasuryTotalsSerializer(serializers.Serializer):
    cash = serializers.SerializerMethodField()
    bank = serializers.SerializerMethodField()
    # Card takings the processor is holding. Inside ``total``.
    in_transit = serializers.SerializerMethodField()
    total = serializers.SerializerMethodField()
    accounts_counted = serializers.IntegerField()
    accounts_total = serializers.IntegerField()
    accounts_with_variance = serializers.IntegerField()

    def get_cash(self, totals) -> str:
        return _money(totals["cash"])

    def get_bank(self, totals) -> str:
        return _money(totals["bank"])

    def get_in_transit(self, totals) -> str:
        return _money(totals.get("in_transit", 0))

    def get_total(self, totals) -> str:
        return _money(totals["total"])


class ConsignmentCustodySerializer(serializers.Serializer):
    unit_count = serializers.IntegerField()
    declared_value = serializers.DecimalField(max_digits=14, decimal_places=2)


class TreasuryObligationsSerializer(serializers.Serializer):
    """What the shop is holding that belongs to somebody else.

    An **overlay**, never a component. The cash in the drawer really is there;
    what is untrue is that all of it is the shop's. Subtracting this from the
    money position would double-count it the moment the payout is made, so the
    screen renders it beneath the total as *منها مستحقات أمانات* (§5.8).
    """

    consignor_payable = serializers.DecimalField(max_digits=14, decimal_places=2)
    #: The debt running the other way — a consignment that came back after its
    #: owner had already collected. Beside the payable, never netted into it.
    consignor_receivable = serializers.DecimalField(
        max_digits=14, decimal_places=2
    )
    consignor_claims_open = serializers.DecimalField(
        max_digits=14, decimal_places=2
    )
    #: «N مطالبة قيد التقدير» — open incidents nobody has put a figure on.
    consignor_claims_unassessed = serializers.IntegerField()
    custody = ConsignmentCustodySerializer()


class TreasuryPositionSerializer(serializers.Serializer):
    as_of = serializers.DateField()
    accounts = AccountPositionSerializer(many=True)
    totals = TreasuryTotalsSerializer()
    obligations = TreasuryObligationsSerializer()
