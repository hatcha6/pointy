"""Drive the identified-stock oracle from the command line.

The test suite runs it short and deterministic; this is for running it long
enough to find the thing a hundred operations did not. A failure prints the
operation count and the disagreement, and the seed reproduces it exactly.
"""

from django.core.management.base import BaseCommand

from apps.inventory.tracking_simulation import run_tracked_stock_simulation


class Command(BaseCommand):
    help = "Randomised consistency run over serialized, batch and lot+serial stock."

    def add_arguments(self, parser):
        parser.add_argument("--seed", type=int, default=1)
        parser.add_argument("--operations", type=int, default=500)
        parser.add_argument("--verbose", action="store_true")

    def handle(self, *args, **options):
        simulation = run_tracked_stock_simulation(
            seed=options["seed"],
            operations=options["operations"],
            verbose=options["verbose"],
        )
        self.stdout.write(
            self.style.SUCCESS(
                f"{simulation.operations_run} operations, "
                f"{len(simulation.oracle.units)} units and "
                f"{len(simulation.oracle.lots)} lots — the shop and the model agree."
            )
        )
