"""Identified stock, end to end: serials, lots, and serials inside lots.

Organised the way the plan's §14 is: the failures ported from ERPNext's bug list
first, then the ones we have that they do not. Every test is named after the
thing that goes wrong when it is missing, because a test called
``test_serial_flow`` tells a future reader nothing about which sentence of the
design it is holding up.

Every scenario finishes by asserting the §5.4 invariants, which is the whole
point of having written them as code: a test that proves the *particular* thing
it is about also proves that nothing else drifted while it happened.
"""

from datetime import timedelta
from decimal import Decimal

from django.test import TestCase
from django.utils import timezone
from rest_framework import serializers

from apps.catalog.models import Product
from apps.core.models import ShopSettings
from apps.purchasing.models import PurchaseReceipt, Supplier
from apps.sales.models import RegisterSession
from apps.sales.services import checkout_order

from . import tracking
from .identity import (
    IdentifierKind,
    check_identifier,
    luhn_check,
    normalize_identifier,
    vin_check_digit_ok,
)
from .integrity import (
    assert_tracking_invariants,
    check_balance_denormalisation,
)
from .models import (
    StockAllocation,
    StockBatch,
    StockBatchBalance,
    StockItem,
    StockLedgerEntry,
    StockUnit,
    StockValuationBin,
    Warehouse,
)
from .tracked_testing import receive, tracked_product

# A real IMEI's check digit: 35 1234 56 789011 + Luhn.
IMEI_A = "351234567890116"
IMEI_B = "351234567890124"
IMEI_C = "351234567890132"


_TILL_SEQUENCE = 0


def _session(user=None):
    """An open till.

    Numbered, because a shop may hold only one open session per owner and a test
    that sells twice would otherwise collide with itself rather than with the
    thing it is testing.
    """
    global _TILL_SEQUENCE
    _TILL_SEQUENCE += 1
    return RegisterSession.objects.create(
        owner=user,
        owner_key=f"test-till-{_TILL_SEQUENCE}",
        status=RegisterSession.Status.OPEN,
        opening_cash=Decimal("0.00"),
    )


def _sell(variant, quantity=1, *, price="100.00", session=None, **line_extra):
    session = session or _session()
    return checkout_order(
        register_session=session,
        lines_data=[
            {"variant": variant, "quantity": Decimal(quantity), **line_extra}
        ],
        payments_data=[
            {"method": "cash", "amount": Decimal(price) * Decimal(quantity)}
        ],
    )


class IdentifierNormalisationTests(TestCase):
    """The same number typed three ways is the same number.

    A lookup that misses because of a dash is a lookup that sends a handset back
    out of the door untracked.
    """

    def test_spacing_and_punctuation_do_not_change_an_identifier(self):
        self.assertEqual(normalize_identifier(" 35 1234-567890.116 "), IMEI_A)
        self.assertEqual(normalize_identifier("wba-3b1  c5 1e p123"), "WBA3B1C51EP123")

    def test_a_blank_secondary_code_normalises_to_blank_not_a_sentinel(self):
        self.assertEqual(normalize_identifier(None), "")
        self.assertEqual(normalize_identifier("   "), "")

    def test_imei_luhn_catches_a_transposed_digit(self):
        self.assertTrue(luhn_check(IMEI_A))
        transposed = IMEI_A[:8] + IMEI_A[9] + IMEI_A[8] + IMEI_A[10:]
        self.assertFalse(luhn_check(transposed))

    def test_a_bad_imei_warns_and_does_not_raise(self):
        """A guard that blocks a legitimate oddity gets disabled, and a disabled
        guard catches nothing."""
        warnings = check_identifier("351234567890117", kind=IdentifierKind.IMEI)
        self.assertEqual([warning.code for warning in warnings], ["imei_checksum"])
        self.assertEqual(check_identifier(IMEI_A, kind=IdentifierKind.IMEI), [])

    def test_imeisv_is_accepted_without_a_luhn_digit(self):
        """The 16-digit form replaces the check digit with a software version,
        so checking it would fail every single time."""
        self.assertEqual(check_identifier(IMEI_A + "7", kind=IdentifierKind.IMEI), [])

    def test_vin_rejects_the_letters_iso_3779_forbids(self):
        warnings = check_identifier("1HGCM82633AO04352", kind=IdentifierKind.VIN)
        self.assertEqual(
            [warning.code for warning in warnings], ["vin_forbidden_letters"]
        )

    def test_vin_check_digit(self):
        self.assertTrue(vin_check_digit_ok("1HGCM82633A004352"))
        self.assertFalse(vin_check_digit_ok("1HGCM82633A004353"))


class InvisibilityTests(TestCase):
    """A shop that sells Coca-Cola must not be able to tell that this shipped."""

    def setUp(self):
        self.product = tracked_product(
            name="كوكا كولا", sku="COKE", mode=Product.TrackingMode.QUANTITY
        )
        self.variant = self.product.default_variant

    def test_an_untracked_product_creates_no_units_lots_or_allocations(self):
        receive(variant=self.variant, quantity=10, unit_cost="1.00")
        _sell(self.variant, 3, price="2.00")

        self.assertEqual(StockUnit.objects.count(), 0)
        self.assertEqual(StockBatch.objects.count(), 0)
        self.assertEqual(StockAllocation.objects.count(), 0)
        self.assertEqual(
            StockItem.objects.get(variant=self.variant).quantity_on_hand,
            Decimal("7.000"),
        )

    def test_an_untracked_product_is_still_valued_by_the_shops_own_method(self):
        receive(variant=self.variant, quantity=10, unit_cost="1.00")
        entry = StockLedgerEntry.objects.filter(variant=self.variant).first()
        self.assertEqual(entry.method, ShopSettings.load().inventory_valuation_method)


