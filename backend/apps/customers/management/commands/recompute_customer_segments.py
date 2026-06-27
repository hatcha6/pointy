"""Recompute RFM customer segments on demand.

The same work the nightly ``customers.recompute_customer_segments`` Celery task
runs, exposed as a management command for backfills, ops one-offs and local
testing without a worker.
"""

import json

from django.core.management.base import BaseCommand

from apps.customers.segmentation import recompute_customer_segments


class Command(BaseCommand):
    help = "Recompute every customer's RFM rank (recency / frequency / monetary)."

    def handle(self, *args, **options):
        summary = recompute_customer_segments()
        self.stdout.write(self.style.SUCCESS("Customer segments recomputed."))
        self.stdout.write(json.dumps(summary, indent=2, sort_keys=True))
