from django.core.management.base import BaseCommand
from django.db import transaction
from django.utils import timezone

from apps.sales.models import Order, StockReservation
from apps.sales.services import release_quote_reservations


class Command(BaseCommand):
    help = (
        "Release stock held by quotations whose validity has expired. The "
        "quotation itself stays visible; only the hold is freed so the units "
        "become sellable again."
    )

    def handle(self, *args, **options):
        today = timezone.localdate()
        expired = (
            Order.objects.quotations()
            .filter(
                reserves_stock=True,
                valid_until__isnull=False,
                valid_until__lt=today,
                stock_reservations__status=StockReservation.Status.ACTIVE,
            )
            .distinct()
        )
        released = 0
        for quotation in expired:
            with transaction.atomic():
                release_quote_reservations(quotation)
            released += 1
        self.stdout.write(
            self.style.SUCCESS(
                f"Released reservations for {released} expired quotation(s)."
            )
        )
