from django.core.exceptions import ImproperlyConfigured
from django.core.management.base import BaseCommand, CommandError

from apps.core.models import RelayInstallation
from apps.core.relay import (
    RelayControlError,
    relay_ai_available,
    sync_relay_installation,
)


class Command(BaseCommand):
    help = "Pull the relay installation's current entitlement state into Django."

    def handle(self, *args, **options):
        installation = RelayInstallation.load()
        if installation is None:
            raise CommandError(
                "no relay installation found; run `relay_provision` first"
            )
        try:
            sync_relay_installation(installation)
        except (RelayControlError, ImproperlyConfigured) as exc:
            raise CommandError(f"relay sync failed: {exc}") from exc

        installation.refresh_from_db()
        self.stdout.write(
            self.style.SUCCESS(
                f"installation {installation.installation_id}: "
                f"relay_enabled={installation.relay_enabled} "
                f"subscription_active={installation.subscription_active} "
                f"ai_enabled={installation.ai_enabled} "
                f"ai_available={relay_ai_available(installation)}"
            )
        )
