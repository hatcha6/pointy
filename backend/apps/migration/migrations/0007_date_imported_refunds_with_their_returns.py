"""Date every imported refund with the return it pays out.

The sale-return loader moved an imported return (``OrderAdjustment.created_at``)
back to the day it happened in the old system, but left its refund payment on
the day of the import. A report as of any day in between saw the goods come
back and not the money go out, and read the customer as owing their own refund.
The loader now dates both; this gives the rows it already wrote the same date.

Only imported returns: they hang on the import's own drawer session, which no
till ever opens. A refund is matched to its return by order, amount and the
reference the loader wrote, and is moved only when it is dated after the
return, so running this twice changes nothing.
"""

from django.db import migrations

#: ``apps.migration.loaders.sales._MIGRATION_OWNER_KEY``, frozen here as a
#: migration must be.
MIGRATION_OWNER_KEY = "migration:import"


def date_refunds_with_their_returns(apps, schema_editor):
    from apps.documents.guards import system_write

    OrderAdjustment = apps.get_model("sales", "OrderAdjustment")
    Payment = apps.get_model("payments", "Payment")
    returns = OrderAdjustment.objects.filter(
        register_session__owner_key=MIGRATION_OWNER_KEY,
        adjustment_type="return",
    ).values_list("pk", "order_id", "amount", "created_at")
    with system_write():
        for pk, order_id, amount, returned_at in list(returns):
            Payment.objects.filter(
                order_id=order_id,
                amount=-amount,
                external_reference=f"return:{pk}",
                paid_at__gt=returned_at,
            ).update(paid_at=returned_at, created_at=returned_at)


class Migration(migrations.Migration):
    dependencies = [
        ("migration", "0006_collapseplan_collapsecandidate_and_more"),
        ("payments", "0013_payment_method_salary_deduction"),
        ("sales", "0037_order_extra_discount_amount"),
    ]

    operations = [
        migrations.RunPython(
            date_refunds_with_their_returns, migrations.RunPython.noop
        ),
    ]
