"""What the shop has already handed a consignor for an article it holds again.

§15.3's last open edge. A paid-out consignment that comes back and re-sells
under a **commission** agreement at a different second price lost the
difference in both directions at once: the re-sale overwrote ``incoming_rate``
(destroying the receivable) and ``consignor_paid_at`` stayed stamped (so no
new payable opened). Under a fixed payout the two happened to cancel, which is
why it survived a phase.

Additive and defaulted, so the previous release runs against this schema
unchanged. The backfill converts the inference that is in the data today —
"paid, and back on the shelf" — into the explicit figure, which is exactly the
number those rows already meant.
"""


from django.db import migrations, models


def _backfill(apps, schema_editor):
    """Every reopened consignment currently carrying its old payout.

    ``incoming_rate`` on a paid-out consignment that is back on the shelf
    *is* the advance — that is what the column has meant since Phase C's
    reopen landed. Moving it says so, and clearing the stamp lets the next
    sale open a real payable instead of being silently swallowed.
    """
    StockUnit = apps.get_model("inventory", "StockUnit")
    rows = list(
        StockUnit.objects.filter(
            is_consignment=True,
            consignor_payout__isnull=False,
            status__in=("in_stock", "reserved"),
            incoming_rate__gt=0,
        )
    )
    for unit in rows:
        unit.consignor_advance = unit.incoming_rate
        unit.incoming_rate = 0
        unit.consignor_paid_at = None
    if rows:
        StockUnit.objects.bulk_update(
            rows,
            ["consignor_advance", "incoming_rate", "consignor_paid_at"],
            batch_size=500,
        )


class Migration(migrations.Migration):

    dependencies = [
        ("inventory", "0035_phase_d_custody_and_counting"),
    ]

    operations = [
        migrations.AddField(
            model_name="stockunit",
            name="consignor_advance",
            field=models.DecimalField(decimal_places=2, default=0, max_digits=10),
        ),
        migrations.AlterField(
            model_name="stockunitevent",
            name="kind",
            field=models.CharField(
                choices=[
                    ("repriced", "تغيير السعر"),
                    ("advance_opened", "تحويل مستحق إلى دفعة مقدّمة"),
                    ("advance_settled", "تسوية دفعة مقدّمة"),
                    ("identified", "إدخال المعرّف"),
                    ("identifier_corrected", "تصحيح المعرّف"),
                    ("attributes_edited", "تعديل الخصائص"),
                    ("refurb_cost", "تكلفة تجديد"),
                    ("written_off", "شطب"),
                    ("note", "ملاحظة"),
                    ("incident", "حادث عهدة"),
                    ("counted", "جرد"),
                    ("relocated", "نقل مكان"),
                ],
                max_length=24,
            ),
        ),
        migrations.RunPython(_backfill, migrations.RunPython.noop),
    ]
