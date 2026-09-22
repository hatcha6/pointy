from rest_framework import serializers

from apps.core.period_lock import assert_period_open

from .models import Expense, ExpenseCategory
from .services import create_expense, drawer_fields_locked, update_expense

LOCKED_DRAWER_FIELD_MESSAGE = (
    "هذا المصروف دُفع من درج تمت تسويته وإغلاقه، فلا يمكن تعديل المبلغ أو "
    "طريقة الدفع. سجّل مصروفًا جديدًا أو حركة درج لتصحيح الفرق."
)


class ExpenseCategorySerializer(serializers.ModelSerializer):
    class Meta:
        model = ExpenseCategory
        fields = [
            "id",
            "name",
            "is_active",
            "display_order",
            "created_at",
            "updated_at",
        ]
        read_only_fields = ("created_at", "updated_at")


class ExpenseSerializer(serializers.ModelSerializer):
    category_name = serializers.CharField(source="category.name", read_only=True)
    payment_method_display = serializers.CharField(
        source="get_payment_method_display",
        read_only=True,
    )
    created_by_username = serializers.SerializerMethodField()
    paid_from_register = serializers.SerializerMethodField()
    # Write-only opt-in: when cash + an open register session exists, also book
    # a linked drawer pay-out. Handled in create_expense.
    pay_from_register = serializers.BooleanField(
        write_only=True,
        required=False,
        default=False,
    )
    # Which bank account the money left. Spelled out on read so the expenses
    # list and its details can draw the bank's own mark without a lookup per
    # row — the same shape a payment and a supplier settlement carry.
    money_account_name = serializers.CharField(
        source="money_account.name", read_only=True, default=""
    )
    money_account_bank_slug = serializers.CharField(
        source="money_account.bank_slug", read_only=True, default=""
    )
    money_account_bank_name = serializers.CharField(
        source="money_account.bank_name", read_only=True, default=""
    )

    class Meta:
        model = Expense
        fields = [
            "id",
            "category",
            "category_name",
            "description",
            "amount",
            "payment_method",
            "payment_method_display",
            "spent_at",
            "reference",
            "notes",
            "money_account",
            "money_account_name",
            "money_account_bank_slug",
            "money_account_bank_name",
            "pay_from_register",
            "paid_from_register",
            "register_session",
            "cash_movement",
            "created_by",
            "created_by_username",
            "created_at",
            "updated_at",
        ]
        read_only_fields = (
            "money_account_name",
            "money_account_bank_slug",
            "money_account_bank_name",
            "register_session",
            "cash_movement",
            "created_by",
            "created_at",
            "updated_at",
        )

    def get_created_by_username(self, expense) -> str | None:
        return expense.created_by.username if expense.created_by_id else None

    def get_paid_from_register(self, expense) -> bool:
        return expense.cash_movement_id is not None

    def create(self, validated_data):
        pay_from_register = validated_data.pop("pay_from_register", False)
        request = self.context.get("request")
        user = getattr(request, "user", None)
        return create_expense(
            user=user,
            pay_from_register=pay_from_register,
            **validated_data,
        )

    def validate(self, attrs):
        # An expense carries a backdatable ``spent_at``, so it is one of the
        # few ways a closed month can be made to move after it was reported.
        # Both dates are checked on an edit: moving an expense *out of* a closed
        # period changes that period's total just as surely as moving one in.
        request = self.context.get("request")
        user = getattr(request, "user", None)
        for when in filter(None, (attrs.get("spent_at"), _spent_at(self.instance))):
            assert_period_open(
                when,
                user=user,
                entity_type="expense",
                entity_id=getattr(self.instance, "pk", None),
                action="expense.save",
            )

        # Once the register session behind a drawer-paid expense is closed, the
        # till has been counted against its pay-out. Editing the amount or the
        # payment method then would leave the drawer disagreeing with the
        # expense (or silently rewrite a signed-off count), so both are frozen.
        # Which bank an expense left is the same question the till and the
        # purchasing screens answer, so it is the same rule and the same
        # function: a bank account, active, and only for a method that can
        # actually reach one. Cash left the drawer.
        method = attrs.get(
            "payment_method", getattr(self.instance, "payment_method", None)
        )
        if "money_account" in attrs:
            from apps.payments.serializers import validate_bank_money_account

            validate_bank_money_account(attrs["money_account"], method)
        elif (
            self.instance is not None
            and self.instance.money_account_id
            and method == Expense.PaymentMethod.CASH
        ):
            # Switching a card expense to cash leaves an account naming a bank
            # the money never left. Clear it rather than refuse the edit: the
            # correction the cashier is making is the right one.
            attrs["money_account"] = None

        expense = self.instance
        if expense is not None and drawer_fields_locked(expense):
            locked = {
                field: LOCKED_DRAWER_FIELD_MESSAGE
                for field in ("amount", "payment_method")
                if field in attrs and attrs[field] != getattr(expense, field)
            }
            if locked:
                raise serializers.ValidationError(locked)
        return attrs

    def update(self, instance, validated_data):
        # Whether a pay-out exists is decided once, at creation; an edit never
        # books a new one. It does keep an existing one honest — see
        # ``update_expense``.
        validated_data.pop("pay_from_register", None)
        return update_expense(
            instance, validated_data, request=self.context.get("request")
        )


def _spent_at(expense):
    return expense.spent_at if expense is not None else None
