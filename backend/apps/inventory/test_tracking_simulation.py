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
