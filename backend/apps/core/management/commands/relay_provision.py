from django.core.exceptions import ImproperlyConfigured
from django.core.management.base import BaseCommand, CommandError

from apps.core.relay import RelayControlError, ensure_relay_installation


class Command(BaseCommand):
    help = (
        "Provision (or reuse) the local relay installation and print its id. "
        "Requires the relay server to be reachable and the POINTY_RELAY_* "
        "control settings to be configured."
    )

    def handle(self, *args, **options):
        try:
            installation, created = ensure_relay_installation()
        except (RelayControlError, ImproperlyConfigured) as exc:
            raise CommandError(f"relay provisioning failed: {exc}") from exc

        verb = "Provisioned new" if created else "Reusing existing"
        self.stderr.write(
            self.style.SUCCESS(f"{verb} relay installation {installation.installation_id}")
        )
        # The installation id on stdout (last line) is machine-readable for scripts.
        self.stdout.write(installation.installation_id)
