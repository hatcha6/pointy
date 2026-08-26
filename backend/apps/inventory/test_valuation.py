"""Tests for the valuation engine.

The unit cases are ported from ERPNext's ``erpnext/stock/tests/test_valuation.py``
so that our port is pinned to the same behaviour theirs is — particularly the
negative-stock and bin-merging rules, which are easy to reimplement plausibly
and wrongly.

ERPNext proves its invariants with ``hypothesis``. We do not depend on it, so
the property tests below drive the same invariants with seeded pseudo-random
sequences: deterministic across runs (a failure is always reproducible), but
wide enough to catch what hand-picked cases miss.
"""

from decimal import Decimal
from random import Random

from django.test import SimpleTestCase

from apps.inventory.valuation import (
    FifoValuation,
    LifoValuation,
    MovingAverageValuation,
    ValuationMethod,
    consumed_cost,
    consumed_unit_cost,
    dump_state,
    load_state,
    round_off_if_near_zero,
    valuation_engine,
)


def D(value):
    return Decimal(str(value))


def as_floats(state):
    return [[float(qty), float(rate)] for qty, rate in state]


class TestFifoValuation(SimpleTestCase):
    def setUp(self):
        self.queue = FifoValuation()

    def test_simple_addition(self):
        self.queue.add_stock(1, 10)
        self.assertEqual(as_floats(self.queue.state), [[1, 10]])

    def test_simple_removal(self):
        self.queue.add_stock(1, 10)
        self.queue.remove_stock(1)
        self.assertEqual(as_floats(self.queue.state), [])

    def test_merge_new_stock(self):
        self.queue.add_stock(1, 10)
        self.queue.add_stock(1, 10)
        self.assertEqual(as_floats(self.queue.state), [[2, 10]])

    def test_separate_bins_for_separate_rates(self):
        self.queue.add_stock(1, 10)
        self.queue.add_stock(1, 20)
        self.assertEqual(as_floats(self.queue.state), [[1, 10], [1, 20]])

    def test_adding_negative_stock_keeps_rate(self):
        """A receipt that does not fully cover a negative balance leaves the
        shortfall valued at what it was sold at."""
        self.queue = FifoValuation([[D(-5), D(100)]])
        self.queue.add_stock(2, 10)
        self.assertEqual(as_floats(self.queue.state), [[-3, 100]])

    def test_adding_negative_stock_updates_rate(self):
        """Once the balance turns positive, the surplus is the new stock and
        carries the new rate."""
        self.queue = FifoValuation([[D(-5), D(100)]])
        self.queue.add_stock(6, 10)
        self.assertEqual(as_floats(self.queue.state), [[1, 10]])

    def test_remove_multiple_bins(self):
        self.queue.add_stock(1, 10)
        self.queue.add_stock(2, 20)
        consumed = self.queue.remove_stock(3)
        self.assertEqual(as_floats(consumed), [[1, 10], [2, 20]])
        self.assertEqual(as_floats(self.queue.state), [])

    def test_partial_bin_removal_keeps_remainder(self):
        self.queue.add_stock(10, 10)
        consumed = self.queue.remove_stock(4)
        self.assertEqual(as_floats(consumed), [[4, 10]])
        self.assertEqual(as_floats(self.queue.state), [[6, 10]])

    def test_fifo_consumes_oldest_first(self):
        self.queue.add_stock(5, 10)
        self.queue.add_stock(5, 20)
        consumed = self.queue.remove_stock(6)
        self.assertEqual(as_floats(consumed), [[5, 10], [1, 20]])
        self.assertEqual(as_floats(self.queue.state), [[4, 20]])

    def test_going_negative_uses_last_known_rate(self):
        self.queue.add_stock(1, 10)
        consumed = self.queue.remove_stock(3)
        self.assertEqual(as_floats(consumed), [[1, 10], [2, 10]])
        self.assertEqual(as_floats(self.queue.state), [[-2, 10]])

    def test_going_negative_from_empty_uses_rate_generator(self):
        """With nothing on hand and no history, the caller supplies the cost —
        this is the hook our last-known-cost fallback hangs on."""
        consumed = self.queue.remove_stock(2, rate_generator=lambda: D(7))
        self.assertEqual(as_floats(consumed), [[2, 7]])
        self.assertEqual(as_floats(self.queue.state), [[-2, 7]])

    def test_totals(self):
        self.queue.add_stock(1, 10)
        self.queue.add_stock(2, 13)
        qty, value = self.queue.get_total_stock_and_value()
        self.assertEqual(qty, D(3))
        self.assertEqual(value, D(36))

    def test_rounding_off_near_zero(self):
        """Fractional consumption must not leave a sliver holding a live rate."""
        self.queue.add_stock(D("1.000000000"), 10)
        self.queue.remove_stock(D("0.999999999"))
        qty, value = self.queue.get_total_stock_and_value()
        self.assertEqual(qty, Decimal("0"))
        self.assertEqual(value, Decimal("0"))

    def test_round_off_helper_thresholds(self):
        self.assertEqual(round_off_if_near_zero(D("0.00000001")), Decimal("0"))
        self.assertEqual(round_off_if_near_zero(D("-0.00000001")), Decimal("0"))
        self.assertEqual(round_off_if_near_zero(D("0.001")), D("0.001"))


