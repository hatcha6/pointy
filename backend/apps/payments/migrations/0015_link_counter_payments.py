"""Link every cancellation made before ``Payment.reverses`` existed.

Until now a cancelled cash payment's counter row was ignored by the drawer that
handed the money back, so every shift that cancelled one closed short by that
amount. Linking the rows already written corrects those drawers' figures too.
The matching rules — and why a reference alone is not trusted — live in
``apps.payments.reconciliation``, which applies the same catch-up to rows an
older backend writes during a live update.
"""

from django.db import migrations


def link(apps, schema_editor):
    from apps.payments.reconciliation import link_counter_payments

    link_counter_payments(apps.get_model("payments", "Payment"))


class Migration(migrations.Migration):
    dependencies = [
        ("payments", "0014_payment_reverses"),
    ]

    operations = [
        migrations.RunPython(link, migrations.RunPython.noop),
    ]