class SerializedReceiptTests(TestCase):
    def setUp(self):
        self.product = tracked_product(
            name="iPhone 13 Pro",
            sku="IP13P",
            mode=Product.TrackingMode.SERIAL,
            unit_price="1500.00",
        )
        self.variant = self.product.default_variant

    def test_receiving_identifiers_creates_one_unit_each_at_the_line_cost(self):
        receive(
            variant=self.variant,
            quantity=3,
            unit_cost="1200.00",
            units=[{"code": IMEI_A}, {"code": IMEI_B}, {"code": IMEI_C}],
        )
        units = StockUnit.objects.order_by("id")
        self.assertEqual([unit.code for unit in units], [IMEI_A, IMEI_B, IMEI_C])
        self.assertTrue(all(unit.is_identified for unit in units))
        self.assertTrue(
            all(unit.status == StockUnit.Status.IN_STOCK for unit in units)
        )
        self.assertTrue(
            all(unit.incoming_rate == Decimal("1200.000000") for unit in units)
        )
        assert_tracking_invariants()

    def test_a_serialized_receipt_writes_one_allocation_per_unit(self):
        """ERPNext #42997: a serialized ledger entry that names no serials.

        Refused by construction — the valuation pass will not write an entry
        whose allocations do not add up to what it moved.
        """
        receive(
            variant=self.variant,
            quantity=2,
            unit_cost="1200.00",
            units=[{"code": IMEI_A}, {"code": IMEI_B}],
        )
        entry = StockLedgerEntry.objects.get(variant=self.variant)
        self.assertEqual(entry.allocations.count(), 2)
        self.assertEqual(
            sorted(row.unit.code for row in entry.allocations.all()),
            sorted([IMEI_A, IMEI_B]),
        )
        self.assertEqual(entry.quantity_change, Decimal("2.000"))

    def test_a_serialized_variant_is_valued_per_unit_whatever_the_shop_chose(self):
        """§3.4: there is no configuration under which serialized stock is
        valued by a blended guess."""
        settings = ShopSettings.load()
        settings.inventory_valuation_method = ShopSettings.ValuationMethod.LIFO
        settings.save(update_fields=["inventory_valuation_method", "updated_at"])

        receive(
            variant=self.variant,
            quantity=1,
            unit_cost="1200.00",
            units=[{"code": IMEI_A}],
        )
        entry = StockLedgerEntry.objects.get(variant=self.variant)
        self.assertEqual(entry.method, "unit_cost")
        self.assertEqual(
            StockValuationBin.objects.get(variant=self.variant).method, "unit_cost"
        )

    def test_per_unit_costs_may_differ_and_must_sum_to_the_line(self):
        """Used goods have individual costs and a purchase line has one total;
        letting the two disagree is how a cost figure becomes a fiction."""
        receive(
            variant=self.variant,
            quantity=2,
            unit_cost="1200.00",
            units=[
                {"code": IMEI_A, "unit_cost": Decimal("1300.00")},
                {"code": IMEI_B, "unit_cost": Decimal("1100.00")},
            ],
        )
        rates = dict(
            StockUnit.objects.values_list("code_normalized", "incoming_rate")
        )
        self.assertEqual(rates[IMEI_A], Decimal("1300.000000"))
        self.assertEqual(rates[IMEI_B], Decimal("1100.000000"))
        bin_row = StockValuationBin.objects.get(variant=self.variant)
        self.assertEqual(bin_row.stock_value, Decimal("2400.000000"))
        assert_tracking_invariants()

    def test_per_unit_costs_that_do_not_sum_to_the_line_are_refused(self):
        with self.assertRaises(serializers.ValidationError) as caught:
            receive(
                variant=self.variant,
                quantity=2,
                unit_cost="1200.00",
                units=[
                    {"code": IMEI_A, "unit_cost": Decimal("1300.00")},
                    {"code": IMEI_B, "unit_cost": Decimal("1300.00")},
                ],
            )
        self.assertIn("مجموع تكاليف الوحدات", str(caught.exception))

    def test_a_live_duplicate_identifier_is_a_structured_conflict(self):
        receive(
            variant=self.variant,
            quantity=1,
            unit_cost="1200.00",
            units=[{"code": IMEI_A}],
        )
        with self.assertRaises(serializers.ValidationError) as caught:
            receive(
                variant=self.variant,
                quantity=1,
                unit_cost="1200.00",
                units=[{"code": IMEI_A}],
            )
        detail = caught.exception.detail
        self.assertIn("conflicts", detail)
        conflict = detail["conflicts"][0]
        self.assertEqual(conflict["kind"], "stock_unit")
        self.assertEqual(conflict["value"], IMEI_A)
        self.assertIn("object_id", conflict)

    def test_an_identifier_sold_previously_can_be_received_again(self):
        """``allow_existing_serial_no``, which ERPNext needs a setting for.

        One live unit per identifier, unlimited history per identifier: a phone
        sold and traded back in is two rows with the same code, at most one of
        them live.
        """
        receive(
            variant=self.variant,
            quantity=1,
            unit_cost="1200.00",
            units=[{"code": IMEI_A}],
        )
        _sell(self.variant, 1, price="1500.00")
        receive(
            variant=self.variant,
            quantity=1,
            unit_cost="900.00",
            units=[{"code": IMEI_A}],
        )

        rows = StockUnit.objects.filter(code_normalized=IMEI_A).order_by("id")
        self.assertEqual(rows.count(), 2)
        self.assertEqual(rows[0].status, StockUnit.Status.SOLD)
        self.assertEqual(rows[1].status, StockUnit.Status.IN_STOCK)
        assert_tracking_invariants()

    def test_a_historical_identifier_is_offered_as_provenance_not_an_error(self):
        receive(
            variant=self.variant,
            quantity=1,
            unit_cost="1200.00",
            units=[{"code": IMEI_A}],
        )
        _sell(self.variant, 1, price="1500.00")
        history = tracking.historical_units(IMEI_A)
        self.assertEqual(len(history), 1)
        self.assertEqual(history[0].status, StockUnit.Status.SOLD)

    def test_damaged_and_accepted_units_are_two_disjoint_sets(self):
        """ERPNext #43492: a receipt whose damaged quantity overwrote its
        accepted serials."""
        receive(
            variant=self.variant,
            quantity=2,
            damaged_quantity=1,
            unit_cost="1200.00",
            units=[{"code": IMEI_A}, {"code": IMEI_B}, {"code": IMEI_C}],
        )
        accepted = set(
            StockUnit.objects.filter(status=StockUnit.Status.IN_STOCK).values_list(
                "code_normalized", flat=True
            )
        )
        damaged = set(
            StockUnit.objects.filter(status=StockUnit.Status.DAMAGED).values_list(
                "code_normalized", flat=True
            )
        )
        self.assertEqual(accepted, {IMEI_A, IMEI_B})
        self.assertEqual(damaged, {IMEI_C})
        self.assertEqual(accepted & damaged, set())
        # Damaged goods never reached ``quantity_on_hand``, so they are not in
        # the bin and have no allocation to hang off.
        self.assertEqual(
            StockItem.objects.get(variant=self.variant).quantity_on_hand,
            Decimal("2.000"),
        )
        assert_tracking_invariants()

    def test_a_receipt_short_of_identifiers_is_refused_unless_capture_later(self):
        with self.assertRaises(serializers.ValidationError):
            receive(
                variant=self.variant,
                quantity=3,
                unit_cost="1200.00",
                units=[{"code": IMEI_A}],
            )

    def test_capture_later_lands_placeholders_that_cannot_be_sold(self):
        settings = ShopSettings.load()
        settings.serialized_capture_later_allowed = True
        settings.save(
            update_fields=["serialized_capture_later_allowed", "updated_at"]
        )

        receive(
            variant=self.variant,
            quantity=2,
            unit_cost="1200.00",
            units=[{"code": IMEI_A}],
        )
        pending = StockUnit.objects.filter(is_identified=False)
        self.assertEqual(pending.count(), 1)
        self.assertEqual(pending.get().status, StockUnit.Status.IN_STOCK)
        assert_tracking_invariants()

        # Two are on the shelf, but only one of them can be rung up.
        with self.assertRaises(serializers.ValidationError):
            _sell(self.variant, 2, price="1500.00")