class TestLifoValuation(SimpleTestCase):
    def setUp(self):
        self.stack = LifoValuation()

    def test_simple_addition(self):
        self.stack.add_stock(1, 10)
        self.assertEqual(as_floats(self.stack.state), [[1, 10]])

    def test_merge_new_stock(self):
        self.stack.add_stock(1, 10)
        self.stack.add_stock(1, 10)
        self.assertEqual(as_floats(self.stack.state), [[2, 10]])

    def test_lifo_consumes_newest_first(self):
        self.stack.add_stock(5, 10)
        self.stack.add_stock(5, 20)
        consumed = self.stack.remove_stock(6)
        self.assertEqual(as_floats(consumed), [[5, 20], [1, 10]])
        self.assertEqual(as_floats(self.stack.state), [[4, 10]])

    def test_lifo_consumption_going_negative(self):
        self.stack.add_stock(5, 10)
        consumed = self.stack.remove_stock(8)
        self.assertEqual(as_floats(consumed), [[5, 10], [3, 10]])
        self.assertEqual(as_floats(self.stack.state), [[-3, 10]])

    def test_lifo_consumption_multiple(self):
        self.stack.add_stock(1, 10)
        self.stack.add_stock(1, 20)
        self.stack.remove_stock(1)
        self.assertEqual(as_floats(self.stack.state), [[1, 10]])
        self.stack.add_stock(1, 30)
        self.stack.remove_stock(1)
        self.assertEqual(as_floats(self.stack.state), [[1, 10]])

    def test_adding_negative_stock_keeps_rate(self):
        self.stack = LifoValuation([[D(-5), D(100)]])
        self.stack.add_stock(2, 10)
        self.assertEqual(as_floats(self.stack.state), [[-3, 100]])

    def test_adding_negative_stock_updates_rate(self):
        self.stack = LifoValuation([[D(-5), D(100)]])
        self.stack.add_stock(6, 10)
        self.assertEqual(as_floats(self.stack.state), [[1, 10]])


