"""Phase D's three new tables, and the lot a count line now names.

``ConsignmentIncident`` is §6.2.2 — the custody record made at the time,
before anybody has decided who is responsible. ``StockCountScan`` is §6.6 —
counting a serialized shelf is a scan loop, and the two lists it produces
are set operations over these rows. ``StockUnitEvent`` is §6.9 — the things
that happen to an article and move no stock, which must not be allocations
because an allocation has to balance and *«who dropped this price»* must
not.

Additive throughout: three new tables and one nullable column. The
constraint swap on ``StockCountLine`` widens what is allowed rather than
narrowing it, so the previous release runs against this schema unchanged
(``zero-downtime-updates``).
"""


import django.db.models.deletion
import django.utils.timezone
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("catalog", "0029_fold_tracks_expiry_into_tracking_mode"),
        ("inventory", "0034_alter_stockledgerentry_voucher_type"),
        ("surveillance", "0003_recorder_max_concurrent_streams"),
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
    ]

    operations = [
        migrations.CreateModel(
            name="ConsignmentIncident",
            fields=[
                (
                    "id",
                    models.BigAutoField(
                        auto_created=True,
                        primary_key=True,
                        serialize=False,
                        verbose_name="ID",
                    ),
                ),
                ("created_at", models.DateTimeField(auto_now_add=True, db_index=True)),
                ("updated_at", models.DateTimeField(auto_now=True)),
                (
                    "doc_status",
                    models.CharField(
                        choices=[
                            ("draft", "Draft"),
                            ("submitted", "Submitted"),
                            ("cancelled", "Cancelled"),
                        ],
                        db_default="draft",
                        db_index=True,
                        default="draft",
                        max_length=16,
                    ),
                ),
                ("submitted_at", models.DateTimeField(blank=True, null=True)),
                ("cancelled_at", models.DateTimeField(blank=True, null=True)),
                ("cancel_reason", models.TextField(blank=True, db_default="")),
                (
                    "amendment_index",
                    models.PositiveSmallIntegerField(db_default=0, default=0),
                ),
                ("number", models.CharField(blank=True, max_length=32, unique=True)),
                (
                    "kind",
                    models.CharField(
                        choices=[
                            ("damaged", "تلف"),
                            ("lost", "فقدان"),
                            ("stolen", "سرقة"),
                            ("destroyed", "إتلاف كامل"),
                            ("dispute", "خلاف على الحالة"),
                        ],
                        max_length=16,
                    ),
                ),
                ("occurred_on", models.DateField(blank=True, null=True)),
                (
                    "discovered_at",
                    models.DateTimeField(default=django.utils.timezone.now),
                ),
                ("narrative", models.TextField()),
                (
                    "responsibility",
                    models.CharField(
                        choices=[
                            ("shop", "المحل"),
                            ("consignor", "صاحب الأمانة"),
                            ("third_party", "طرف ثالث"),
                            ("force_majeure", "ظرف قاهر"),
                            ("undetermined", "غير محدد"),
                        ],
                        default="undetermined",
                        max_length=16,
                    ),
                ),
                (
                    "assessed_value",
                    models.DecimalField(decimal_places=2, default=0, max_digits=10),
                ),
                ("is_assessed", models.BooleanField(default=False)),
                (
                    "resolution",
                    models.CharField(
                        choices=[
                            ("pending", "قيد التسوية"),
                            ("paid", "سُدّد نقداً"),
                            ("replaced", "استُبدل"),
                            ("waived", "تنازل صاحبها"),
                            ("insured", "غطّاه التأمين"),
                            ("no_claim", "لا مطالبة"),
                        ],
                        default="pending",
                        max_length=16,
                    ),
                ),
                ("resolved_at", models.DateTimeField(blank=True, null=True)),
                ("settlement_ref", models.CharField(blank=True, max_length=64)),
            ],
            options={
                "ordering": ["-discovered_at", "-id"],
                "permissions": [
                    (
                        "manage_consignmentincident",
                        "Can record and assess consignment custody incidents",
                    )
                ],
            },
        ),
        migrations.CreateModel(
            name="StockCountScan",
            fields=[
                (
                    "id",
                    models.BigAutoField(
                        auto_created=True,
                        primary_key=True,
                        serialize=False,
                        verbose_name="ID",
                    ),
                ),
                ("created_at", models.DateTimeField(auto_now_add=True, db_index=True)),
                ("updated_at", models.DateTimeField(auto_now=True)),
                ("code", models.CharField(max_length=120)),
                (
                    "code_normalized",
                    models.CharField(db_index=True, editable=False, max_length=120),
                ),
                ("found_elsewhere", models.BooleanField(default=False)),
                ("scanned_at", models.DateTimeField(default=django.utils.timezone.now)),
            ],
            options={
                "ordering": ["-scanned_at", "-id"],
            },
        ),
        migrations.CreateModel(
            name="StockUnitEvent",
            fields=[
                (
                    "id",
                    models.BigAutoField(
                        auto_created=True,
                        primary_key=True,
                        serialize=False,
                        verbose_name="ID",
                    ),
                ),
                ("created_at", models.DateTimeField(auto_now_add=True, db_index=True)),
                ("updated_at", models.DateTimeField(auto_now=True)),
                (
                    "kind",
                    models.CharField(
                        choices=[
                            ("repriced", "تغيير السعر"),
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
                (
                    "at",
                    models.DateTimeField(
                        db_index=True, default=django.utils.timezone.now
                    ),
                ),
                ("from_value", models.CharField(blank=True, max_length=240)),
                ("to_value", models.CharField(blank=True, max_length=240)),
                ("note", models.CharField(blank=True, max_length=240)),
                ("reference_type", models.CharField(blank=True, max_length=32)),
                ("reference_id", models.PositiveBigIntegerField(blank=True, null=True)),
            ],
            options={
                "ordering": ["-at", "-id"],
            },
        ),
        migrations.RemoveConstraint(
            model_name="stockcountline",
            name="unique_variant_per_stock_count",
        ),
        migrations.AddField(
            model_name="stockcountline",
            name="batch",
            field=models.ForeignKey(
                blank=True,
                null=True,
                on_delete=django.db.models.deletion.PROTECT,
                related_name="stock_count_lines",
                to="inventory.stockbatch",
            ),
        ),
        migrations.AddConstraint(
            model_name="stockcountline",
            constraint=models.UniqueConstraint(
                condition=models.Q(("batch__isnull", True)),
                fields=("stock_count", "variant"),
                name="unique_variant_per_stock_count",
            ),
        ),
        migrations.AddConstraint(
            model_name="stockcountline",
            constraint=models.UniqueConstraint(
                condition=models.Q(("batch__isnull", False)),
                fields=("stock_count", "variant", "batch"),
                name="unique_lot_line_per_stock_count",
            ),
        ),
        migrations.AddField(
            model_name="consignmentincident",
            name="agreement",
            field=models.ForeignKey(
                on_delete=django.db.models.deletion.PROTECT,
                related_name="incidents",
                to="inventory.consignmentagreement",
            ),
        ),
        migrations.AddField(
            model_name="consignmentincident",
            name="amended_from",
            field=models.ForeignKey(
                blank=True,
                null=True,
                on_delete=django.db.models.deletion.SET_NULL,
                related_name="%(app_label)s_%(class)s_amendments",
                to="inventory.consignmentincident",
            ),
        ),
        migrations.AddField(
            model_name="consignmentincident",
            name="camera",
            field=models.ForeignKey(
                blank=True,
                null=True,
                on_delete=django.db.models.deletion.SET_NULL,
                related_name="consignment_incidents",
                to="surveillance.camera",
            ),
        ),
        migrations.AddField(
            model_name="consignmentincident",
            name="cancelled_by",
            field=models.ForeignKey(
                blank=True,
                null=True,
                on_delete=django.db.models.deletion.SET_NULL,
                related_name="%(app_label)s_%(class)s_cancelled",
                to=settings.AUTH_USER_MODEL,
            ),
        ),
        migrations.AddField(
            model_name="consignmentincident",
            name="created_by",
            field=models.ForeignKey(
                blank=True,
                null=True,
                on_delete=django.db.models.deletion.SET_NULL,
                related_name="consignment_incidents",
                to=settings.AUTH_USER_MODEL,
            ),
        ),
        migrations.AddField(
            model_name="consignmentincident",
            name="replacement_unit",
            field=models.ForeignKey(
                blank=True,
                null=True,
                on_delete=django.db.models.deletion.SET_NULL,
                related_name="replaced_incidents",
                to="inventory.stockunit",
            ),
        ),
        migrations.AddField(
            model_name="consignmentincident",
            name="reported_by",
            field=models.ForeignKey(
                blank=True,
                null=True,
                on_delete=django.db.models.deletion.PROTECT,
                related_name="reported_consignment_incidents",
                to=settings.AUTH_USER_MODEL,
            ),
        ),
        migrations.AddField(
            model_name="consignmentincident",
            name="settlement_payout",
            field=models.ForeignKey(
                blank=True,
                null=True,
                on_delete=django.db.models.deletion.SET_NULL,
                related_name="settled_incidents",
                to="inventory.consignorpayout",
            ),
        ),
        migrations.AddField(
            model_name="consignmentincident",
            name="submitted_by",
            field=models.ForeignKey(
                blank=True,
                null=True,
                on_delete=django.db.models.deletion.SET_NULL,
                related_name="%(app_label)s_%(class)s_submitted",
                to=settings.AUTH_USER_MODEL,
            ),
        ),
        migrations.AddField(
            model_name="consignmentincident",
            name="superseded_by",
            field=models.ForeignKey(
                blank=True,
                null=True,
                on_delete=django.db.models.deletion.SET_NULL,
                related_name="%(app_label)s_%(class)s_supersedes",
                to="inventory.consignmentincident",
            ),
        ),
        migrations.AddField(
            model_name="consignmentincident",
            name="unit",
            field=models.ForeignKey(
                on_delete=django.db.models.deletion.PROTECT,
                related_name="incidents",
                to="inventory.stockunit",
            ),
        ),
        migrations.AddField(
            model_name="stockcountscan",
            name="line",
            field=models.ForeignKey(
                blank=True,
                null=True,
                on_delete=django.db.models.deletion.CASCADE,
                related_name="scans",
                to="inventory.stockcountline",
            ),
        ),
        migrations.AddField(
            model_name="stockcountscan",
            name="scanned_by",
            field=models.ForeignKey(
                blank=True,
                null=True,
                on_delete=django.db.models.deletion.SET_NULL,
                related_name="stock_count_scans",
                to=settings.AUTH_USER_MODEL,
            ),
        ),
        migrations.AddField(
            model_name="stockcountscan",
            name="stock_count",
            field=models.ForeignKey(
                on_delete=django.db.models.deletion.CASCADE,
                related_name="scans",
                to="inventory.stockcount",
            ),
        ),
        migrations.AddField(
            model_name="stockcountscan",
            name="unit",
            field=models.ForeignKey(
                blank=True,
                null=True,
                on_delete=django.db.models.deletion.PROTECT,
                related_name="stock_count_scans",
                to="inventory.stockunit",
            ),
        ),
        migrations.AddField(
            model_name="stockcountscan",
            name="variant",
            field=models.ForeignKey(
                blank=True,
                null=True,
                on_delete=django.db.models.deletion.PROTECT,
                related_name="stock_count_scans",
                to="catalog.productvariant",
            ),
        ),
        migrations.AddField(
            model_name="stockunitevent",
            name="actor",
            field=models.ForeignKey(
                blank=True,
                null=True,
                on_delete=django.db.models.deletion.SET_NULL,
                related_name="stock_unit_events",
                to=settings.AUTH_USER_MODEL,
            ),
        ),
        migrations.AddField(
            model_name="stockunitevent",
            name="unit",
            field=models.ForeignKey(
                on_delete=django.db.models.deletion.CASCADE,
                related_name="events",
                to="inventory.stockunit",
            ),
        ),
        migrations.AddIndex(
            model_name="consignmentincident",
            index=models.Index(
                fields=["resolution", "-discovered_at"], name="incident_open_idx"
            ),
        ),
        migrations.AddIndex(
            model_name="consignmentincident",
            index=models.Index(
                fields=["agreement", "-discovered_at"], name="incident_agree_idx"
            ),
        ),
        migrations.AddIndex(
            model_name="stockcountscan",
            index=models.Index(
                fields=["stock_count", "variant"], name="scan_count_var_idx"
            ),
        ),
        migrations.AddConstraint(
            model_name="stockcountscan",
            constraint=models.UniqueConstraint(
                fields=("stock_count", "code_normalized"),
                name="unique_scan_per_stock_count",
            ),
        ),
        migrations.AddIndex(
            model_name="stockunitevent",
            index=models.Index(fields=["unit", "-at"], name="unit_event_time_idx"),
        ),
    ]
