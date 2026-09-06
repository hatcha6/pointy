"""Give every existing order the lifecycle its status implied.

``paid`` and ``void`` are unambiguous. ``open`` is not — it means a sale still
being rung up for a standard order and an issued, delivered, unpaid invoice for
a credit one — so it is resolved by what the row actually is: a credit invoice
or a quotation that exists at all was issued, and only a standard order left
open is a sale that never completed.
"""

from django.db import migrations
from django.db.models import F


def backfill(apps, schema_editor):
    Order = apps.get_model("sales", "Order")
    Order.objects.filter(status="paid").update(doc_status="submitted")
    Order.objects.filter(status="void").update(doc_status="cancelled")
    Order.objects.filter(status="open", sale_type__in=["credit", "quotation"]).update(
        doc_status="submitted"
    )
    # A standard order still sitting at ``open`` is the one case where the
    # value means what it says: a checkout that never settled. It stays a draft.
    Order.objects.filter(status="open", sale_type="standard").update(
        doc_status="draft"
    )
    # The quotation-to-sale link is the forward pointer under a different name.
    # One statement, not one per quotation: a shop that has been quoting for
    # years should not pay a round trip each for them during an upgrade.
    Order.objects.filter(converted_to__isnull=False).update(
        superseded_by_id=F("converted_to_id")
    )


def unbackfill(apps, schema_editor):
    """Nothing to undo: the columns this wrote are dropped by the migration
    that added them."""


class Migration(migrations.Migration):
    dependencies = [
        ("sales", "0026_order_amended_from_order_amendment_index_and_more"),
    ]

    operations = [
        migrations.RunPython(backfill, unbackfill),
    ]
