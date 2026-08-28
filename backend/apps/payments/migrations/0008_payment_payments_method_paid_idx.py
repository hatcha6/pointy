"""Index the money date on the busiest write table in the shop.

``paid_at`` is ``Payment``'s money date (``apps.core.money_dates``): the money
position sums it by method, its drill-down orders by it, and the profit report's
commission line ranges over it. It carried no index at all, so every one of
those was a sequential scan plus a sort. Measured on 25,000 payments: the
drill-down's source query went from a Seq Scan + top-N heapsort at 17.7ms to an
Index Scan that stops at the page, at 0.5ms — and, more importantly, from
O(table) to O(page), so it stays flat as a shop's history grows.

Built with ``CREATE INDEX CONCURRENTLY`` (hence ``atomic = False``), following
``catalog.0020_search_trigram_indexes``: a plain ``AddIndex`` takes an ACCESS
EXCLUSIVE lock, and this table is written on every single checkout. Applying it
on a live shop must never block the till. ``SeparateDatabaseAndState`` keeps
Django's model state in step with the ``Meta.indexes`` entry while the database
side does the concurrent build.
"""

from django.db import migrations, models

INDEX_NAME = "payments_method_paid_idx"
CREATE_SQL = (
    f"CREATE INDEX CONCURRENTLY IF NOT EXISTS {INDEX_NAME} "
    "ON payments_payment (method, paid_at DESC);"
)
DROP_SQL = f"DROP INDEX CONCURRENTLY IF EXISTS {INDEX_NAME};"


def _run(sql):
    def operation(apps, schema_editor):
        # CONCURRENTLY is PostgreSQL-only. On sqlite (the fast/parallel test
        # path) this is a no-op — the same choice catalog.0020 makes, and the
        # test datasets are far too small for the index to matter.
        connection = schema_editor.connection
        if connection.vendor != "postgresql":
            return
        with connection.cursor() as cursor:
            cursor.execute(sql)

    return operation


class Migration(migrations.Migration):
    atomic = False

    dependencies = [
        ("payments", "0007_backfill_payment_session_paid_at"),
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
                    model_name="payment",
                    index=models.Index(
                        fields=["method", "-paid_at"], name=INDEX_NAME
                    ),
                ),
            ],
        ),
    ]
