"""Backfill ``special_day_keys`` on existing sales and purchases.

New sales/purchases are tagged at creation; this command fills the history so
forecasting has the signal on past rows too. It is a management command (not a
data migration) because the tables can hold millions of rows: it streams with
``iterator()`` and writes in batched ``bulk_update`` calls, and is safe to
re-run (idempotent — it only writes when the computed keys differ).

Note: ``fixed`` / ``nth_weekday`` keys resolve for any historical date, but the
moon-based Eids only tag past dates that have been entered on the relay for
those years.
"""

from django.core.management.base import BaseCommand

from apps.documents.guards import system_write
from apps.core.timeutils import business_local_date
from apps.holidays.rules import special_days_for_date
from apps.holidays.services import get_active_definitions


class Command(BaseCommand):
    help = "Backfill special_day_keys on existing sales and purchases from their creation date."

    def add_arguments(self, parser):
        parser.add_argument(
            "--force",
            action="store_true",
            help="Re-tag rows that already carry keys (default: only fill empty rows).",
        )
        parser.add_argument(
            "--batch-size",
            type=int,
            default=1000,
            help="Number of rows per bulk_update (default: 1000).",
        )

    def handle(self, *args, **options):
        from apps.purchasing.models import PurchaseOrder
        from apps.sales.models import Order

        force = options["force"]
        batch_size = max(int(options["batch_size"]), 1)
        definitions = get_active_definitions(force_refresh=True)

        total = 0
        for model, label in ((Order, "sales"), (PurchaseOrder, "purchases")):
            updated = self._backfill(model, label, definitions, force, batch_size)
            total += updated
        self.stdout.write(self.style.SUCCESS(f"Backfilled {total} row(s)."))

    def _backfill(self, model, label, definitions, force, batch_size):
        # The tag is a frozen snapshot on an issued document — deliberately, so
        # a later edit to the holiday calendar cannot rewrite what a sale was
        # tagged with. Backfilling rows that predate the feature is the one
        # exception, and it is a machine writing history rather than a person
        # editing a document. See apps.documents.guards.
        with system_write():
            return self._write_tags(model, label, definitions, force, batch_size)

    def _write_tags(self, model, label, definitions, force, batch_size):
        queryset = model.objects.all().only("id", "created_at", "special_day_keys")
        if not force:
            queryset = queryset.filter(special_day_keys=[])

        batch = []
        updated = 0
        for obj in queryset.iterator(chunk_size=batch_size):
            if obj.created_at is None:
                continue
            keys = [
                occ.key
                for occ in special_days_for_date(
                    business_local_date(obj.created_at), definitions
                )
            ]
            if obj.special_day_keys == keys:
                continue
            obj.special_day_keys = keys
            batch.append(obj)
            if len(batch) >= batch_size:
                model.objects.bulk_update(batch, ["special_day_keys"])
                updated += len(batch)
                batch = []
        if batch:
            model.objects.bulk_update(batch, ["special_day_keys"])
            updated += len(batch)

        self.stdout.write(f"  {label}: {updated} updated")
        return updated
