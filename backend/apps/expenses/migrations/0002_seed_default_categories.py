from django.db import migrations

from apps.expenses.category_defaults import (
    DEFAULT_EXPENSE_CATEGORIES,
    DEFAULT_EXPENSE_CATEGORY_NAMES,
)


def seed_categories(apps, schema_editor):
    ExpenseCategory = apps.get_model("expenses", "ExpenseCategory")
    for name, display_order in DEFAULT_EXPENSE_CATEGORIES:
        ExpenseCategory.objects.get_or_create(
            name=name,
            defaults={"display_order": display_order, "is_active": True},
        )


def remove_categories(apps, schema_editor):
    ExpenseCategory = apps.get_model("expenses", "ExpenseCategory")
    # Only remove seeded rows that were never used by an expense.
    ExpenseCategory.objects.filter(
        name__in=DEFAULT_EXPENSE_CATEGORY_NAMES,
        expenses__isnull=True,
    ).delete()


class Migration(migrations.Migration):
    dependencies = [
        ("expenses", "0001_initial"),
    ]

    operations = [
        migrations.RunPython(seed_categories, remove_categories),
    ]
