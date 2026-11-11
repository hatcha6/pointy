"""Take update/install records from the host and track them.

    tail -n +N update-history.jsonl \\
      | docker compose exec -T backend python manage.py record_deployment_runs

One JSON object per line on stdin (``deploy/onprem/update-lib.sh`` writes and
pipes them). A line that is not a record is skipped, not fatal: the host moves
its cursor past everything it piped once this exits 0, and one bad line must
not hold every later run back for good.
"""

import json
import sys

from django.core.management.base import BaseCommand

from apps.analytics.deployment import record_deployment_runs


class Command(BaseCommand):
    help = "Record on-prem update/install runs (JSON lines on stdin) as analytics events."

    def handle(self, *args, **options):
        records = []
        skipped = 0
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                skipped += 1
        stored = record_deployment_runs(records)
        self.stdout.write(
            f"deployment runs: {stored} recorded, {len(records) - stored + skipped} skipped"
        )
