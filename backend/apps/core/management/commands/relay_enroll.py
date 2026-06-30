from django.core.exceptions import ImproperlyConfigured
from django.core.management.base import BaseCommand, CommandError

from apps.core.models import RelayInstallation
from apps.core.relay import RelayControlError, ensure_relay_installation


class Command(BaseCommand):
    help = (
        "License this installation. If not already enrolled, redeem the configured "
        "license key (POINTY_RELAY_ENROLLMENT_TOKEN) with the relay and persist the "
        "returned scoped credentials. Idempotent: a no-op once licensed."
    )

    def handle(self, *args, **options):
        if RelayInstallation.load() is not None:
            self.stdout.write("Already licensed.")
            return
        try:
            installation, created = ensure_relay_installation()
        except (ImproperlyConfigured, RelayControlError) as exc:
            raise CommandError(f"enrollment failed: {exc}") from exc
        verb = "Enrolled new" if created else "Reusing existing"
        self.stdout.write(f"{verb} installation {installation.installation_id}.")
