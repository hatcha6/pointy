"""Rebuild inventory valuation from the stock ledger.

The answer to three situations: a correction posted out of order, a change of
valuation method, and simple doubt about whether the cached bins still match
history. Replaying is cheap and safe because the ledger is append-only — the
quantities and the costs that were paid do not change, only what the chosen
method makes of them.
"""

from django.core.management.base import BaseCommand
from django.db.models import Count

from apps.inventory.models import StockLedgerEntry, Warehouse
from apps.inventory.valuation_service import current_method, repost_variant


class Command(BaseCommand):
    help = "Replay the stock ledger to rebuild valuation bins and entry costs."

    def add_arguments(self, parser):
        parser.add_argument(
            "--variant",
            type=int,
            action="append",
            dest="variants",
            help="Repost only this variant (repeatable). Default: every variant.",
        )
        parser.add_argument(
            "--method",
            help="Repost as if this method were in force. Default: the shop's.",
        )
        parser.add_argument(
            "--dry-run",
            action="store_true",
            help="Report what would be reposted without writing anything.",
        )

    def handle(self, *args, **options):
        method = options.get("method") or current_method()
        warehouse_id = Warehouse.default_id()
        variants = options.get("variants")

        if variants:
            targets = list(variants)
        else:
            targets = list(
                StockLedgerEntry.objects.filter(warehouse_id=warehouse_id)
                .values_list("variant_id", flat=True)
                .annotate(entries=Count("id"))
                .order_by("variant_id")
                .distinct()
            )

        if options["dry_run"]:
            self.stdout.write(
                f"Would repost {len(targets)} variant(s) as '{method}'."
            )
            return

        total_entries = 0
        for variant_id in targets:
            total_entries += repost_variant(
                variant_id,
                warehouse_id=warehouse_id,
                method=method,
            )

        self.stdout.write(
            self.style.SUCCESS(
                f"Reposted {len(targets)} variant(s), "
                f"{total_entries} ledger entries, as '{method}'."
            )
        )
