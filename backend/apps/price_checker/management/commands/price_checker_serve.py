from django.core.management.base import BaseCommand

from apps.price_checker.daemon import serve


class Command(BaseCommand):
    help = "Run the price-checker socket daemon (TCP/UDP) in the foreground."

    def handle(self, *args, **options):
        self.stdout.write(self.style.SUCCESS("Starting price-checker socket daemon…"))
        serve()
