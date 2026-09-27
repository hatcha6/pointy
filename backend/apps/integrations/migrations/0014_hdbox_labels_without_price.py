"""Take HD Box's agency price out of the labels already written on sales.

HD Box words a renewal as "12 month 220.00$", and 220.00 is what the float pays
— the shop's cost. The driver now leaves it out of every new label; this does
the same for the top-ups already sold, whose labels are shown on invoices, in
the shift report and in a cashier's alerts. The months are their own column,
so nothing is lost. Data only: the column is unchanged, so an older build
reading it during an update sees an ordinary label.
"""

import re

from django.db import migrations

# A copy of ``providers.hdbox._LABEL_PRICE_RE``, frozen here as migrations must
# be: the driver's pattern may change and this must keep doing what it did.
_LABEL_PRICE_RE = re.compile(
    r"\s*\(?\s*(?:\$\s*\d[\d,]*(?:\.\d+)?|\d[\d,]*\.\d+\s*\$?|\d[\d,]*\s*\$)"
    r"\s*\)?\s*$"
)


def strip_prices(apps, schema_editor):
    IntegrationFulfillment = apps.get_model("integrations", "IntegrationFulfillment")
    changed = []
    # A plain read, not .iterator(): server-side cursors and PgBouncer's
    # transaction pooling do not mix, and a shop's top-ups fit in memory.
    for row in IntegrationFulfillment.objects.filter(provider="hdbox").only(
        "pk", "option_label"
    ):
        cleaned = _LABEL_PRICE_RE.sub("", row.option_label or "").strip()
        if cleaned != row.option_label:
            row.option_label = cleaned
            changed.append(row)
    IntegrationFulfillment.objects.bulk_update(
        changed, ["option_label"], batch_size=500
    )


class Migration(migrations.Migration):

    dependencies = [
        ("integrations", "0013_provider_payment_mirror"),
    ]

    operations = [
        migrations.RunPython(strip_prices, migrations.RunPython.noop),
    ]
