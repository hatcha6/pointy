"""Give every shop the two places its money already goes.

A shop that upgrades into this feature has been trading for months: its cash and
its bank hold real money, and no replay of history would produce a number its
owner recognises (the cost data behind an early sale is exactly what we do not
trust). So both accounts open at zero **today** and count forward from there,
and the owner sets the real opening balance from the treasury screen. That is a
cutover, not a backfill — deliberately.
"""

from django.db import migrations
from django.utils import timezone


def seed_accounts(apps, schema_editor):
    MoneyAccount = apps.get_model("treasury", "MoneyAccount")
    if MoneyAccount.objects.exists():
        return

    today = timezone.localdate()
    MoneyAccount.objects.create(
        name="الخزينة",
        kind="cash",
        opening_balance=0,
        opening_at=today,
        is_default=True,
        display_order=0,
    )
    MoneyAccount.objects.create(
        name="المصرف",
        kind="bank",
        opening_balance=0,
        opening_at=today,
        is_default=True,
        display_order=1,
    )


def unseed_accounts(apps, schema_editor):
    MoneyAccount = apps.get_model("treasury", "MoneyAccount")
    MoneyAccount.objects.filter(
        name__in=["الخزينة", "المصرف"],
        counts__isnull=True,
        transfers_in__isnull=True,
        transfers_out__isnull=True,
    ).delete()


class Migration(migrations.Migration):
    dependencies = [("treasury", "0001_initial")]

    operations = [migrations.RunPython(seed_accounts, unseed_accounts)]
