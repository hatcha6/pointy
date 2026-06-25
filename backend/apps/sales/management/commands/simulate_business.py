"""Run the randomized business simulation with an independent oracle on demand.

Unlike ``checkout_load`` (a throughput/latency benchmark over HTTP against a
running server), this command runs *in-process* and verifies **correctness**:
it drives a varied stream of real transactions and asserts that every stored
quantity and monetary value exactly matches an independent reference
computation. It is the "big business endurance" companion to the CI-scale
``apps.sales.test_business_simulation`` test.

By default the whole run is wrapped in a transaction that is rolled back at the
end, so it is safe to run against any database without leaving data behind. Pass
``--commit`` to persist (only meaningful against a throwaway database).

Examples::

    python manage.py simulate_business --operations 5000
    python manage.py simulate_business --operations 50000 --seed 7
"""

import time

from django.conf import settings
from django.core.management.base import BaseCommand, CommandError
from django.db import transaction

from apps.sales.business_simulation import SimulationError, run_simulation


class _Rollback(Exception):
    pass


class Command(BaseCommand):
    help = "Run the randomized business simulation and verify the oracle."

    def add_arguments(self, parser):
        parser.add_argument("--operations", type=int, default=2000)
        parser.add_argument(
            "--seed",
            type=int,
            default=None,
            help="RNG seed (defaults to the current time; printed so failures reproduce).",
        )
        parser.add_argument("--checkpoint-every", type=int, default=50)
        parser.add_argument(
            "--commit",
            action="store_true",
            help="Persist the generated data instead of rolling it back.",
        )

    def handle(self, *args, **options):
        seed = options["seed"] if options["seed"] is not None else int(time.time())
        operations = options["operations"]
        checkpoint = options["checkpoint_every"]
        commit = options["commit"]

        # The simulation drives some endpoints through the test API client, whose
        # default host is ``testserver``; the Django test runner allows that
        # automatically but a management command does not, so permit it here.
        if "testserver" not in settings.ALLOWED_HOSTS:
            settings.ALLOWED_HOSTS = [*settings.ALLOWED_HOSTS, "testserver"]

        self.stdout.write(
            f"Business simulation — seed={seed} operations={operations} "
            f"checkpoint_every={checkpoint} commit={commit}"
        )
        started = time.monotonic()
        sim = None
        try:
            try:
                with transaction.atomic():
                    sim = run_simulation(
                        seed=seed,
                        operations=operations,
                        checkpoint_every=checkpoint,
                    )
                    if not commit:
                        raise _Rollback()
            except _Rollback:
                pass
        except SimulationError as exc:
            raise CommandError(f"ORACLE MISMATCH — {exc}")

        elapsed = time.monotonic() - started
        self.stdout.write(
            self.style.SUCCESS(
                f"PASSED — oracle matched the backend on every check "
                f"({operations} ops in {elapsed:.1f}s)."
            )
        )
        self.stdout.write("Operation mix:")
        for name, count in sorted(sim.op_counts.items(), key=lambda kv: -kv[1]):
            self.stdout.write(f"  {name:<28} {count}")
        self.stdout.write(
            f"orders={len(sim.oracle.orders)} "
            f"sessions={len(sim.oracle.sessions)} "
            f"purchase_orders={len(sim.oracle.pos)}"
        )
        if not commit:
            self.stdout.write("Generated data was rolled back (use --commit to keep).")