class SerializedSaleTests(TestCase):
    def setUp(self):
        self.product = tracked_product(
            name="iPhone 13 Pro",
            sku="IP13P",
            mode=Product.TrackingMode.SERIAL,
            unit_price="1500.00",
        )
        self.variant = self.product.default_variant
        receive(
            variant=self.variant,
            quantity=3,
            unit_cost="1200.00",
            units=[
                {"code": IMEI_A, "unit_cost": Decimal("1300.00")},
                {"code": IMEI_B, "unit_cost": Decimal("1200.00")},
                {"code": IMEI_C, "unit_cost": Decimal("1100.00")},
            ],
        )

    def test_selling_a_named_unit_issues_that_unit_at_its_own_cost(self):
        unit = StockUnit.objects.get(code_normalized=IMEI_C)
        order = _sell(self.variant, 1, price="1500.00", stock_units=[unit.pk])

        unit.refresh_from_db()
        self.assertEqual(unit.status, StockUnit.Status.SOLD)
        self.assertEqual(unit.sold_order_line, order.lines.get())
        self.assertIsNotNone(unit.sold_at)
        line = order.lines.get()
        # The cheapest handset, because the till named it — not the oldest, and
        # certainly not a blended rate.
        self.assertEqual(line.unit_cost, Decimal("1100.00"))
        assert_tracking_invariants()

    def test_selling_without_naming_one_takes_the_oldest(self):
        order = _sell(self.variant, 1, price="1500.00")
        sold = StockUnit.objects.get(status=StockUnit.Status.SOLD)
        self.assertEqual(sold.code_normalized, IMEI_A)
        self.assertEqual(order.lines.get().unit_cost, Decimal("1300.00"))

    def test_selling_by_scanned_code_resolves_the_unit(self):
        _sell(self.variant, 1, price="1500.00", stock_unit_codes=[" 351234-567890124 "])
        sold = StockUnit.objects.get(status=StockUnit.Status.SOLD)
        self.assertEqual(sold.code_normalized, IMEI_B)

    def test_a_sale_of_three_writes_three_allocations_under_one_entry(self):
        _sell(self.variant, 3, price="1500.00")
        entry = StockLedgerEntry.objects.filter(
            variant=self.variant, quantity_change__lt=0
        ).get()
        self.assertEqual(entry.allocations.count(), 3)
        self.assertEqual(
            sorted(row.rate for row in entry.allocations.all()),
            [
                Decimal("1100.000000"),
                Decimal("1200.000000"),
                Decimal("1300.000000"),
            ],
        )
        # One blended rate on the entry, three real costs beneath it.
        self.assertEqual(entry.valuation_rate, Decimal("1200.000000"))
        self.assertEqual(entry.value_change, Decimal("-3600.000000"))

    def test_serialized_stock_cannot_go_negative_even_with_overselling_on(self):
        """ERPNext allowed this and removed the special case in v15. There is no
        such thing as a phantom handset."""
        settings = ShopSettings.load()
        settings.allow_overselling = True
        settings.save(update_fields=["allow_overselling", "updated_at"])

        with self.assertRaises(serializers.ValidationError):
            _sell(self.variant, 4, price="1500.00")
        self.assertEqual(
            StockItem.objects.get(variant=self.variant).quantity_on_hand,
            Decimal("3.000"),
        )
        self.assertFalse(
            StockUnit.objects.filter(status=StockUnit.Status.SOLD).exists()
        )

    def test_selling_a_unit_that_is_already_sold_is_refused(self):
        unit = StockUnit.objects.get(code_normalized=IMEI_A)
        _sell(self.variant, 1, price="1500.00", stock_units=[unit.pk])
        with self.assertRaises(serializers.ValidationError):
            _sell(self.variant, 1, price="1500.00", stock_units=[unit.pk])
        assert_tracking_invariants()

    def test_the_bin_is_the_sum_of_what_is_left(self):
        _sell(self.variant, 1, price="1500.00", stock_units=[
            StockUnit.objects.get(code_normalized=IMEI_A).pk
        ])
        bin_row = StockValuationBin.objects.get(variant=self.variant)
        self.assertEqual(bin_row.quantity, Decimal("2.000"))
        self.assertEqual(bin_row.stock_value, Decimal("2300.000000"))
        self.assertEqual(bin_row.valuation_rate, Decimal("1150.000000"))
        assert_tracking_invariants()

    def test_a_consigned_unit_counts_in_quantity_and_contributes_nothing_to_value(self):
        """The shop is holding the watch; the shop does not own the watch."""
        consigned = StockUnit.objects.create(
            variant=self.variant,
            warehouse_id=Warehouse.default_id(),
            code="CONSIGNED-1",
            status=StockUnit.Status.IN_STOCK,
            incoming_rate=Decimal("0"),
            is_consignment=True,
            declared_value=Decimal("1400.00"),
            in_stock_since=timezone.now(),
        )
        self.assertEqual(consigned.stock_value, Decimal("0"))


