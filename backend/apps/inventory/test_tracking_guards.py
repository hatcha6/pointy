"""The rules that live nowhere a constraint can see them, held by tests.

Four of the fourteen invariants reach from a row, through a variant, to a
product's ``tracking_mode``. No check constraint can follow that path, and
denormalising the mode onto every unit and every allocation to make it visible
was considered and rejected — a column on the largest tables in the feature,
held for a rule whose value changes when a product's mode changes.

So they are held by a single writing service plus the tests below, each named
after the failure it prevents. Two of these are **static**: they read the source
rather than run it, in the shape ``apps/core/test_money_definitions.py``
established, because the failure being prevented is a developer adding a second
writer — and no runtime test can see that until the numbers have already
diverged in production.

When one of these fails, the fix is almost never to widen the allow-list. It is
to go through ``apps.inventory.tracking``.
"""

import re
from decimal import Decimal
from pathlib import Path

from django.test import SimpleTestCase, TestCase
from django.utils import timezone

from apps.catalog.models import Product

from . import tracking
from .integrity import assert_tracking_invariants
from .models import StockBatch, StockBatchBalance, StockUnit, Warehouse
from .tracked_testing import receive, tracked_product

APPS_ROOT = Path(__file__).resolve().parent.parent


def _source_files():
    """Every non-test, non-migration module under ``apps/``."""
    for path in sorted(APPS_ROOT.rglob("*.py")):
        parts = path.parts
        if "migrations" in parts or "__pycache__" in parts:
            continue
        if path.name.startswith("test_") or path.name == "tests.py":
            continue
        if path.name.endswith("_testing.py"):
            continue
        yield path


def _offenders(pattern, allowed):
    matcher = re.compile(pattern)
    hits = {}
    for path in _source_files():
        relative = path.relative_to(APPS_ROOT.parent).as_posix()
        if relative in allowed:
            continue
        lines = [
            f"{relative}:{number}"
            for number, line in enumerate(path.read_text().splitlines(), start=1)
            if matcher.search(line)
        ]
        if lines:
            hits[relative] = lines
    return hits


class UnitStatusHasOneWriterTests(SimpleTestCase):
    """``StockUnit.status`` is written by ``transition_unit`` and nothing else.

    A status set by a form, or by a queryset ``update``, is a status that has
    skipped the transition table — which is how a sold handset quietly becomes
    in-stock again and gets sold twice.
    """

    ALLOWED = {
        # The one writer, and the model that declares the column.
        "apps/inventory/tracking.py",
        "apps/inventory/models.py",
        # Un-receiving voids a whole receipt's units in one statement. It is a
        # bulk correction of rows that were never really here, and it is named
        # in this list rather than routed through the per-unit path because
        # forty units on a cancelled delivery should not be forty UPDATEs.
        "apps/purchasing/documents.py",
    }

    def test_no_other_module_writes_a_unit_status(self):
        offenders = _offenders(
            r"(StockUnit\.objects[\w.()\[\]\"', ]*\.update\([^)]*status=)"
            # ``=`` but not ``==``: reading a unit's status is ordinary, and a
            # guard that cannot tell a comparison from an assignment sends
            # everybody to the allow-list, which is how a guard stops guarding.
            r"|(\bunit\.status\s*=(?!=))",
            self.ALLOWED,
        )
        self.assertEqual(
            offenders,
            {},
            "StockUnit.status must be written through "
            "apps.inventory.tracking.transition_unit, which knows the "
            "transition table. Offending lines: "
            f"{offenders}",
        )


class BalanceDenormalisationHasOneWriterTests(SimpleTestCase):
    """``StockBatchBalance.expiry_date`` and ``is_sellable`` are copies.

    They exist so the FEFO lookup at the till is a single indexed scan of one
    table instead of a join on the checkout path — a promise §11 makes that this
    feature does not get to quietly break. The price is two columns that can
    diverge, and it is paid in ``StockBatch.save``'s propagation. A second
    writer is how a quarantined lot keeps selling in a branch.
    """

    ALLOWED = {
        "apps/inventory/models.py",
        "apps/inventory/tracking.py",
    }

    def test_no_other_module_writes_the_denormalised_columns(self):
        offenders = _offenders(
            r"StockBatchBalance\.objects[\w.()\[\]\"', ]*\.update\("
            r"[^)]*(is_sellable|expiry_date)"
            r"|\bbalance\.(is_sellable|expiry_date)\s*=",
            self.ALLOWED,
        )
        self.assertEqual(
            offenders,
            {},
            "A balance's expiry_date / is_sellable are written only by "
            "StockBatch.save's propagation. Offending lines: "
            f"{offenders}",
        )


