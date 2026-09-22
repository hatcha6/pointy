from django.core.exceptions import ImproperlyConfigured
from django.core.management.base import BaseCommand, CommandError

from apps.core.models import RelayInstallation
from apps.core.relay import RelayControlError, change_relay_license


class Command(BaseCommand):
    help = (
        "Re-license this installation with a different license key, for when the "
        "wrong one was redeemed. The new key is redeemed with the relay first, and "
        "nothing changes unless the relay accepts it. On an on-prem server use "
        "change-license.sh instead: it runs this, then records the key in .env and "
        "resets the relay connector."
    )

    def add_arguments(self, parser):
        parser.add_argument("license_key", help="The new single-use license key.")
        parser.add_argument(
            "--no-input",
            "--noinput",
            action="store_false",
            dest="interactive",
            help="Do not ask for confirmation.",
        )

    def handle(self, *args, **options):
        if options["interactive"] and not self._confirmed(RelayInstallation.load()):
            raise CommandError("Cancelled. Nothing was changed.")
        try:
            installation, previous_id = change_relay_license(options["license_key"])
        except RelayControlError as exc:
            raise CommandError(_refusal(exc)) from exc
        except ImproperlyConfigured as exc:
            raise CommandError(f"{str(exc).rstrip('.')}. Nothing was changed.") from exc

        new_id = installation.installation_id
        if previous_id:
            self.stdout.write(
                self.style.SUCCESS(f"Switched to installation {new_id} (was {previous_id}).")
            )
        else:
            self.stdout.write(self.style.SUCCESS(f"Licensed as installation {new_id}."))
        self.stdout.write(f"Subscription: {_subscription_summary(installation)}")
        self.stdout.write(
            "\nStill to do on this server; change-license.sh does both:\n"
            "  - Put the new key in .env as POINTY_RELAY_ENROLLMENT_TOKEN.\n"
            f"  - Reset the relay connector's saved state so it connects as {new_id}."
        )
        if previous_id:
            self.stdout.write(
                "On the relay, retire the old installation:\n"
                f"  pointy-relay subscription disable {previous_id} "
                f'--reason "wrong license key; replaced by {new_id}"'
            )

    def _confirmed(self, current):
        if current is None:
            self.stdout.write("This server is not licensed yet.")
        else:
            self.stdout.write(
                f"This server is licensed as installation {current.installation_id}. "
                "It will switch to the new installation the key creates."
            )
        self.stdout.write("A key is single-use: once redeemed it can license nothing else.")
        try:
            answer = self._ask("Type 'yes' to continue, or 'no' to cancel: ")
        except EOFError:
            return False
        return answer.strip().lower() == "yes"

    def _ask(self, prompt):
        # A method of its own so a test can answer for the operator. Patching
        # builtins.input never reaches the shipped build: Cython binds a module's
        # builtins once, when it is imported.
        return input(prompt)


def _refusal(exc):
    # The relay answers every bad key alike on purpose, so a guess learns nothing.
    if exc.status_code == 401:
        return (
            "The relay rejected the key: it is mistyped, already used, or expired. "
            "Nothing was changed."
        )
    if exc.status_code is None:
        # No usable answer: the connection may have dropped after the relay took
        # the key, and then a retry is told the key is already used.
        return (
            f"No usable answer came back from the relay ({exc}). Nothing was changed "
            "on this server, but if the key reached the relay it may be spent: the "
            "newest entry in `pointy-relay installations list` would be the "
            "installation it made."
        )
    return f"The key could not be redeemed ({exc}). Nothing was changed."


def _subscription_summary(installation):
    if not installation.subscription_active:
        return "not active"
    ends = installation.subscription_ends_at
    until = f"until {ends:%Y-%m-%d}" if ends else "with no end date"
    remote = "on" if installation.relay_enabled else "off"
    ai = "on" if installation.ai_enabled else "off"
    return f"active {until} (remote access {remote}, AI {ai})"