class BatchReceiptTests(TestCase):
    def setUp(self):
        self.product = tracked_product(
            name="أموكسيسيلين 500",
            sku="AMOX500",
            mode=Product.TrackingMode.BATCH,
            unit_price="20.00",
        )
        self.variant = self.product.default_variant
        self.today = timezone.localdate()

    def test_one_delivery_may_bundle_several_lots(self):
        receive(
            variant=self.variant,
            quantity=100,
            unit_cost="14.50",
            batches=[
                {
                    "code": "A-2026-01",
                    "quantity": Decimal("60"),
                    "expiry_date": self.today + timedelta(days=400),
                },
                {
                    "code": "B-2026-04",
                    "quantity": Decimal("40"),
                    "expiry_date": self.today + timedelta(days=500),
                },
            ],
        )
        lots = StockBatch.objects.order_by("expiry_date")
        self.assertEqual([lot.code for lot in lots], ["A-2026-01", "B-2026-04"])
        self.assertEqual(
            [lot.balances.get().remaining_quantity for lot in lots],
            [Decimal("60.000"), Decimal("40.000")],
        )
        assert_tracking_invariants()

    def test_captured_lot_quantities_must_sum_to_what_was_accepted(self):
        with self.assertRaises(serializers.ValidationError) as caught:
            receive(
                variant=self.variant,
                quantity=100,
                unit_cost="14.50",
                batches=[{"code": "A-1", "quantity": Decimal("60")}],
            )
        self.assertIn("لا يساوي الكمية", str(caught.exception))

    def test_a_known_lot_code_adds_to_a_balance_instead_of_forking_the_lot(self):
        """A second delivery of Lot A *is* Lot A — same factory run, same
        expiry, same recall exposure."""
        expiry = self.today + timedelta(days=400)
        receive(
            variant=self.variant,
            quantity=60,
            unit_cost="14.00",
            batches=[
                {"code": "A-2026-01", "quantity": Decimal("60"), "expiry_date": expiry}
            ],
        )
        receive(
            variant=self.variant,
            quantity=40,
            unit_cost="16.00",
            batches=[
                {"code": "A-2026-01", "quantity": Decimal("40"), "expiry_date": expiry}
            ],
        )
        lot = StockBatch.objects.get()
        balance = lot.balances.get()
        self.assertEqual(balance.received_quantity, Decimal("100.000"))
        self.assertEqual(balance.remaining_quantity, Decimal("100.000"))
        # Weighted within this lot and this warehouse: (60x14 + 40x16) / 100.
        self.assertEqual(balance.incoming_rate, Decimal("14.800000"))
        assert_tracking_invariants()

    def test_a_known_lot_with_a_different_expiry_is_a_structured_conflict(self):
        """One of the two labels is wrong, and the receiver is holding the box."""
        receive(
            variant=self.variant,
            quantity=60,
            unit_cost="14.00",
            batches=[
                {
                    "code": "A-2026-01",
                    "quantity": Decimal("60"),
                    "expiry_date": self.today + timedelta(days=400),
                }
            ],
        )
        with self.assertRaises(serializers.ValidationError) as caught:
            receive(
                variant=self.variant,
                quantity=40,
                unit_cost="14.00",
                batches=[
                    {
                        "code": "A-2026-01",
                        "quantity": Decimal("40"),
                        "expiry_date": self.today + timedelta(days=500),
                    }
                ],
            )
        conflict = caught.exception.detail["conflicts"][0]
        self.assertEqual(conflict["kind"], "batch_expiry")
        self.assertIn("existing_expiry_date", conflict)

    def test_one_lot_in_three_places_is_one_lot_and_three_balances(self):
        expiry = self.today + timedelta(days=400)
        lot, _ = tracking.resolve_batch(
            variant=self.variant, code="A-2026-01", expiry_date=expiry
        )
        showroom = Warehouse.objects.create(name="المعرض 2", code="SHOW")
        branch = Warehouse.objects.create(name="فرع 2", code="BR2")
        for warehouse, quantity in (
            (Warehouse.default_id(), 60),
            (showroom, 25),
            (branch, 15),
        ):
            balance = tracking.lock_balance(
                batch=lot, warehouse=warehouse, variant=self.variant
            )
            tracking.receive_into_balance(
                balance=balance, quantity=Decimal(quantity), rate=Decimal("14.00")
            )

        self.assertEqual(StockBatch.objects.count(), 1)
        self.assertEqual(lot.balances.count(), 3)
        self.assertEqual(
            sorted(b.remaining_quantity for b in lot.balances.all()),
            [Decimal("15.000"), Decimal("25.000"), Decimal("60.000")],
        )

    def test_quarantining_a_lot_is_one_write_that_reaches_every_branch(self):
        expiry = self.today + timedelta(days=400)
        lot, _ = tracking.resolve_batch(
            variant=self.variant, code="A-2026-01", expiry_date=expiry
        )
        branch = Warehouse.objects.create(name="فرع 2", code="BR2")
        for warehouse in (Warehouse.default_id(), branch):
            balance = tracking.lock_balance(
                batch=lot, warehouse=warehouse, variant=self.variant
            )
            tracking.receive_into_balance(
                balance=balance, quantity=Decimal("10"), rate=Decimal("14.00")
            )

        lot.status = StockBatch.Status.QUARANTINED
        lot.save(update_fields=["status", "updated_at"])

        self.assertFalse(
            StockBatchBalance.objects.filter(batch=lot, is_sellable=True).exists()
        )
        # The lot's own goods are untouched: quarantine is a stop-sale, not a
        # write-off, and the stock is still on the shelf until somebody scraps
        # it — which is its own movement, in each place it sits.
        self.assertEqual(
            sorted(b.remaining_quantity for b in lot.balances.all()),
            [Decimal("10.000"), Decimal("10.000")],
        )
        self.assertEqual(check_balance_denormalisation(), [])

    def test_changing_a_lots_expiry_reaches_its_balances_in_the_same_write(self):
        lot, _ = tracking.resolve_batch(
            variant=self.variant,
            code="A-2026-01",
            expiry_date=self.today + timedelta(days=400),
        )
        balance = tracking.lock_balance(
            batch=lot, warehouse=Warehouse.default_id(), variant=self.variant
        )
        lot.expiry_date = self.today + timedelta(days=30)
        lot.save(update_fields=["expiry_date", "updated_at"])

        balance.refresh_from_db()
        self.assertEqual(balance.expiry_date, lot.expiry_date)
        self.assertEqual(check_balance_denormalisation(), [])


