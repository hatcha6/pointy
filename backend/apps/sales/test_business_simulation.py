"""Entry point that runs the model-based business simulation as a test.

The heavy lifting lives in :mod:`apps.sales.business_simulation`. This module
just wires it into the Django test runner at a CI-friendly scale and exposes the
arithmetic self-test as its own fast test.

Scale and reproducibility are controlled by environment variables so the same
test can be cranked up to "big business" volume without code changes::

    # default CI scale
    DATABASE_URL='sqlite://:memory:' python manage.py test \
        apps.sales.test_business_simulation

    # large endurance run on a chosen seed
    SIM_OPERATIONS=20000 SIM_SEED=7 DATABASE_URL='sqlite://:memory:' \
        python manage.py test apps.sales.test_business_simulation
"""

import os

from django.test import TestCase

from apps.sales.business_simulation import run_simulation, self_test_arithmetic


class OracleArithmeticTests(TestCase):
    """Guards the oracle's independent arithmetic port against the documented
    backend behavior, so a port bug fails here (clearly the test's fault) rather
    than deep inside a simulation run."""

    def test_oracle_arithmetic_matches_documented_examples(self):
        self_test_arithmetic()


class BusinessSimulationTests(TestCase):
    def test_randomized_business_simulation(self):
        seed = int(os.environ.get("SIM_SEED", "20240624"))
        operations = int(os.environ.get("SIM_OPERATIONS", "300"))
        checkpoint = int(os.environ.get("SIM_CHECKPOINT", "20"))
        sim = run_simulation(
            seed=seed, operations=operations, checkpoint_every=checkpoint
        )
        # Sanity: the run actually exercised the system, not a degenerate stream.
        self.assertEqual(sum(sim.op_counts.values()), operations)
        self.assertGreaterEqual(len(sim.oracle.orders), 1)
        # At a few hundred ops most operation kinds should have fired at least
        # once; require a healthy spread so the test can't silently degrade into
        # "sales only".
        self.assertGreaterEqual(len(sim.op_counts), 10)
