"""Take the provider top-ups already recorded out of the cash box that paid them.

Until now the float sheet never said where a top-up came from, so the server
wrote each one as money arriving from outside the shop. The float went up, but
the cash box that paid the provider kept the money in الخزينة. The balance
sheet then read every top-up as capital the owner had put in, and the zakat
base counted it twice: once in the cash box and once in the float.

This gives each of those top-ups the source the server now assumes when a
client says nothing: the cash box untagged cash lands in. The row ends up
exactly as if it had been recorded that way. It is data only, and an older
build reads a two-sided transfer as readily as a one-sided one.

Three limits, each on purpose:

* Only the top-ups the float sheet wrote. That means a transfer into a
  provider float, with no source, carrying the sheet's own reason. Somebody who
  picked «خارج المحل» on the treasury screen chose that side, and keeps it.
* Only top-ups on or after the cash box's opening day. The box's opening
  balance is what it held that day, so a top-up paid before it is already out
  of that figure. Taking it out again would count it twice.
* Nothing, when the shop has no active cash box to take it from.

A count taken before this ran keeps the variance it recorded (counts are
snapshots on purpose). The next count reads the corrected balance.
"""

from django.db import migrations
from django.utils import timezone

# A copy of ``float_ledger.TOP_UP_REASON``, frozen here as migrations must be:
# the ledger's wording may change and this must keep finding the old rows.
TOP_UP_REASON = "شحن رصيد وكالة"


def routed_cash_box(MoneyAccount):
    """The active cash box untagged cash lands in, or ``None``.

    The same choice as ``treasury.position._default_account_ids``: the flagged
    default, else the first active box in the shop's own order. Spelled with
    literals because a historical model carries no ``Kind`` choices.
    """
    boxes = list(
        MoneyAccount.objects.filter(kind="cash", is_active=True).order_by(
            "display_order", "name", "pk"
        )
    )
    for box in boxes:
        if box.is_default:
            return box
    return boxes[0] if boxes else None


def take_top_ups_out_of_the_cash_box(apps, schema_editor):
    MoneyAccount = apps.get_model("treasury", "MoneyAccount")
    MoneyTransfer = apps.get_model("treasury", "MoneyTransfer")

    cash = routed_cash_box(MoneyAccount)
    if cash is None:
        return
    MoneyTransfer.objects.filter(
        from_account__isnull=True,
        to_account__kind="provider",
        reason=TOP_UP_REASON,
        moved_at__gte=cash.opening_at,
    ).update(from_account_id=cash.pk, updated_at=timezone.now())


class Migration(migrations.Migration):

    dependencies = [
        ("integrations", "0015_voucher_brand_logo"),
        ("treasury", "0004_moneyaccount_bank_slug_moneyaccount_iban"),
    ]

    operations = [
        # No reverse. The repaired rows are what the sheet should have written,
        # and an older build reads them correctly, so a rollback keeps them.
        migrations.RunPython(
            take_top_ups_out_of_the_cash_box, migrations.RunPython.noop
        ),
    ]
