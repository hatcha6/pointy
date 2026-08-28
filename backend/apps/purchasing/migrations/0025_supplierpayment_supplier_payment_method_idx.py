"""Index the money date on supplier payments.

``paid_at`` is ``SupplierPayment``'s money date: the money position sums it by
method over a date range, and the account drill-down orders by it. Like
``Payment.paid_at`` it carried no index, so both were sequential scans.

Concurrent build for the same reason as ``payments.0008``: this table is written
by the POS cash-purchase flow, and an ACCESS EXCLUSIVE lock during an update
would block it.
"""

from django.db import migrations, models

INDEX_NAME = "supplier_payment_method_idx"
CREATE_SQL = (
    f"CREATE INDEX CONCURRENTLY IF NOT EXISTS {INDEX_NAME} "
    "ON purchasing_supplierpayment (method, paid_at DESC);"
)
DROP_SQL = f"DROP INDEX CONCURRENTLY IF EXISTS {INDEX_NAME};"


def _run(sql):
    def operation(apps, schema_editor):
        connection = schema_editor.connection
        if connection.vendor != "postgresql":
            return
        with connection.cursor() as cursor:
            cursor.execute(sql)

    return operation


class Migration(migrations.Migration):
    atomic = False

    dependencies = [
        ("purchasing", "0024_purchase_order_cancelled_total"),
    ]

    operations = [
        migrations.SeparateDatabaseAndState(
            database_operations=[
                migrations.RunPython(
                    _run(CREATE_SQL), _run(DROP_SQL), atomic=False
                ),
            ],
            state_operations=[
                migrations.AddIndex(
                    model_name="supplierpayment",
                    index=models.Index(
                        fields=["method", "-paid_at"], name=INDEX_NAME
                    ),
                ),
            ],
        ),
    ]
