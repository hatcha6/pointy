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
        # And for the purchasing side's pack↔base crossing. Every factor used
        # to be 1, where a dropped conversion is the identity: a run that never
        # bought by the carton says nothing about receipts, expected stock, the
        # per-base cost basis or the landed-cost weights. The mixed-unit guard
        # is the sharper one — an allocation is scale-invariant, so a weight
        # that forgot to convert only misallocates on an order whose lines are
        # bought in different units.
        self.assertGreaterEqual(sim.pack_purchase_line_assertions, 1)
        self.assertGreaterEqual(sim.mixed_unit_retail_landed_orders, 1)
        # And for the sales refund document. ``returned_cost_total`` is the one
        # figure on it that no revenue assertion can reach, and it is 0.00 both
        # for a refund of never-purchased goods and for every implementation
        # that gets the reversal wrong — so a run whose refunds all cost nothing
        # has not tested it. The multi-unit guard is the sharper one: at unit
        # factor 1 the pack↔base scaling in the reversal is the identity.
        self.assertGreaterEqual(sim.costed_refund_assertions, 1)
        self.assertGreaterEqual(sim.multi_unit_costed_refund_assertions, 1)
        # And for the document lifecycle's round trip: retracting a document
        # has to leave the shop exactly where it was before the document
        # existed. The three are counted separately because they land on
        # different figures — drawer cash, a payable that several separate
        # queries compute, and stock quantity *and* value — and a sum that
        # forgot to skip a retracted row reads identically to one that never
        # learned to until a month is closed against it.
        self.assertGreaterEqual(sim.expense_retraction_assertions, 1)
        self.assertGreaterEqual(sim.supplier_payment_retraction_assertions, 1)
        self.assertGreaterEqual(sim.stock_count_retraction_assertions, 1)
        # And for a customer's payment given back, whose one action has four
        # outcomes that land on different figures: a credit invoice owed again
        # (the customer's account), a cash sale refusing to be left unpaid and
        # a payment refusing to be handed back twice (nothing may move), and a
        # payment moved to another tender (the drawers, not the sale).
        self.assertGreaterEqual(sim.customer_payment_cancel_assertions, 1)
        self.assertGreaterEqual(sim.cash_sale_cancel_refusals, 1)
        self.assertGreaterEqual(sim.given_back_refusals, 1)
        self.assertGreaterEqual(sim.payment_replacement_assertions, 1)
        # And for the cap that keeps a line's discount inside the line's own
        # rounding regime. The engine's cap and the order line's subtotal agree
        # everywhere except on a line the discounts consumed ENTIRELY whose
        # gross lands on a half-cent — so a run that never rang that up would
        # pass with or without the cap, and prove nothing either way.
        self.assertGreaterEqual(sim.fully_discounted_line_assertions, 1)
        self.assertGreaterEqual(sim.half_cent_fully_discounted_lines, 1)
        # And for the shop-wide P&L. The aggregate figures are only evidence for
        # the property that matters — an order handed back in full contributes
        # exactly nothing to reported profit — and that identity holds under
        # every implementation unless some line's gross or cost carries more
        # precision than the cent the line stores. A run whose voided orders
        # were all whole units at 2dp prices proves nothing about it.
        self.assertGreaterEqual(sim.undone_orders_reconciled, 1)
        self.assertGreaterEqual(sim.rounding_sensitive_undone_orders, 1)
        # And for the rankings the same lines are rolled up into. Every row is
        # checked, but a row nothing ever came back from reads the same gross or
        # net — only a row a void or a return actually reduced can tell the two
        # implementations apart.
        self.assertGreaterEqual(sim.ranking_rows_reconciled, 1)
        self.assertGreaterEqual(sim.returned_ranking_rows, 1)


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