class TestMovingAverageValuation(SimpleTestCase):
    def setUp(self):
        self.average = MovingAverageValuation()

    def test_first_receipt_sets_the_rate(self):
        self.average.add_stock(10, 5)
        self.assertEqual(self.average.valuation_rate, D(5))

    def test_receipt_reaverages_against_balance(self):
        self.average.add_stock(10, 10)
        self.average.add_stock(10, 20)
        self.assertEqual(self.average.valuation_rate, D(15))

    def test_weighted_not_arithmetic(self):
        """The classic wrong implementation averages the two rates and ignores
        the quantities. 90 units at 10 plus 10 at 20 is 11, not 15."""
        self.average.add_stock(90, 10)
        self.average.add_stock(10, 20)
        self.assertEqual(self.average.valuation_rate, D(11))

    def test_issue_does_not_move_the_rate(self):
        self.average.add_stock(10, 10)
        self.average.remove_stock(5)
        self.assertEqual(self.average.valuation_rate, D(10))
        qty, value = self.average.get_total_stock_and_value()
        self.assertEqual(qty, D(5))
        self.assertEqual(value, D(50))

    def test_removal_reports_cost_at_current_rate(self):
        self.average.add_stock(10, 10)
        self.average.add_stock(10, 20)
        consumed = self.average.remove_stock(4)
        self.assertEqual(consumed_unit_cost(consumed), D(15))
        self.assertEqual(consumed_cost(consumed), D(60))

    def test_receipt_onto_negative_balance_adopts_new_rate(self):
        self.average.add_stock(5, 10)
        self.average.remove_stock(8)
        self.assertEqual(self.average.qty, D(-3))
        self.average.add_stock(10, 25)
        self.assertEqual(self.average.valuation_rate, D(25))

    def test_seeding_from_a_queue_blends_it(self):
        average = MovingAverageValuation([[D(5), D(10)], [D(5), D(20)]])
        self.assertEqual(average.qty, D(10))
        self.assertEqual(average.valuation_rate, D(15))


class TestEngineSelection(SimpleTestCase):
    def test_each_method_resolves(self):
        self.assertIsInstance(
            valuation_engine(ValuationMethod.FIFO), FifoValuation
        )
        self.assertIsInstance(
            valuation_engine(ValuationMethod.LIFO), LifoValuation
        )
        self.assertIsInstance(
            valuation_engine(ValuationMethod.MOVING_AVERAGE),
            MovingAverageValuation,
        )

    def test_unknown_method_falls_back_rather_than_raising(self):
        """A corrupted settings value must never stop the shop selling."""
        engine = valuation_engine("nonsense")
        self.assertIsInstance(engine, MovingAverageValuation)

    def test_state_round_trips_without_float_drift(self):
        engine = FifoValuation()
        engine.add_stock(D("3.333"), D("1.117"))
        engine.add_stock(D("1.5"), D("2.25"))
        restored = load_state(dump_state(engine.state))
        self.assertEqual(restored, engine.state)

    def test_empty_state_loads_as_empty(self):
        self.assertEqual(load_state(None), [])
        self.assertEqual(load_state(""), [])


class TestMethodsDiffer(SimpleTestCase):
    """The three methods must actually disagree, in the direction accountancy
    says they should. If prices rise, FIFO sells the cheap stock first and
    reports the lower cost; LIFO sells the dear stock first and reports the
    higher one. A port that silently made all three behave alike would pass
    every test above."""

    def buy_low_then_high(self, engine):
        engine.add_stock(10, 10)
        engine.add_stock(10, 20)
        return engine

    def test_rising_prices_order_the_methods(self):
        fifo = self.buy_low_then_high(FifoValuation())
        lifo = self.buy_low_then_high(LifoValuation())
        average = self.buy_low_then_high(MovingAverageValuation())

        fifo_cost = consumed_cost(fifo.remove_stock(10))
        lifo_cost = consumed_cost(lifo.remove_stock(10))
        average_cost = consumed_cost(average.remove_stock(10))

        self.assertEqual(fifo_cost, D(100))
        self.assertEqual(average_cost, D(150))
        self.assertEqual(lifo_cost, D(200))
        self.assertLess(fifo_cost, average_cost)
        self.assertLess(average_cost, lifo_cost)

    def test_remaining_value_is_the_mirror_image(self):
        fifo = self.buy_low_then_high(FifoValuation())
        lifo = self.buy_low_then_high(LifoValuation())
        fifo.remove_stock(10)
        lifo.remove_stock(10)
        self.assertEqual(fifo.get_total_stock_and_value()[1], D(200))
        self.assertEqual(lifo.get_total_stock_and_value()[1], D(100))