class BatchSaleTests(TestCase):
    def setUp(self):
        self.product = tracked_product(
            name="أموكسيسيلين 500",
            sku="AMOX500",
            mode=Product.TrackingMode.BATCH,
            unit_price="20.00",
        )
        self.variant = self.product.default_variant
        self.today = timezone.localdate()

    def _receive(self, *, code, quantity, days, unit_cost="14.00"):
        receive(
            variant=self.variant,
            quantity=quantity,
            unit_cost=unit_cost,
            batches=[
                {
                    "code": code,
                    "quantity": Decimal(quantity),
                    "expiry_date": self.today + timedelta(days=days),
                }
            ],
        )

    def test_fefo_takes_the_earliest_expiring_lot_first(self):
        # Received in the *wrong* order so the ordering cannot be incidental.
        self._receive(code="LATE", quantity=10, days=400)
        self._receive(code="SOON", quantity=10, days=30)

        _sell(self.variant, 4, price="20.00")

        soon = StockBatchBalance.objects.get(batch__code="SOON")
        late = StockBatchBalance.objects.get(batch__code="LATE")
        self.assertEqual(soon.remaining_quantity, Decimal("6.000"))
        self.assertEqual(late.remaining_quantity, Decimal("10.000"))
        assert_tracking_invariants()

    def test_a_sale_bigger_than_one_lot_splits_across_two_allocations(self):
        self._receive(code="SOON", quantity=3, days=30, unit_cost="14.00")
        self._receive(code="LATE", quantity=5, days=400, unit_cost="16.00")

        _sell(self.variant, 4, price="20.00")

        entry = StockLedgerEntry.objects.filter(
            variant=self.variant, quantity_change__lt=0
        ).get()
        allocations = entry.allocations.order_by("id")
        self.assertEqual(
            [(row.batch.code, row.quantity) for row in allocations],
            [("SOON", Decimal("3.000")), ("LATE", Decimal("1.000"))],
        )
        # 3 x 14 + 1 x 16 = 58, at a blended 14.50 on the entry itself.
        self.assertEqual(entry.value_change, Decimal("-58.000000"))
        self.assertEqual(entry.valuation_rate, Decimal("14.500000"))
        assert_tracking_invariants()

    def test_an_expired_lot_is_not_sold(self):
        self._receive(code="DEAD", quantity=10, days=-1)
        with self.assertRaises(serializers.ValidationError) as caught:
            _sell(self.variant, 1, price="20.00")
        self.assertIn("دفعات صالحة", str(caught.exception))

    def test_a_quarantined_lot_is_blocked_on_the_very_next_checkout(self):
        self._receive(code="RECALL", quantity=10, days=400)
        lot = StockBatch.objects.get(code="RECALL")
        lot.is_locked = True
        lot.save(update_fields=["is_locked", "updated_at"])

        with self.assertRaises(serializers.ValidationError):
            _sell(self.variant, 1, price="20.00")

    def test_a_batch_variant_is_valued_batch_wise(self):
        self._receive(code="SOON", quantity=3, days=30, unit_cost="14.00")
        entry = StockLedgerEntry.objects.filter(variant=self.variant).first()
        self.assertEqual(entry.method, "batch_cost")

    def test_the_bin_sums_the_balances_in_this_place_only(self):
        self._receive(code="SOON", quantity=10, days=30, unit_cost="14.00")
        branch = Warehouse.objects.create(name="فرع 2", code="BR2")
        lot = StockBatch.objects.get(code="SOON")
        balance = tracking.lock_balance(
            batch=lot, warehouse=branch, variant=self.variant
        )
        tracking.receive_into_balance(
            balance=balance, quantity=Decimal("5"), rate=Decimal("14.00")
        )

        bin_row = StockValuationBin.objects.get(
            variant=self.variant, warehouse_id=Warehouse.default_id()
        )
        self.assertEqual(bin_row.quantity, Decimal("10.000"))
        self.assertEqual(bin_row.stock_value, Decimal("140.000000"))