class MovementsOnTrackedVariantsCarryAllocationsTests(TestCase):
    """ERPNext #42997, refused by construction.

    The single most valuable test in this feature, because the failure it
    prevents is silent: a serialized ledger entry whose allocations do not
    account for what it moved reports a stock value nobody can explain and a
    COGS nobody can trace.
    """

    def setUp(self):
        self.product = tracked_product(
            name="iPhone", sku="TRK1", mode=Product.TrackingMode.SERIAL,
            unit_price="1500.00",
        )
        self.variant = self.product.default_variant

    def test_a_tracked_movement_whose_plan_does_not_add_up_is_refused(self):
        from apps.inventory.services import (
            build_stock_movement,
            create_stock_movements,
            lock_stock_item,
            stock_snapshot,
        )
        from apps.inventory.models import StockLedgerEntry, StockMovement

        receive(
            variant=self.variant,
            quantity=2,
            unit_cost="1000.00",
            units=[{"code": "SER-1"}, {"code": "SER-2"}],
        )
        stock_item = lock_stock_item(variant=self.variant)
        before = stock_snapshot(stock_item)
        stock_item.quantity_on_hand -= Decimal("2")

        # A plan that names one unit for a movement of two — the exact shape of
        # the bug.
        plan = tracking.plan_issue(
            variant=self.variant,
            warehouse=stock_item.warehouse_id,
            quantity=Decimal("1"),
        )
        movement = build_stock_movement(
            variant=self.variant,
            stock_item=stock_item,
            movement_type=StockMovement.Type.DECREASE,
            quantity=Decimal("2"),
            note="اختبار",
            created_by=None,
            before=before,
            tracked_plan=plan,
        )
        with self.assertRaises(ValueError) as caught:
            create_stock_movements(
                [movement],
                voucher_type=StockLedgerEntry.VoucherType.ADJUSTMENT,
            )
        self.assertIn("#42997", str(caught.exception))


class ConcurrentSaleTests(TestCase):
    """Two tills, one handset: exactly one of them sells it."""

    def setUp(self):
        self.product = tracked_product(
            name="iPhone", sku="TRK2", mode=Product.TrackingMode.SERIAL,
            unit_price="1500.00",
        )
        self.variant = self.product.default_variant
        receive(
            variant=self.variant,
            quantity=1,
            unit_cost="1000.00",
            units=[{"code": "SER-ONLY"}],
        )

    def test_the_second_cart_is_refused_and_nothing_is_left_half_sold(self):
        from rest_framework import serializers

        from apps.sales.models import RegisterSession
        from apps.sales.services import checkout_order

        def sell(key):
            session = RegisterSession.objects.create(
                owner_key=key,
                status=RegisterSession.Status.OPEN,
                opening_cash=Decimal("0.00"),
            )
            return checkout_order(
                register_session=session,
                lines_data=[{"variant": self.variant, "quantity": Decimal("1")}],
                payments_data=[
                    {"method": "cash", "amount": Decimal("1500.00")}
                ],
            )

        sell("till-a")
        with self.assertRaises(serializers.ValidationError):
            sell("till-b")

        self.assertEqual(
            StockUnit.objects.filter(status=StockUnit.Status.SOLD).count(), 1
        )
        assert_tracking_invariants()


TRACKING_TABLES = (
    "inventory_stockunit",
    "inventory_stockbatch",
    "inventory_stockbatchbalance",
    "inventory_stockallocation",
)


def _queries_for(action):
    from django.db import connection
    from django.test.utils import CaptureQueriesContext

    with CaptureQueriesContext(connection) as captured:
        action()
    return [query["sql"] for query in captured.captured_queries]


def _touching_tracking(queries):
    return [
        sql
        for sql in queries
        if any(table in sql for table in TRACKING_TABLES)
    ]


