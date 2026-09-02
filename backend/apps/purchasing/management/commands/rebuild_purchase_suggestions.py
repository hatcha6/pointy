"""Rebuild the purchase-suggestion tables by hand.

The nightly Celery task does this on its own; this exists so a shop that just
imported years of history (or an engineer checking why a strip is empty) can
build the tables now and see what came out.
"""

from django.core.management.base import BaseCommand

from apps.purchasing import suggestions
from apps.purchasing.models import Supplier


class Command(BaseCommand):
    help = "Rebuild purchase-suggestion habits and affinities from order history."

    def add_arguments(self, parser):
        parser.add_argument(
            "--supplier",
            type=int,
            default=None,
            help="Rebuild only this supplier (default: every supplier, plus prune).",
        )
        parser.add_argument(
            "--window-days",
            type=int,
            default=suggestions.WINDOW_DAYS,
            help=f"Evidence window in days (default {suggestions.WINDOW_DAYS}).",
        )

    def handle(self, *args, **options):
        supplier_id = options["supplier"]
        window_days = options["window_days"]

        if supplier_id is not None:
            if not Supplier.objects.filter(pk=supplier_id).exists():
                self.stderr.write(self.style.ERROR(f"No supplier {supplier_id}."))
                return
            result = suggestions.rebuild_supplier_suggestions(
                supplier_id, window_days=window_days
            )
            self.stdout.write(
                self.style.SUCCESS(
                    "supplier {supplier_id}: {orders} orders → "
                    "{habits} habits, {affinities} affinity pairs "
                    "(version {version})".format(**result)
                )
            )
            return

        result = suggestions.rebuild_purchase_suggestions(window_days=window_days)
        self.stdout.write(
            self.style.SUCCESS(
                "{suppliers} suppliers → {habits} habits, {affinities} affinity "
                "pairs; {pruned} stale rows removed".format(**result)
            )
        )
