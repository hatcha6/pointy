"""Run the §5.4 invariants against a real shop's database.

``apps/inventory/integrity.py`` has held fourteen runnable checks since Phase A
and, until this command, was imported by the tests and the simulation and by
nothing else — no task, no endpoint, no command. So the invariants had never run
against a shop's actual data, and every defect the Phase A/B review found was
found by calling them by hand from a shell. That is the wrong way round: they are
cheap, they are exact, and they are the only thing that notices when a bin and
the articles under it stop agreeing.

Read-only. It changes nothing, so it is safe to run on a live shop — and safe to
put on a schedule, which is the point:

    python manage.py check_stock_integrity
    python manage.py check_stock_integrity --quiet   # exit code only, for cron
"""

from django.core.management.base import BaseCommand

from apps.inventory.integrity import tracking_invariant_violations


class Command(BaseCommand):
    help = (
        "Check the identified-stock invariants (§5.4). Exits non-zero when any "
        "of them does not hold."
    )

    def add_arguments(self, parser):
        parser.add_argument(
            "--quiet",
            action="store_true",
            help="Print nothing when everything holds; still exits non-zero if not.",
        )

    def handle(self, *args, **options):
        violations = tracking_invariant_violations()
        if not violations:
            if not options["quiet"]:
                self.stdout.write(
                    self.style.SUCCESS(
                        "Identified stock is consistent: all invariants hold."
                    )
                )
            return

        # Written to stderr and as one line each, so a scheduler's mail or a log
        # line carries the whole finding without anybody opening a shell.
        self.stderr.write(
            self.style.ERROR(
                f"{len(violations)} identified-stock invariant(s) do not hold:"
            )
        )
        for violation in violations:
            self.stderr.write(self.style.ERROR(f"  - {violation}"))
        # SystemExit rather than CommandError: this is a finding about the data,
        # not a failure of the command.
        raise SystemExit(1)
