from django.core.management.base import BaseCommand

from apps.catalog.seed import seed_variant_options


class Command(BaseCommand):
    help = "Seed common Arabic variant options and values."

    def handle(self, *args, **options):
        created = seed_variant_options()
        self.stdout.write(
            self.style.SUCCESS(
                "Seeded variant options "
                f"({created['options']} new options, {created['values']} new values)."
            )
        )
