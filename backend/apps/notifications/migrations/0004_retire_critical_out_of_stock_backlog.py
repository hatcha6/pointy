"""Clear the out-of-stock alert backlog left by the pre-guard generator.

Before the inventory guards landed, every stock item at or below zero raised its
own ``inventory.out_of_stock`` alert at CRITICAL severity. A shop that never
counted its opening stock in drifts every tracked item negative, so one field
shop accumulated 11,884 of these — 88% of every notification it had ever raised,
all critical, and only 11% ever acknowledged. The register-variance and fraud
alerts underneath were never seen.

``sync_business_notifications`` would eventually fix this on its own: it
refreshes severity on existing rows and resolves any active alert the generator
no longer asks for. But that sync runs on a Celery beat (and throttled inline on
reads), so on a shop where beat is not running the backlog would sit there
lighting up the notification centre after the upgrade. Do it at migrate time
instead, so the first screen after the update is already clean.

Data only, no schema change — safe under the live expand/contract update flow.
"""

from django.db import migrations
from django.utils import timezone


def retire_backlog(apps, schema_editor):
    BusinessNotification = apps.get_model("notifications", "BusinessNotification")
    StockItem = apps.get_model("inventory", "StockItem")

    # Out-of-stock is a WARNING now: an empty shelf is a normal trading
    # condition. Applied to resolved rows too, so history reads consistently.
    BusinessNotification.objects.filter(
        code="inventory.out_of_stock",
        severity="critical",
    ).update(severity="warning")

    # Resolve the active alerts the new generator will never raise again: the
    # ones sitting on an impossible (negative) position. Those are covered by
    # the single ``inventory.position_untrusted`` roll-up from now on. Genuine
    # zero-quantity alerts are left active — they are still true, and the next
    # sync re-states them at the corrected severity.
    negative_variant_ids = StockItem.objects.filter(
        quantity_on_hand__lt=0,
    ).values_list("variant_id", flat=True)

    now = timezone.now()
    # entity_id is a CharField holding the variant pk, so compare as text.
    stale = BusinessNotification.objects.filter(
        code="inventory.out_of_stock",
        status="active",
        entity_type="catalog.productvariant",
        entity_id__in=[str(pk) for pk in negative_variant_ids],
    )
    stale.update(status="resolved", resolved_at=now, last_seen_at=now)


def noop(apps, schema_editor):
    """Deliberately not reversed.

    Reversing would mean re-raising thousands of critical alerts about a stock
    position we now know cannot be believed. Rolling the code back is enough:
    the old generator re-creates whatever it still considers true.
    """


class Migration(migrations.Migration):

    dependencies = [
        ("notifications", "0003_alter_businessnotification_created_at_and_more"),
        ("inventory", "0001_initial"),
    ]

    operations = [
        migrations.RunPython(retire_backlog, noop),
    ]
