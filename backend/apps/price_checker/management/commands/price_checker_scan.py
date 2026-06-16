import json

from django.core.management.base import BaseCommand

from apps.price_checker.discovery import run_discovery_scan


class Command(BaseCommand):
    help = "Scan the local network for price-checker devices and register them."

    def handle(self, *args, **options):
        summary = run_discovery_scan()
        self.stdout.write(json.dumps(summary, indent=2))