class SerialBatchTests(TestCase):
    """The fourth mode: a serialised pack inside a lot.

    Every test here is really about one sentence — **the pack is counted
    once** — because the failure it prevents is a pharmacy that appears to be
    holding twice the medicine it has.
    """

    def setUp(self):
        self.product = tracked_product(
            name="لقاح مسلسل",
            sku="VAX",
            mode=Product.TrackingMode.SERIAL_BATCH,
            unit_price="90.00",
        )
        self.variant = self.product.default_variant
        self.today = timezone.localdate()

    def _receive(self, codes, *, lot="L-1", days=400, unit_cost="40.00"):
        receive(
            variant=self.variant,
            quantity=len(codes),
            unit_cost=unit_cost,
            units=[{"code": code} for code in codes],
            batches=[
                {"code": lot, "expiry_date": self.today + timedelta(days=days)}
            ],
        )

    def test_receiving_creates_units_inside_one_lot(self):
        self._receive(["S1", "S2", "S3"])
        lot = StockBatch.objects.get()
        self.assertEqual(lot.units.count(), 3)
        self.assertTrue(all(unit.batch_id == lot.pk for unit in lot.units.all()))
        assert_tracking_invariants()

    def test_the_pack_is_counted_once(self):
        """40 serialised packs in one lot is 40, not 80."""
        self._receive([f"S{index}" for index in range(1, 41)])
        bin_row = StockValuationBin.objects.get(variant=self.variant)
        self.assertEqual(bin_row.quantity, Decimal("40.000"))
        self.assertEqual(
            StockItem.objects.get(variant=self.variant).quantity_on_hand,
            Decimal("40.000"),
        )
        # And the balance is a mirror of that count, not a second number.
        self.assertEqual(
            StockBatchBalance.objects.get().remaining_quantity, Decimal("40.000")
        )
        assert_tracking_invariants()

    def test_a_sale_writes_one_allocation_naming_both_identities(self):
        self._receive(["S1", "S2"])
        _sell(self.variant, 1, price="90.00")

        entry = StockLedgerEntry.objects.filter(
            variant=self.variant, quantity_change__lt=0
        ).get()
        allocation = entry.allocations.get()
        self.assertIsNotNone(allocation.unit_id)
        self.assertIsNotNone(allocation.batch_id)
        self.assertEqual(allocation.quantity, Decimal("1.000"))
        # One row, both bookkeepings: the unit's status flips and the lot's
        # balance decrements.
        self.assertEqual(allocation.unit.status, StockUnit.Status.SOLD)
        self.assertEqual(
            StockBatchBalance.objects.get().remaining_quantity, Decimal("1.000")
        )
        assert_tracking_invariants()

    def test_a_serial_batch_variant_is_valued_per_unit_not_per_lot(self):
        """Two costed identities for one physical object is how a variant ends
        up counted twice."""
        self._receive(["S1"])
        entry = StockLedgerEntry.objects.get(variant=self.variant)
        self.assertEqual(entry.method, "unit_cost")
        unit = StockUnit.objects.get()
        self.assertEqual(unit.incoming_rate, Decimal("40.000000"))

    def test_a_receipt_without_a_lot_is_refused(self):
        with self.assertRaises(serializers.ValidationError) as caught:
            receive(
                variant=self.variant,
                quantity=1,
                unit_cost="40.00",
                units=[{"code": "S1"}],
            )
        self.assertIn("رقم الدفعة مطلوب", str(caught.exception))

    def test_an_expired_lot_is_refused_even_though_the_pack_has_a_serial(self):
        self._receive(["S1"], days=-1)
        with self.assertRaises(serializers.ValidationError) as caught:
            _sell(self.variant, 1, price="90.00")
        self.assertIn("منتهية الصلاحية", str(caught.exception))


