from django.db import migrations
from django.db.models import F, OuterRef, Subquery


def backfill(apps, schema_editor):
    """Attribute historical payments to the session that issued their order so
    every already-closed register drawer reconciles exactly as before (the old
    ``cash_sales_total`` joined through ``order.register_session``). Also set
    ``paid_at`` to each row's creation time instead of the column-add default.
    """
    Payment = apps.get_model("payments", "Payment")
    Order = apps.get_model("sales", "Order")

    Payment.objects.filter(register_session__isnull=True).update(
        register_session_id=Subquery(
            Order.objects.filter(pk=OuterRef("order_id")).values(
                "register_session_id"
            )[:1]
        )
    )
    Payment.objects.update(paid_at=F("created_at"))


def noop(apps, schema_editor):
    # Irreversible-but-harmless: leaving register_session/paid_at populated on a
    # reverse migration is fine; nothing to undo.
    pass


class Migration(migrations.Migration):

    dependencies = [
        ("payments", "0006_payment_created_by_payment_paid_at_and_more"),
    ]

    operations = [
        migrations.RunPython(backfill, noop),
    ]
