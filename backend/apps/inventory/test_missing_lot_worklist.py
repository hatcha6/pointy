"""The missing-lot worklist: grandfathered units given the lot they never had.

``serial → serial_batch`` keeps the units already on the shelf with
``batch = NULL`` (§4.2). They can be sold, but no recall can find them, and
until this worklist nothing could give them a lot. Every test that writes ends
by asserting the whole set of identified-stock invariants, because the one
thing an assignment must not do is leave a balance, a bin or a history that
disagrees with the units it touched.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.db import connection
from django.test import TestCase
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.models import Product
from apps.catalog.serializers import ProductCatalogSerializer
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.sales.models import RegisterSession
from apps.sales.services import checkout_order

from . import transfers as transfer_services
from .integrity import assert_tracking_invariants
from .models import (
    StockAllocation,
    StockBatch,
    StockBatchBalance,
    StockLedgerEntry,
    StockTransfer,
    StockTransferLine,
    StockUnit,
    StockUnitEvent,
    StockValuationBin,
    Warehouse,
)
from .tracked_testing import receive, tracked_product

_SEQUENCE = 0


def _switch(product, mode):
    serializer = ProductCatalogSerializer(
        product, data={"tracking_mode": mode}, partial=True
    )
    serializer.is_valid(raise_exception=True)
    serializer.save()
    product.refresh_from_db()
    return product


def _sell(variant, unit, *, price="300.00"):
    global _SEQUENCE
    _SEQUENCE += 1
    session = RegisterSession.objects.create(
        owner_key=f"lot-worklist-till-{_SEQUENCE}",
        status=RegisterSession.Status.OPEN,
        opening_cash=Decimal("0.00"),
    )
    return checkout_order(
        register_session=session,
        lines_data=[
            {"variant": variant, "quantity": Decimal("1"), "stock_units": [unit.pk]}
        ],
        payments_data=[{"method": "cash", "amount": Decimal(price)}],
    )


def _user(*, manager=False, permissions=()):
    global _SEQUENCE
    _SEQUENCE += 1
    user = get_user_model().objects.create_user(
        username=f"lot-worklist-{_SEQUENCE}", password="pw"
    )
    if manager:
        user.groups.add(Group.objects.get(name=MANAGER_GROUP))
    for codename in permissions:
        app_label, code = codename.split(".")
        user.user_permissions.add(
            Permission.objects.get(content_type__app_label=app_label, codename=code)
        )
    return user


def _rows(response):
    payload = response.data
    return payload["results"] if isinstance(payload, dict) else payload


class MissingLotWorklistTestCase(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.product = tracked_product(
            name="أنسولين",
            sku="ML-INS",
            mode=Product.TrackingMode.SERIAL,
            unit_price="300.00",
        )
        self.variant = self.product.default_variant
        receive(
            variant=self.variant,
            quantity=3,
            unit_cost="90.00",
            units=[{"code": f"ML-PACK-{n}"} for n in (1, 2, 3)],
        )
        _switch(self.product, Product.TrackingMode.SERIAL_BATCH)
        self.units = list(StockUnit.objects.filter(variant=self.variant).order_by("pk"))
        self.client = APIClient()
        self.client.force_authenticate(user=_user(manager=True))

    def _assign(self, units, **payload):
        return self.client.post(
            reverse("stock-unit-assign-lot"),
            {"variant": self.variant.pk, "units": [unit.pk for unit in units], **payload},
            format="json",
        )

    def _bin_value(self):
        return sum(
            (row.stock_value for row in StockValuationBin.objects.filter(variant=self.variant)),
            Decimal("0"),
        )


class WorklistReadTests(MissingLotWorklistTestCase):
    def test_groups_list_each_variant_owing_lots_with_its_count(self):
        response = self.client.get(reverse("stock-unit-missing-lot-groups"))

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(len(response.data), 1)
        group = response.data[0]
        self.assertEqual(group["variant"], self.variant.pk)
        self.assertEqual(group["product_name"], "أنسولين")
        self.assertEqual(group["count"], 3)

    def test_the_units_are_listed_a_page_at_a_time_and_found_by_scan(self):
        response = self.client.get(
            reverse("stock-unit-missing-lots"), {"variant": self.variant.pk}
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            [row["code"] for row in _rows(response)],
            ["ML-PACK-1", "ML-PACK-2", "ML-PACK-3"],
        )

        response = self.client.get(
            reverse("stock-unit-missing-lots"), {"code": "ml pack 2"}
        )
        self.assertEqual([row["code"] for row in _rows(response)], ["ML-PACK-2"])

    def test_the_summary_counts_what_the_worklist_owes(self):
        response = self.client.get(reverse("stock-unit-summary"))
        self.assertEqual(response.data["missing_lots"], 3)

    def test_a_product_that_never_switched_owes_nothing(self):
        other = tracked_product(
            name="علبة", sku="ML-BOX", mode=Product.TrackingMode.SERIAL_BATCH
        )
        receive(
            variant=other.default_variant,
            quantity=1,
            units=[{"code": "ML-BOX-1"}],
            batches=[{"code": "BOX-L1"}],
        )
        response = self.client.get(reverse("stock-unit-missing-lot-groups"))
        self.assertEqual([group["variant"] for group in response.data], [self.variant.pk])

    def test_the_list_costs_the_same_for_three_units_as_for_thirty(self):
        url = reverse("stock-unit-missing-lots")
        with CaptureQueriesContext(connection) as small:
            self.client.get(url)
        # Back to plain serials for a delivery, then lots again: twenty-seven
        # more grandfathered packs, made the only way history makes them.
        _switch(self.product, Product.TrackingMode.SERIAL)
        receive(
            variant=self.variant,
            quantity=27,
            units=[{"code": f"ML-FILL-{n}"} for n in range(27)],
        )
        _switch(self.product, Product.TrackingMode.SERIAL_BATCH)
        self.assertEqual(
            len(_rows(self.client.get(url, {"page_size": 50}))), 30
        )
        with CaptureQueriesContext(connection) as large:
            self.client.get(url, {"page_size": 50})
        self.assertEqual(len(large), len(small))


class AssignLotTests(MissingLotWorklistTestCase):
    def test_a_new_lot_takes_the_units_and_nothing_moves(self):
        value_before = self._bin_value()
        ledger_before = StockLedgerEntry.objects.filter(variant=self.variant).count()

        response = self._assign(
            self.units[:2], lot_code="INS-2029", expiry_date="2029-06-30"
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertTrue(response.data["created"])
        self.assertEqual(response.data["assigned"], 2)
        lot = StockBatch.objects.get(variant=self.variant, code="INS-2029")
        self.assertEqual(str(lot.expiry_date), "2029-06-30")
        balance = StockBatchBalance.objects.get(batch=lot)
        self.assertEqual(balance.remaining_quantity, Decimal("2"))
        self.assertEqual(balance.received_quantity, Decimal("2"))
        self.assertEqual(balance.incoming_rate, Decimal("90"))
        self.assertEqual(
            set(StockUnit.objects.filter(batch=lot).values_list("pk", flat=True)),
            {unit.pk for unit in self.units[:2]},
        )
        self.assertEqual(
            StockUnitEvent.objects.filter(kind=StockUnitEvent.Kind.LOT_ASSIGNED).count(),
            2,
        )
        # Value-neutral: no ledger entry, no allocation, the same stock value.
        self.assertEqual(StockLedgerEntry.objects.filter(variant=self.variant).count(), ledger_before)
        self.assertEqual(self._bin_value(), value_before)
        self.assertEqual(
            self.client.get(reverse("stock-unit-summary")).data["missing_lots"], 1
        )
        assert_tracking_invariants()

    def test_an_existing_lot_adds_to_its_balance_here(self):
        receive(
            variant=self.variant,
            quantity=1,
            unit_cost="120.00",
            units=[{"code": "ML-NEW-1"}],
            batches=[{"code": "INS-OLD"}],
        )
        lot = StockBatch.objects.get(variant=self.variant, code="INS-OLD")

        response = self._assign(self.units, batch=lot.pk)

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertFalse(response.data["created"])
        balance = StockBatchBalance.objects.get(batch=lot)
        self.assertEqual(balance.remaining_quantity, Decimal("4"))
        # (120 + 3 × 90) / 4: re-weighted like a second delivery of the lot.
        self.assertEqual(balance.incoming_rate, Decimal("97.5"))
        assert_tracking_invariants()

    def test_a_typed_code_the_variant_already_knows_is_that_lot(self):
        receive(
            variant=self.variant,
            quantity=1,
            units=[{"code": "ML-NEW-2"}],
            batches=[{"code": "INS-KNOWN"}],
        )

        response = self._assign(self.units[:1], lot_code="ins-known")

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertFalse(response.data["created"])
        self.assertEqual(StockBatch.objects.filter(variant=self.variant).count(), 1)
        assert_tracking_invariants()

    def test_an_assigned_unit_sells_out_of_its_lot(self):
        self._assign(self.units[:1], lot_code="INS-SELL")
        lot = StockBatch.objects.get(code="INS-SELL")

        _sell(self.variant, self.units[0])

        allocation = StockAllocation.objects.get(
            unit=self.units[0], direction=StockAllocation.Direction.OUT
        )
        self.assertEqual(allocation.batch_id, lot.pk)
        self.assertEqual(
            StockBatchBalance.objects.get(batch=lot).remaining_quantity, Decimal("0")
        )
        assert_tracking_invariants()

    def test_a_unit_that_moved_lot_less_before_its_lot_keeps_a_clean_history(self):
        """Invariant 14 used to read a grandfathered unit's *current* lot: a
        unit that travelled without one and was then given one made its own
        journey a violation."""
        store = Warehouse.objects.create(
            name="المخزن", code="ml-store", kind=Warehouse.Kind.STORE_ROOM
        )
        transfer = StockTransfer.objects.create(
            source_id=Warehouse.default_id(), destination=store
        )
        line = StockTransferLine.objects.create(
            transfer=transfer, variant=self.variant, quantity=Decimal("1")
        )
        actor = _user(manager=True)
        transfer_services.dispatch_transfer(
            transfer,
            actor=actor,
            picks={line.pk: {"unit_ids": [self.units[0].pk]}},
        )
        transfer_services.receive_transfer(
            transfer, lines=[(line, Decimal("1"))], actor=actor
        )
        assert_tracking_invariants()

        response = self._assign(self.units[:1], lot_code="INS-TRAVEL")

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        lot = StockBatch.objects.get(code="INS-TRAVEL")
        # The balance is where the unit is, not where it was born.
        self.assertEqual(
            StockBatchBalance.objects.get(batch=lot, warehouse=store).remaining_quantity,
            Decimal("1"),
        )
        assert_tracking_invariants()


class AssignLotRefusalTests(MissingLotWorklistTestCase):
    def test_a_unit_that_already_has_a_lot_is_refused(self):
        self._assign(self.units[:1], lot_code="INS-A")

        response = self._assign(self.units[:1], lot_code="INS-B")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertFalse(StockBatch.objects.filter(code="INS-B").exists())
        assert_tracking_invariants()

    def test_a_known_code_with_another_expiry_is_the_receipts_conflict(self):
        receive(
            variant=self.variant,
            quantity=1,
            units=[{"code": "ML-NEW-3"}],
            batches=[{"code": "INS-DATED", "expiry_date": "2030-01-31"}],
        )

        response = self._assign(
            self.units[:1], lot_code="INS-DATED", expiry_date="2031-01-31"
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["conflicts"][0]["kind"], "batch_expiry")
        self.units[0].refresh_from_db()
        self.assertIsNone(self.units[0].batch_id)

    def test_a_new_lot_of_a_product_that_owes_its_date_needs_one(self):
        """Receiving would refuse a lot of this product without an expiry; so
        does naming one here, and the lot it was about to create goes too."""
        Product.objects.filter(pk=self.product.pk).update(expiry_required=True)
        groups = self.client.get(reverse("stock-unit-missing-lot-groups")).data
        self.assertTrue(groups[0]["expiry_required"])

        response = self._assign(self.units[:1], lot_code="INS-NODATE")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("expiry_date", response.data)
        self.assertFalse(StockBatch.objects.filter(code="INS-NODATE").exists())

        response = self._assign(
            self.units[:1], lot_code="INS-DATED-OK", expiry_date="2030-03-31"
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        assert_tracking_invariants()

    def test_another_variants_lot_is_refused(self):
        other = tracked_product(name="شراب", sku="ML-SYR", mode=Product.TrackingMode.BATCH)
        receive(
            variant=other.default_variant,
            quantity=2,
            batches=[{"code": "SYR-1", "quantity": 2}],
        )
        foreign = StockBatch.objects.get(code="SYR-1")

        response = self._assign(self.units[:1], batch=foreign.pk)

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_a_product_not_tracked_in_lots_is_refused(self):
        _switch(self.product, Product.TrackingMode.SERIAL)

        response = self._assign(self.units[:1], lot_code="INS-X")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_naming_both_or_neither_is_refused(self):
        self.assertEqual(
            self._assign(self.units[:1]).status_code, status.HTTP_400_BAD_REQUEST
        )

    def test_a_reader_without_the_identify_permission_cannot_assign(self):
        self.client.force_authenticate(
            user=_user(permissions=["inventory.view_stockunit"])
        )
        self.assertEqual(
            self.client.get(reverse("stock-unit-missing-lots")).status_code,
            status.HTTP_200_OK,
        )
        response = self._assign(self.units[:1], lot_code="INS-NOPE")
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
