"""Unclaimed-payout reminders (§6.2.2, §10): one row per article, sale and round.

A new table and nothing else, so the previous release runs against this schema
unchanged during the live-update flip minute — it neither reads nor writes it.
"""

import django.db.models.deletion
import django.utils.timezone
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("customers", "0012_paymentcard_cardholder_name"),
        ("inventory", "0039_stockbatch_quarantine_stamp"),
        ("messaging", "0004_messaginggateway_auto_messages"),
    ]

    operations = [
        migrations.CreateModel(
            name="ConsignmentPayoutReminder",
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
                ("sold_at", models.DateTimeField()),
                ("round", models.PositiveSmallIntegerField()),
                ("days_waiting", models.PositiveIntegerField(default=0)),
                (
                    "amount",
                    models.DecimalField(decimal_places=2, default=0, max_digits=12),
                ),
                ("sent_at", models.DateTimeField(default=django.utils.timezone.now)),
                (
                    "consignor",
                    models.ForeignKey(
                        blank=True,
                        null=True,
                        on_delete=django.db.models.deletion.SET_NULL,
                        related_name="consignment_payout_reminders",
                        to="customers.customer",
                    ),
                ),
                (
                    "message",
                    models.ForeignKey(
                        blank=True,
                        null=True,
                        on_delete=django.db.models.deletion.SET_NULL,
                        related_name="+",
                        to="messaging.outboundmessage",
                    ),
                ),
                (
                    "unit",
                    models.ForeignKey(
                        on_delete=django.db.models.deletion.CASCADE,
                        related_name="payout_reminders",
                        to="inventory.stockunit",
                    ),
                ),
            ],
            options={
                "ordering": ["-sent_at", "-id"],
                "indexes": [
                    models.Index(
                        fields=["unit", "-sent_at"], name="consign_reminder_unit_idx"
                    ),
                    models.Index(
                        fields=["consignor", "-sent_at"],
                        name="consign_reminder_party_idx",
                    ),
                ],
                "constraints": [
                    models.UniqueConstraint(
                        fields=("unit", "sold_at", "round"),
                        name="consign_reminder_once_per_round",
                    )
                ],
            },
        ),
    ]