class TestValuationInvariants(SimpleTestCase):
    """Seeded stand-ins for ERPNext's hypothesis property tests.

    Each seed is a reproducible sequence of receipts and issues. The invariants
    are the ones that must hold for any method and any sequence — they are what
    a downstream P&L silently depends on.
    """

    SEEDS = range(40)
    OPERATIONS = 60

    def sequences(self, seed):
        random = Random(seed)
        operations = []
        for _ in range(self.OPERATIONS):
            qty = D(random.randint(1, 50))
            rate = D(random.randint(1, 100))
            operations.append(("add" if random.random() < 0.55 else "remove", qty, rate))
        return operations

    def drive(self, engine, operations, *, allow_negative):
        """Run the sequence, tracking what we put in and took out."""
        added_qty = D(0)
        added_value = D(0)
        removed_qty = D(0)
        removed_value = D(0)
        for action, qty, rate in operations:
            if action == "add":
                engine.add_stock(qty, rate)
                added_qty += qty
                added_value += qty * rate
            else:
                on_hand = engine.get_total_stock_and_value()[0]
                if not allow_negative:
                    qty = min(qty, on_hand)
                    if qty <= 0:
                        continue
                consumed = engine.remove_stock(qty)
                removed_qty += qty
                removed_value += consumed_cost(consumed)
        return added_qty, added_value, removed_qty, removed_value

    def test_quantity_is_conserved_for_every_method(self):
        for method in (
            ValuationMethod.FIFO,
            ValuationMethod.LIFO,
            ValuationMethod.MOVING_AVERAGE,
        ):
            for seed in self.SEEDS:
                with self.subTest(method=method, seed=seed):
                    engine = valuation_engine(method)
                    added, _, removed, _ = self.drive(
                        engine, self.sequences(seed), allow_negative=True
                    )
                    qty, _ = engine.get_total_stock_and_value()
                    self.assertEqual(qty, added - removed)

    def test_value_is_conserved_in_the_queue_methods(self):
        """Money in equals money out plus money left. Exact for FIFO and LIFO,
        because a rate once assigned to a bin never changes."""
        for method in (ValuationMethod.FIFO, ValuationMethod.LIFO):
            for seed in self.SEEDS:
                with self.subTest(method=method, seed=seed):
                    engine = valuation_engine(method)
                    _, added_value, _, removed_value = self.drive(
                        engine, self.sequences(seed), allow_negative=False
                    )
                    _, remaining_value = engine.get_total_stock_and_value()
                    self.assertEqual(added_value, removed_value + remaining_value)

    def test_moving_average_conserves_value_within_rounding(self):
        """Averaging divides, so conservation holds to Decimal precision rather
        than exactly. A drift bigger than a millionth of a dinar is a bug."""
        tolerance = Decimal("0.000001")
        for seed in self.SEEDS:
            with self.subTest(seed=seed):
                engine = valuation_engine(ValuationMethod.MOVING_AVERAGE)
                _, added_value, _, removed_value = self.drive(
                    engine, self.sequences(seed), allow_negative=False
                )
                _, remaining_value = engine.get_total_stock_and_value()
                drift = abs(added_value - (removed_value + remaining_value))
                self.assertLess(drift, tolerance)

    def test_no_negative_bins_when_never_oversold(self):
        for method in (ValuationMethod.FIFO, ValuationMethod.LIFO):
            for seed in self.SEEDS:
                with self.subTest(method=method, seed=seed):
                    engine = valuation_engine(method)
                    self.drive(engine, self.sequences(seed), allow_negative=False)
                    for qty, _ in engine.state:
                        self.assertGreaterEqual(qty, 0)

    def test_state_survives_serialisation_mid_sequence(self):
        """The engine is rebuilt from a database column on every use, so a
        sequence driven through save/load must match one driven in memory."""
        for method in (
            ValuationMethod.FIFO,
            ValuationMethod.LIFO,
            ValuationMethod.MOVING_AVERAGE,
        ):
            for seed in list(self.SEEDS)[:10]:
                with self.subTest(method=method, seed=seed):
                    live = valuation_engine(method)
                    state = None
                    for action, qty, rate in self.sequences(seed):
                        reloaded = valuation_engine(method, load_state(state))
                        for engine in (live, reloaded):
                            if action == "add":
                                engine.add_stock(qty, rate)
                            else:
                                engine.remove_stock(qty)
                        state = dump_state(reloaded.state)
                    self.assertEqual(
                        live.get_total_stock_and_value(),
                        valuation_engine(method, load_state(state))
                        .get_total_stock_and_value(),
                    )