class AllocationShapeGuardTests(TestCase):
    """The two rules the database cannot hold, and the service that does."""

    def test_a_serial_batch_unit_written_without_a_batch_is_refused(self):
        product = tracked_product(
            name="لقاح", sku="VAX2", mode=Product.TrackingMode.SERIAL_BATCH
        )
        plan = tracking.TrackedPlan(
            mode=Product.TrackingMode.SERIAL_BATCH,
            direction=StockAllocation.Direction.OUT,
            warehouse_id=Warehouse.default_id(),
        )
        unit = StockUnit.objects.create(
            variant=product.default_variant,
            warehouse_id=Warehouse.default_id(),
            code="S-NOLOT",
            in_stock_since=timezone.now(),
        )
        plan.allocations.append(
            tracking.Allocation(quantity=Decimal("1"), rate=Decimal("1"), unit=unit)
        )
        with self.assertRaises(ValueError) as caught:
            tracking.write_allocations(
                plan, voucher_type="sale", posting_at=timezone.now()
            )
        self.assertIn("must name the lot", str(caught.exception))

    def test_a_batch_allocation_on_a_serialized_variant_is_refused(self):
        product = tracked_product(
            name="هاتف", sku="PH1", mode=Product.TrackingMode.SERIAL,
            unit_price="1500.00",
        )
        lot, _ = tracking.resolve_batch(
            variant=product.default_variant, code="L-1"
        )
        plan = tracking.TrackedPlan(
            mode=Product.TrackingMode.SERIAL,
            direction=StockAllocation.Direction.OUT,
            warehouse_id=Warehouse.default_id(),
        )
        plan.allocations.append(
            tracking.Allocation(quantity=Decimal("2"), rate=Decimal("1"), batch=lot)
        )
        with self.assertRaises(ValueError) as caught:
            tracking.write_allocations(
                plan, voucher_type="sale", posting_at=timezone.now()
            )
        self.assertIn("must name a unit", str(caught.exception))

    def test_an_illegal_status_transition_is_refused_by_name(self):
        product = tracked_product(
            name="هاتف", sku="PH2", mode=Product.TrackingMode.SERIAL,
            unit_price="1500.00",
        )
        unit = StockUnit.objects.create(
            variant=product.default_variant,
            warehouse_id=Warehouse.default_id(),
            code="S-1",
            status=StockUnit.Status.CANCELLED,
        )
        with self.assertRaises(ValueError) as caught:
            tracking.transition_unit(unit, StockUnit.Status.IN_STOCK)
        self.assertIn("not an allowed transition", str(caught.exception))


class ReceiptCancellationTests(TestCase):
    def setUp(self):
        self.product = tracked_product(
            name="iPhone 13 Pro",
            sku="IP13P",
            mode=Product.TrackingMode.SERIAL,
            unit_price="1500.00",
        )
        self.variant = self.product.default_variant

    def test_cancelling_a_receipt_voids_its_units_and_frees_their_codes(self):
        from apps.purchasing import documents as purchase_documents

        receive(
            variant=self.variant,
            quantity=2,
            unit_cost="1200.00",
            units=[{"code": IMEI_A}, {"code": IMEI_B}],
        )
        receipt = PurchaseReceipt.objects.get()
        purchase_documents.reverse_purchase_receipt(
            receipt, at=timezone.now(), actor=None
        )

        self.assertEqual(
            set(StockUnit.objects.values_list("status", flat=True)),
            {StockUnit.Status.CANCELLED},
        )
        # Never deleted: the row is the only record that the identifier was ever
        # here, and a cancelled unit frees its code for the next time it walks in.
        self.assertEqual(StockUnit.objects.count(), 2)
        self.assertIsNone(tracking.find_live_unit(IMEI_A))


class ExpiryCohortCompatibilityTests(TestCase):
    """``tracks_expiry`` without lot control keeps behaving exactly as it did.

    The older, quieter feature — a shop that wants "this milk goes off on the
    12th" and has never heard of a lot number — now runs on the new tables. It
    still creates no allocations and does not change how the stock is costed.
    """

    def setUp(self):
        self.product = tracked_product(
            name="حليب",
            sku="MILK",
            mode=Product.TrackingMode.QUANTITY,
            tracks_expiry=True,
            unit_price="3.00",
        )
        self.variant = self.product.default_variant

    def test_receiving_creates_a_generated_lot_and_a_balance(self):
        receive(
            variant=self.variant,
            quantity=6,
            unit_cost="2.00",
            expiry_date=timezone.localdate() + timedelta(days=10),
        )
        lot = StockBatch.objects.get()
        self.assertTrue(lot.code_is_generated)
        self.assertEqual(lot.display_code, "")
        self.assertEqual(lot.balances.get().remaining_quantity, Decimal("6.000"))
        self.assertEqual(StockAllocation.objects.count(), 0)

    def test_a_sale_draws_the_cohort_down_in_this_warehouse_only(self):
        """The old version consumed a lot in Branch #2 to satisfy a sale in the
        main store, and the model it ran on could not express its way out."""
        receive(
            variant=self.variant,
            quantity=6,
            unit_cost="2.00",
            expiry_date=timezone.localdate() + timedelta(days=10),
        )
        lot = StockBatch.objects.get()
        branch = Warehouse.objects.create(name="فرع 2", code="BR2")
        elsewhere = tracking.lock_balance(
            batch=lot, warehouse=branch, variant=self.variant
        )
        tracking.receive_into_balance(
            balance=elsewhere, quantity=Decimal("4"), rate=Decimal("2.00")
        )

        _sell(self.variant, 2, price="3.00")

        here = lot.balances.get(warehouse_id=Warehouse.default_id())
        elsewhere.refresh_from_db()
        self.assertEqual(here.remaining_quantity, Decimal("4.000"))
        self.assertEqual(elsewhere.remaining_quantity, Decimal("4.000"))

    def test_the_shops_own_valuation_method_still_governs(self):
        receive(
            variant=self.variant,
            quantity=6,
            unit_cost="2.00",
            expiry_date=timezone.localdate() + timedelta(days=10),
        )
        entry = StockLedgerEntry.objects.filter(variant=self.variant).first()
        self.assertEqual(entry.method, ShopSettings.load().inventory_valuation_method)