class CheckoutQueryBudgetTests(TestCase):
    """§11: the performance budget, asserted as numbers rather than hopes.

    Two promises live here. A cart with no tracked line pays **zero** extra
    queries — the constraint at the top of the whole design, and the reason the
    mode is read off a product the checkout had already loaded. And a cart with
    tracked lines pays per *variant*, not per *line*: two lines of the same
    handset model lock its units once.
    """

    def _session(self, key):
        from apps.sales.models import RegisterSession

        return RegisterSession.objects.create(
            owner_key=key,
            status=RegisterSession.Status.OPEN,
            opening_cash=Decimal("0.00"),
        )

    def _checkout(self, key, lines, total):
        from apps.sales.services import checkout_order

        return checkout_order(
            register_session=self._session(key),
            lines_data=lines,
            payments_data=[{"method": "cash", "amount": Decimal(total)}],
        )

    def test_a_plain_cart_never_reads_a_tracking_table(self):
        product = tracked_product(
            name="كوكا كولا",
            sku="COKE-Q",
            mode=Product.TrackingMode.QUANTITY,
            unit_price="3.00",
        )
        variant = product.default_variant
        receive(variant=variant, quantity=100, unit_cost="1.00")
        # Warm the settings singleton and the default-warehouse cache, which a
        # real till warms on its first sale of the day.
        self._checkout(
            "warm", [{"variant": variant, "quantity": Decimal("1")}], "3.00"
        )

        queries = _queries_for(
            lambda: self._checkout(
                "cold", [{"variant": variant, "quantity": Decimal("1")}], "3.00"
            )
        )
        self.assertEqual(
            _touching_tracking(queries),
            [],
            "A shop that sells Coca-Cola must not be able to tell that "
            "serialization shipped.",
        )

    def test_two_lines_of_one_serialized_variant_lock_its_units_once(self):
        product = tracked_product(
            name="iPhone",
            sku="TRK-Q",
            mode=Product.TrackingMode.SERIAL,
            unit_price="1500.00",
        )
        variant = product.default_variant
        receive(
            variant=variant,
            quantity=4,
            unit_cost="1000.00",
            units=[{"code": f"Q-{index}"} for index in range(4)],
        )
        self._checkout(
            "warm-t", [{"variant": variant, "quantity": Decimal("1")}], "1500.00"
        )

        one_line = _queries_for(
            lambda: self._checkout(
                "one", [{"variant": variant, "quantity": Decimal("1")}], "1500.00"
            )
        )
        two_lines = _queries_for(
            lambda: self._checkout(
                "two",
                [
                    {"variant": variant, "quantity": Decimal("1")},
                    {"variant": variant, "quantity": Decimal("1")},
                ],
                "3000.00",
            )
        )

        def locks(queries):
            return len(
                [
                    sql
                    for sql in queries
                    if "inventory_stockunit" in sql and "FOR UPDATE" in sql
                ]
            )

        self.assertEqual(locks(one_line), locks(two_lines))
        self.assertLessEqual(locks(two_lines), 1)


class TrackedLotIsNeverAPlaceTests(TestCase):
    """A plan that drifts back toward one row per lot per place fails here.

    The table this feature is built on has exactly one row per lot, whatever
    happens to its goods, and the property that proves it is that moving stock
    between two warehouses leaves the lot row byte-identical.
    """

    def setUp(self):
        self.product = tracked_product(
            name="أموكسيسيلين",
            sku="AMOX-G",
            mode=Product.TrackingMode.BATCH,
            unit_price="20.00",
        )
        self.variant = self.product.default_variant

    def test_moving_stock_between_places_does_not_touch_the_lot(self):
        lot, _ = tracking.resolve_batch(
            variant=self.variant,
            code="A-1",
            expiry_date=timezone.localdate(),
        )
        source = tracking.lock_balance(
            batch=lot, warehouse=Warehouse.default_id(), variant=self.variant
        )
        tracking.receive_into_balance(
            balance=source, quantity=Decimal("100"), rate=Decimal("10.00")
        )
        before = StockBatch.objects.values().get(pk=lot.pk)

        branch = Warehouse.objects.create(name="فرع", code="BR")
        destination = tracking.lock_balance(
            batch=lot, warehouse=branch, variant=self.variant
        )
        tracking.issue_from_balance(balance=source, quantity=Decimal("25"))
        tracking.receive_into_balance(
            balance=destination, quantity=Decimal("25"), rate=Decimal("10.00")
        )

        self.assertEqual(StockBatch.objects.values().get(pk=lot.pk), before)
        self.assertEqual(StockBatch.objects.count(), 1)
        self.assertEqual(
            sorted(
                StockBatchBalance.objects.values_list("remaining_quantity", flat=True)
            ),
            [Decimal("25.000"), Decimal("75.000")],
        )

    def test_a_second_delivery_of_the_same_lot_re_weights_one_balance(self):
        lot, created = tracking.resolve_batch(variant=self.variant, code="A-1")
        self.assertTrue(created)
        balance = tracking.lock_balance(
            batch=lot, warehouse=Warehouse.default_id(), variant=self.variant
        )
        tracking.receive_into_balance(
            balance=balance, quantity=Decimal("60"), rate=Decimal("14.00")
        )
        again, created_again = tracking.resolve_batch(
            variant=self.variant, code=" a-1 "
        )
        self.assertFalse(created_again)
        self.assertEqual(again.pk, lot.pk)
        tracking.receive_into_balance(
            balance=balance, quantity=Decimal("40"), rate=Decimal("16.00")
        )

        balance.refresh_from_db()
        self.assertEqual(balance.incoming_rate, Decimal("14.800000"))
        self.assertEqual(StockBatch.objects.count(), 1)
