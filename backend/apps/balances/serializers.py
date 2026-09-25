from decimal import Decimal

from rest_framework import serializers

from apps.documents.serializers import DocumentLifecycleFields
from apps.treasury.models import MoneyAccount

from . import customers as customer_balances
from . import employees as employee_balances
from . import suppliers as supplier_balances
from .models import (
    BalanceEntry,
    CustomerBalanceEntry,
    EmployeeBalanceEntry,
    SupplierBalanceEntry,
)

ZERO = Decimal("0.00")


class OpeningBalanceSerializer(serializers.Serializer):
    """An opening balance typed into the form that creates a customer or a
    supplier. Written as an ordinary balance entry, in the same transaction as
    the party itself — so a party is never created without the balance it was
    meant to arrive with."""

    direction = serializers.ChoiceField(choices=BalanceEntry.Direction.choices)
    amount = serializers.DecimalField(
        max_digits=10, decimal_places=2, min_value=Decimal("0.01")
    )
    effective_date = serializers.DateField(required=False, allow_null=True)
    note = serializers.CharField(
        required=False, allow_blank=True, max_length=2000, trim_whitespace=True
    )


class BalanceEntryInputSerializer(serializers.Serializer):
    """One opening balance or adjustment, as a person enters it. Never a
    refund: that moves money, and has its own endpoint that moves it."""

    kind = serializers.ChoiceField(
        choices=[
            (BalanceEntry.Kind.OPENING, BalanceEntry.Kind.OPENING.label),
            (BalanceEntry.Kind.ADJUSTMENT, BalanceEntry.Kind.ADJUSTMENT.label),
        ],
        default=BalanceEntry.Kind.ADJUSTMENT,
    )
    direction = serializers.ChoiceField(choices=BalanceEntry.Direction.choices)
    amount = serializers.DecimalField(
        max_digits=10, decimal_places=2, min_value=Decimal("0.01")
    )
    effective_date = serializers.DateField(required=False, allow_null=True)
    note = serializers.CharField(
        required=False, allow_blank=True, max_length=2000, trim_whitespace=True
    )


class EmployeeBalanceEntryInputSerializer(BalanceEntryInputSerializer):
    """An employee's entry, which may say how much of a debt one payroll run
    takes."""

    payroll_deduction_limit = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        min_value=Decimal("0.01"),
        required=False,
        allow_null=True,
    )


class RefundInputSerializer(serializers.Serializer):
    """A balance settled with cash through the actor's drawer."""

    amount = serializers.DecimalField(
        max_digits=10, decimal_places=2, min_value=Decimal("0.01")
    )
    note = serializers.CharField(
        required=False, allow_blank=True, max_length=2000, trim_whitespace=True
    )


class EmployeeSettlementInputSerializer(RefundInputSerializer):
    """An employee's balance settled in cash — either side of it, so it says
    which: ``we_owe_them`` pays the employee, ``they_owe_us`` takes their
    money in."""

    settles = serializers.ChoiceField(choices=BalanceEntry.Direction.choices)


class _BalanceEntrySerializer(DocumentLifecycleFields, serializers.ModelSerializer):
    """What an entry says, what has been settled against it, and whether it
    can still be withdrawn."""

    created_by_username = serializers.SerializerMethodField()
    settled_amount = serializers.SerializerMethodField()
    remaining_amount = serializers.SerializerMethodField()
    can_cancel = serializers.SerializerMethodField()

    ENTRY_FIELDS = [
        "id",
        "number",
        "kind",
        "direction",
        "amount",
        "effective_date",
        "note",
        "created_by",
        "created_by_username",
        "created_at",
        "settled_amount",
        "remaining_amount",
        "can_cancel",
        *DocumentLifecycleFields.LIFECYCLE_FIELDS,
    ]

    #: The domain module that knows how much of an entry has been settled.
    balances = None

    def get_created_by_username(self, entry) -> str | None:
        return entry.created_by.username if entry.created_by_id else None

    def _settled(self, entry) -> Decimal:
        cache = getattr(entry, "_settled_cache", None)
        if cache is None:
            cache = self.balances.settled_amount(entry)
            entry._settled_cache = cache
        return cache

    def get_settled_amount(self, entry) -> str:
        return f"{self._settled(entry):.2f}"

    def get_remaining_amount(self, entry) -> str:
        if not entry.is_submitted:
            return f"{ZERO:.2f}"
        return f"{max(entry.amount - self._settled(entry), ZERO):.2f}"

    def get_can_cancel(self, entry) -> bool:
        # The same rule the cancellation enforces: only while nothing has been
        # collected from, paid against or spent out of it — and never a
        # refund, which handed cash over.
        return (
            entry.is_submitted
            and entry.kind != BalanceEntry.Kind.REFUND
            and self._settled(entry) == ZERO
        )


