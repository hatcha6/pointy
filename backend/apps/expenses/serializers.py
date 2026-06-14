from rest_framework import serializers

from .models import Expense, ExpenseCategory
from .services import create_expense


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

    def update(self, instance, validated_data):
        # The drawer linkage is decided once, at creation; editing an expense
        # never re-books or unwinds a pay-out that already happened.
        validated_data.pop("pay_from_register", None)
        return super().update(instance, validated_data)
