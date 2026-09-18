"""The identified-stock oracle, run as a test.

Deterministic seeds so a failure is reproducible, and short runs so the suite
stays fast. Drive it harder from the command line when something is suspected::

    python manage.py simulate_tracked_stock --seed 99 --operations 1000
"""

from django.test import TestCase

from .tracking_simulation import run_tracked_stock_simulation


class TrackedStockSimulationTests(TestCase):
    def test_a_hundred_operations_across_all_four_modes_stay_consistent(self):
        simulation = run_tracked_stock_simulation(seed=7, operations=100)
        self.assertEqual(simulation.operations_run, 100)

    def test_a_second_seed_finds_a_different_order_of_events(self):
        simulation = run_tracked_stock_simulation(seed=31, operations=100)
        self.assertEqual(simulation.operations_run, 100)

    def test_the_run_actually_exercised_consignment(self):
        """A weighted operation that never fires proves nothing.

        Consignment is the part of this model where the shop and the oracle are
        most easily made to agree by accident — both would say "worth nothing"
        about goods that were never taken in — so the run is asserted to have
        actually held some.
        """
        from .models import StockUnit

        simulation = run_tracked_stock_simulation(seed=7, operations=100)
        self.assertGreater(
            StockUnit.objects.filter(is_consignment=True).count(),
            0,
            "the simulation never took anything in on consignment",
        )
        self.assertGreater(
            StockUnit.objects.filter(
                is_consignment=True, status=StockUnit.Status.SOLD
            ).count(),
            0,
            "the simulation never sold a consignment, so the payout that "
            "becomes a cost was never checked",
        )
        self.assertEqual(simulation.operations_run, 100)
