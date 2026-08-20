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
        # The cost-basis assertions must have had something to bite on: a sale
        # of a never-purchased variant snapshots 0.00, and 0.00 agrees with
        # every broken implementation too. Require lines with a real cost, and
        # some sold in a non-base unit, where the purchase's per-piece cost has
        # to be scaled into the unit the sale transacted in.
        self.assertGreaterEqual(sim.costed_line_assertions, 1)
        self.assertGreaterEqual(sim.multi_unit_costed_line_assertions, 1)
        # Same rule for supplier returns. The credit for a line returned whole
        # is right under every implementation of the per-unit share, so a run
        # that only ever returned whole lines — or never returned part of an
        # over-shipped one — has not tested the share at all.
        self.assertGreaterEqual(sim.returned_line_assertions, 1)
        self.assertGreaterEqual(sim.over_received_return_assertions, 1)


class SimulationIgnoresPreExistingDataTests(TestCase):
    """The run's assertions must describe the run, not the database it ran on.

    ``simulate_business`` is documented as safe against any database, and the
    high-volume Postgres runs use a dev database that already holds data. A
    conservation identity that summed *every* payment row read that pre-existing
    data as the run's own and reported a mismatch that was not one.
    """

    def test_payment_identity_ignores_payments_the_run_did_not_create(self):
        from decimal import Decimal

        from apps.payments.models import Payment
        from apps.sales.models import Order

        sim = run_simulation(seed=13, operations=40, checkpoint_every=20)

        stray = Order.objects.create()
        Payment.objects.create(
            order=stray, method=Payment.Method.CASH, amount=Decimal("777.00")
        )

        sim.reconcile_identities()  # must not see the stray 777.00