class TrackingModeTransitionTests(TestCase):
    """Turning tracking on or off re-labels history, so it is guarded.

    Guarded, not forbidden — the same shape as the valuation-method guard, and
    for the same reason: the shop is allowed to change its mind, it is just not
    allowed to change what last year's numbers meant while doing it.
    """

    def _serializer(self, product, mode):
        from apps.catalog.serializers import ProductCatalogSerializer

        return ProductCatalogSerializer(
            product, data={"tracking_mode": mode}, partial=True
        )

    def test_turning_serials_on_with_stock_on_hand_is_refused(self):
        product = tracked_product(
            name="كوكا كولا", sku="MODE-1", mode=Product.TrackingMode.QUANTITY
        )
        receive(variant=product.default_variant, quantity=5, unit_cost="1.00")

        serializer = self._serializer(product, Product.TrackingMode.SERIAL)
        self.assertFalse(serializer.is_valid())
        self.assertIn("tracking_mode", serializer.errors)

    def test_turning_serials_on_with_an_empty_shelf_is_allowed(self):
        product = tracked_product(
            name="كوكا كولا", sku="MODE-2", mode=Product.TrackingMode.QUANTITY
        )
        serializer = self._serializer(product, Product.TrackingMode.SERIAL)
        self.assertTrue(serializer.is_valid(), serializer.errors)

    def test_turning_serials_off_while_units_are_in_stock_is_refused(self):
        product = tracked_product(
            name="هاتف",
            sku="MODE-3",
            mode=Product.TrackingMode.SERIAL,
            unit_price="1500.00",
        )
        receive(
            variant=product.default_variant,
            quantity=1,
            unit_cost="1000.00",
            units=[{"code": "MODE-SER-1"}],
        )

        serializer = self._serializer(product, Product.TrackingMode.QUANTITY)
        self.assertFalse(serializer.is_valid())

    def test_serial_to_serial_batch_grandfathers_existing_units(self):
        """A pharmacy that starts with serials must be able to adopt lots.

        Refusing until history is perfect would mean it never can, which is the
        wrong answer to a shop trying to get more correct.
        """
        from .integrity import units_missing_lots

        product = tracked_product(
            name="لقاح",
            sku="MODE-4",
            mode=Product.TrackingMode.SERIAL,
            unit_price="300.00",
        )
        receive(
            variant=product.default_variant,
            quantity=1,
            unit_cost="100.00",
            units=[{"code": "MODE-PACK-1"}],
        )

        serializer = self._serializer(product, Product.TrackingMode.SERIAL_BATCH)
        self.assertTrue(serializer.is_valid(), serializer.errors)
        serializer.save()

        # The existing unit keeps batch = NULL and lands on the worklist; the
        # next receipt has to name a lot.
        self.assertEqual(units_missing_lots().count(), 1)
        with self.assertRaises(serializers.ValidationError):
            receive(
                variant=product.default_variant,
                quantity=1,
                unit_cost="100.00",
                units=[{"code": "MODE-PACK-2"}],
            )

    def test_serial_batch_back_to_serial_is_free(self):
        """Nothing is unsaid: the lots stop being required and every allocation
        keeps naming the lot it named."""
        product = tracked_product(
            name="لقاح",
            sku="MODE-5",
            mode=Product.TrackingMode.SERIAL_BATCH,
            unit_price="300.00",
        )
        receive(
            variant=product.default_variant,
            quantity=1,
            unit_cost="100.00",
            units=[{"code": "MODE-PACK-3"}],
            batches=[{"code": "MODE-LOT"}],
        )
        serializer = self._serializer(product, Product.TrackingMode.SERIAL)
        self.assertTrue(serializer.is_valid(), serializer.errors)


class IdentifiedStockBlocksACostEditTests(TestCase):
    """Editing a received order un-records its delivery and re-records it.

    That is right for a quantity in a bin and wrong for forty handsets: the
    identifiers were captured at the receiving bay, they are not in an edit
    payload, and a re-record would invent a second set. Until §5.5's re-stamp
    exists, this refuses and names what is in the way.
    """

    def test_a_landed_cost_edit_is_refused_and_names_the_units(self):
        from apps.purchasing.models import PurchaseOrder
        from apps.purchasing.services import save_purchase_order_with_lines

        product = tracked_product(
            name="هاتف",
            sku="LC-1",
            mode=Product.TrackingMode.SERIAL,
            unit_price="1500.00",
        )
        receive(
            variant=product.default_variant,
            quantity=1,
            unit_cost="1000.00",
            units=[{"code": "LC-SER-1"}],
        )
        order = PurchaseOrder.objects.get()

        with self.assertRaises(serializers.ValidationError) as caught:
            save_purchase_order_with_lines(
                purchase_order=order,
                landed_cost_entries_data=[
                    {"label": "شحن", "amount": Decimal("50.00")}
                ],
            )
        detail = caught.exception.detail
        self.assertEqual(
            str(detail["code"]), "purchase_order_has_identified_stock"
        )
        self.assertEqual([str(code) for code in detail["stock_units"]], ["LC-SER-1"])
