"""Recompute product "most bought" popularity on demand.

The same work the nightly ``catalog.recompute_product_popularity`` Celery task
runs, exposed as a management command for backfills (e.g. right after the
migration that adds the column), ops one-offs and local testing without a worker.
"""

import json

from django.core.management.base import BaseCommand

from apps.catalog.popularity import recompute_product_popularity


class Command(BaseCommand):
    help = "Recompute every product's rolling-90-day popularity (most-bought) score."

    def handle(self, *args, **options):
        summary = recompute_product_popularity()
        self.stdout.write(self.style.SUCCESS("Product popularity recomputed."))
        self.stdout.write(json.dumps(summary, indent=2, sort_keys=True))