class CustomerBalanceEntrySerializer(_BalanceEntrySerializer):
    balances = customer_balances
    customer_name = serializers.CharField(source="customer.full_name", read_only=True)

    class Meta:
        model = CustomerBalanceEntry
        fields = [
            *_BalanceEntrySerializer.ENTRY_FIELDS,
            "customer",
            "customer_name",
            # The carrier order a debt entry is collected through, so a payment
            # made against it can be traced back here.
            "order",
        ]
        read_only_fields = fields


class SupplierBalanceEntrySerializer(_BalanceEntrySerializer):
    balances = supplier_balances
    supplier_name = serializers.CharField(source="supplier.name", read_only=True)

    class Meta:
        model = SupplierBalanceEntry
        fields = [
            *_BalanceEntrySerializer.ENTRY_FIELDS,
            "supplier",
            "supplier_name",
        ]
        read_only_fields = fields


class EmployeeBalanceEntrySerializer(_BalanceEntrySerializer):
    balances = employee_balances
    employee_name = serializers.CharField(source="employee.full_name", read_only=True)
    #: What runs drafted or approved but not paid already carry of it — so the
    #: screen can say "on the next payroll" before the money moves.
    scheduled_amount = serializers.SerializerMethodField()

    class Meta:
        model = EmployeeBalanceEntry
        fields = [
            *_BalanceEntrySerializer.ENTRY_FIELDS,
            "employee",
            "employee_name",
            "payroll_deduction_limit",
            "scheduled_amount",
        ]
        read_only_fields = fields

    def get_scheduled_amount(self, entry) -> str:
        return f"{employee_balances.scheduled_amount(entry):.2f}"


class SupplierAccountPaymentSerializer(serializers.Serializer):
    """Pay a supplier against their account: split across what the shop owes
    them, oldest first (``apps.balances.suppliers.record_supplier_account_payment``)."""

    method = serializers.ChoiceField(choices=[])
    amount = serializers.DecimalField(
        max_digits=10, decimal_places=2, min_value=Decimal("0.01")
    )
    reference = serializers.CharField(
        required=False, allow_blank=True, max_length=128, default=""
    )
    notes = serializers.CharField(required=False, allow_blank=True, default="")
    paid_at = serializers.DateTimeField(required=False)
    money_account = serializers.PrimaryKeyRelatedField(
        queryset=MoneyAccount.objects.all(), required=False, allow_null=True
    )

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        from apps.purchasing.models import SupplierPayment

        # Every supplier method but the refund, which is money coming *back*
        # from a supplier and only a purchase return writes.
        self.fields["method"].choices = [
            (value, label)
            for value, label in SupplierPayment.Method.choices
            if value != SupplierPayment.Method.REFUND
        ]

    def validate(self, attrs):
        from apps.core.period_lock import assert_period_open

        request = self.context.get("request")
        # ``paid_at`` is caller-supplied, the same door the supplier payment
        # endpoint guards.
        assert_period_open(
            attrs.get("paid_at"),
            user=getattr(request, "user", None),
            entity_type="supplier_payment",
            action="purchasing.supplier_account_payment",
        )
        if attrs.get("money_account") is not None:
            from apps.payments.serializers import validate_bank_money_account

            validate_bank_money_account(attrs["money_account"], attrs.get("method"))
        return attrs


__all__ = [
    "BalanceEntryInputSerializer",
    "CustomerBalanceEntrySerializer",
    "EmployeeBalanceEntryInputSerializer",
    "EmployeeBalanceEntrySerializer",
    "EmployeeSettlementInputSerializer",
    "OpeningBalanceSerializer",
    "RefundInputSerializer",
    "SupplierAccountPaymentSerializer",
    "SupplierBalanceEntrySerializer",
]
