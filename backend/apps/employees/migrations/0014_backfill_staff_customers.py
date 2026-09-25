"""Give every current employee the staff customer account new ones are born with.

From this release an employee is created together with a customer account of
their own, which is what a cashier picks at the till when a member of staff
takes goods home — and what the next payroll run deducts from. Staff hired
before it need the same account, or the feature would work for next month's
hires and nobody on the payroll today.

Only employees who can still be paid: an inactive or terminated one is left
alone, and gets an account the day they come back (``ensure_staff_customer``).

Accounts older than automatic employee creation have no employee row at all,
so those users get one first — the same profile ``ensure_employee_for_user``
would have made on the day — and then the customer account with it. Without
that step the owner's own login, and every till account made before employees
existed, would be the ones left out.
"""

from django.conf import settings
from django.db import migrations
from django.utils import timezone
from django.utils.crypto import get_random_string


def backfill(apps, schema_editor):
    Employee = apps.get_model("employees", "Employee")
    Customer = apps.get_model("customers", "Customer")
    User = apps.get_model(settings.AUTH_USER_MODEL)

    for user in (
        User.objects.filter(is_active=True, employee_profile__isnull=True)
        .order_by("pk")
    ):
        full_name = f"{user.first_name} {user.last_name}".strip() or user.username
        # ``Employee.save`` numbers a new row; the historical model has no such
        # method, so the number is written the same way here.
        Employee.objects.create(
            user=user,
            full_name=full_name,
            employee_number=(
                f"E{timezone.now():%Y%m%d%H%M%S}{get_random_string(4).upper()}"
            ),
        )

    employees = Employee.objects.filter(
        customer__isnull=True, status__in=("active", "on_leave")
    ).order_by("pk")
    for employee in employees:
        customer = Customer.objects.create(
            full_name=employee.full_name or employee.employee_number,
            phone=employee.phone,
            email=employee.email,
        )
        # ``Customer.save`` numbers a new row from its own date and id; the
        # historical model has no such method, so the number is written the same
        # way here.
        customer.customer_number = f"C{customer.created_at:%Y%m%d}{customer.id:06d}"
        customer.save(update_fields=["customer_number"])
        employee.customer = customer
        employee.save(update_fields=["customer"])


def unbackfill(apps, schema_editor):
    """Nothing to undo: the link this wrote is dropped with its column, and the
    accounts stay as ordinary customers with whatever history they gathered."""


class Migration(migrations.Migration):
    dependencies = [
        ("employees", "0013_staff_purchases"),
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
    ]

    operations = [
        migrations.RunPython(backfill, unbackfill),
    ]
