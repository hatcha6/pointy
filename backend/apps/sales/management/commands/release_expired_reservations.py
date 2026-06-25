from django.core.management.base import BaseCommand

from apps.sales.services import release_expired_quote_reservations


class Command(BaseCommand):
    help = (
        "Release stock held by quotations whose validity has expired. The "
        "quotation itself stays visible; only the hold is freed so the units "
        "become sellable again. This runs automatically on a daily Celery beat "
        "schedule; the command is kept for manual/one-off invocation."
    )

    def handle(self, *args, **options):
        released = release_expired_quote_reservations()
        self.stdout.write(
            self.style.SUCCESS(
                f"Released reservations for {released} expired quotation(s)."
            )
        )
