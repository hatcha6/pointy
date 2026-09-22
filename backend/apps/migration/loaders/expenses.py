"""Expense loaders: expense categories + expense transactions.

Both write directly. Historical expenses never link a register cash movement.
``Expense.spent_at`` is a real (backdatable) date, so the original date is kept
without the ``created_at`` trick the sale/PO loaders need.
"""

from __future__ import annotations

from apps.expenses.models import Expense, ExpenseCategory

from ..entity_plan import EXPENSE, EXPENSE_CATEGORY
from .base import (
    CREATED,
    UPDATED,
    BaseLoader,
    LoaderError,
    LoadOutcome,
    clean_str,
    to_bool,
    to_decimal,
)

_DEFAULT_CATEGORY = "مصروفات مستوردة"
_EXPENSE_METHODS = {choice for choice, _label in Expense.PaymentMethod.choices}


class ExpenseCategoryLoader(BaseLoader):
    entity_type = EXPENSE_CATEGORY

    def load(self, record, resolver, *, dry_run):
        name = clean_str(record.name)
        if not name:
            raise LoaderError("اسم نوع المصروف مطلوب.", code="missing_name")
        instance = resolver.existing(ExpenseCategory, self.entity_type, record.source_key)
        if instance is None:
            instance = ExpenseCategory.objects.filter(name=name).first()
        action = UPDATED if instance is not None else CREATED
        if instance is None:
            instance = ExpenseCategory()
        instance.name = name
        instance.is_active = to_bool(record.is_active)
        instance.save()
        resolver.remember(self.entity_type, record.source_key, instance)
        return LoadOutcome(action, instance.pk)


class ExpenseLoader(BaseLoader):
    entity_type = EXPENSE

    def load(self, record, resolver, *, dry_run):
        amount = to_decimal(record.amount)
        if amount <= 0:
            raise LoaderError("مبلغ المصروف يجب أن يكون أكبر من صفر.", code="invalid_amount")

        category_name = clean_str(record.category_name) or _DEFAULT_CATEGORY
        category, _created = ExpenseCategory.objects.get_or_create(name=category_name)

        instance = resolver.existing(Expense, self.entity_type, record.source_key)
        action = UPDATED if instance is not None else CREATED
        if instance is None:
            instance = Expense()
        instance.category = category
        instance.description = clean_str(record.description) or category_name
        instance.amount = amount
        instance.payment_method = (
            record.payment_method if record.payment_method in _EXPENSE_METHODS else "cash"
        )
        if record.occurred_at is not None:
            instance.spent_at = (
                record.occurred_at.date()
                if hasattr(record.occurred_at, "date")
                else record.occurred_at
            )
        instance.reference = clean_str(record.reference)[:128]
        instance.save()
        resolver.remember(self.entity_type, record.source_key, instance)
        return LoadOutcome(action, instance.pk)
