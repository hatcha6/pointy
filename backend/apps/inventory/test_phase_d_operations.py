"""Phase D's prerequisite: the four paths that used to raise, and now allocate.

The 2026-09-18 review found that a transfer, a stock count, a manual
adjustment and a job's materials all *raise* on a tracked product, because
``post_movement_valuations`` refuses a tracked movement that names nothing.
That was the right failure and an unusable one, and it is what gated turning
the feature on in a real shop.

Each test here is named after the shop's sentence rather than the code path,
because the standing lesson of §15.2 is that every defect that got through was
invisible to a test suite asking the wrong question.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.utils import timezone
from rest_framework import serializers as drf
from rest_framework.test import APIClient

from apps.catalog.models import Product
from apps.inventory import integrity
from apps.inventory.models import (
    StockBatch,
    StockBatchBalance,
    StockItem,
    StockLedgerEntry,
    StockTransfer,
    StockUnit,
    StockValuationBin,
    Warehouse,
)
from apps.inventory.tracked_testing import receive, tracked_product
from apps.inventory import transfers as transfer_services

User = get_user_model()


def _staff(username="phased", perms=()):
    user = User.objects.create_user(username=username, password="x", is_staff=True)
    if perms:
        from django.contrib.auth.models import Permission

        for label in perms:
            app_label, codename = label.split(".")
            user.user_permissions.add(
                Permission.objects.get(
                    content_type__app_label=app_label, codename=codename
                )
            )
    return user


class ManualAdjustmentNamesWhatItMovedTests(TestCase):
    """A shelf that changes by hand is still a shelf."""

    def setUp(self):
        self.user = _staff(
            "adjuster",
            perms=("inventory.add_stockmovement", "inventory.view_stockmovement"),
        )
        self.client = APIClient()
        self.client.force_authenticate(self.user)

    def _post(self, variant, movement_type, quantity, **extra):
        return self.client.post(
            "/api/stock-movements/",
            {
                "variant": variant.pk,
                "movement_type": movement_type,
                "quantity": str(quantity),
                **extra,
            },
            format="json",
        )

    def test_a_serialized_decrease_with_no_scan_is_refused_and_says_why(self):
        product = tracked_product(
            name="آيفون", sku="ADJ-S", mode=Product.TrackingMode.SERIAL
        )
        variant = product.default_variant
        receive(variant=variant, quantity=2, units=[{"code": "A1"}, {"code": "A2"}])

        response = self._post(variant, "decrease", 1)

        self.assertEqual(response.status_code, 400)
        self.assertIn("مسلسل", str(response.data))
        variant.refresh_from_db()
        self.assertEqual(
            StockItem.objects.get(variant=variant).quantity_on_hand, Decimal("2")
        )

    def test_a_named_handset_leaves_and_the_ledger_says_which(self):
        product = tracked_product(
            name="آيفون", sku="ADJ-N", mode=Product.TrackingMode.SERIAL
        )
        variant = product.default_variant
        receive(
            variant=variant,
            quantity=2,
            unit_cost="500.00",
            units=[{"code": "B1"}, {"code": "B2"}],
        )
        unit = StockUnit.objects.get(code="B1")

        response = self._post(variant, "damaged", 1, units=[unit.pk])

        self.assertEqual(response.status_code, 201, response.data)
        unit.refresh_from_db()
        self.assertEqual(unit.status, StockUnit.Status.DAMAGED)
        allocation = unit.allocations.order_by("-id").first()
        self.assertEqual(allocation.direction, "out")
        self.assertEqual(allocation.rate, Decimal("500.000000"))
        self.assertEqual(integrity.tracking_invariant_violations(), [])

    def test_a_lot_decrease_takes_the_earliest_expiry_without_being_told(self):
        product = tracked_product(
            name="حليب", sku="ADJ-L", mode=Product.TrackingMode.BATCH
        )
        variant = product.default_variant
        today = timezone.localdate()
        receive(
            variant=variant,
            quantity=10,
            unit_cost="3.00",
            batches=[
                {
                    "code": "LATE",
                    "quantity": Decimal("5"),
                    "expiry_date": today.replace(year=today.year + 1),
                },
                {
                    "code": "SOON",
                    "quantity": Decimal("5"),
                    "expiry_date": today,
                },
            ],
        )

        response = self._post(variant, "decrease", 2)

        self.assertEqual(response.status_code, 201, response.data)
        soon = StockBatchBalance.objects.get(batch__code="SOON")
        self.assertEqual(soon.remaining_quantity, Decimal("3.000"))
        self.assertEqual(integrity.tracking_invariant_violations(), [])

    def test_the_bin_finally_follows_a_manual_adjustment(self):
        """It never did. The shelf moved, the stock value did not."""
        product = tracked_product(
            name="سكر", sku="ADJ-B", mode=Product.TrackingMode.QUANTITY
        )
        variant = product.default_variant
        receive(variant=variant, quantity=10, unit_cost="4.00")
        before = StockValuationBin.objects.get(variant=variant)
        self.assertEqual(before.quantity, Decimal("10.000"))

        response = self._post(variant, "decrease", 4)

        self.assertEqual(response.status_code, 201, response.data)
        after = StockValuationBin.objects.get(variant=variant)
        self.assertEqual(after.quantity, Decimal("6.000"))
        self.assertEqual(after.stock_value, Decimal("24.000000"))
        self.assertTrue(
            StockLedgerEntry.objects.filter(
                variant=variant,
                voucher_type=StockLedgerEntry.VoucherType.ADJUSTMENT,
            ).exists()
        )

    def test_an_increase_of_serialized_stock_lands_on_the_worklist(self):
        """Arrived, on the shelf, and owing a number — never refused."""
        product = tracked_product(
            name="آيفون", sku="ADJ-P", mode=Product.TrackingMode.SERIAL
        )
        variant = product.default_variant
        receive(variant=variant, quantity=1, unit_cost="500.00", units=[{"code": "C1"}])

        response = self._post(variant, "increase", 1)

        self.assertEqual(response.status_code, 201, response.data)
        placeholder = StockUnit.objects.get(is_identified=False)
        self.assertEqual(placeholder.status, StockUnit.Status.IN_STOCK)
        self.assertEqual(placeholder.incoming_rate, Decimal("500.000000"))
        self.assertEqual(integrity.tracking_invariant_violations(), [])


class TransferMovesTheArticlesTests(TestCase):
    """Sent five, arrived four, and here is the IMEI of the missing one."""

    def setUp(self):
        self.actor = _staff(
            "driver", perms=("inventory.dispatch_stocktransfer",)
        )
        self.source = Warehouse.objects.get(pk=Warehouse.default_id())
        self.branch = Warehouse.objects.create(name="فرع", code="br")
        self.product = tracked_product(
            name="آيفون", sku="TR-S", mode=Product.TrackingMode.SERIAL
        )
        self.variant = self.product.default_variant
        receive(
            variant=self.variant,
            quantity=3,
            unit_cost="500.00",
            units=[{"code": "T1"}, {"code": "T2"}, {"code": "T3"}],
        )

    def _transfer(self, quantity):
        transfer = StockTransfer.objects.create(
            source=self.source, destination=self.branch
        )
        transfer.lines.create(variant=self.variant, quantity=Decimal(quantity))
        return transfer

    def test_a_serialized_transfer_that_names_nothing_is_refused(self):
        transfer = self._transfer(2)
        with self.assertRaises(drf.ValidationError) as caught:
            transfer_services.dispatch_transfer(transfer, actor=self.actor)
        self.assertIn("مسلسل", str(caught.exception.detail))

    def test_goods_in_a_van_are_sellable_nowhere_and_countable_somewhere(self):
        transfer = self._transfer(2)
        line = transfer.lines.first()
        units = list(StockUnit.objects.filter(code__in=["T1", "T2"]))
        transfer_services.dispatch_transfer(
            transfer,
            actor=self.actor,
            picks={str(line.pk): {"unit_ids": [unit.pk for unit in units]}},
        )

        transit_id = Warehouse.transit_id()
        for unit in units:
            unit.refresh_from_db()
            self.assertEqual(unit.status, StockUnit.Status.IN_TRANSIT)
            self.assertEqual(unit.warehouse_id, transit_id)
        self.assertEqual(
            StockItem.objects.get(
                variant=self.variant, warehouse=self.source
            ).quantity_on_hand,
            Decimal("1"),
        )
        # Invariant 1 counts units per warehouse. A unit whose row still said
        # the source while its quantity sat in transit would make both bins
        # wrong at once.
        self.assertEqual(integrity.tracking_invariant_violations(), [])

    def test_the_far_end_gets_the_same_handsets_at_the_same_cost(self):
        transfer = self._transfer(2)
        line = transfer.lines.first()
        units = list(StockUnit.objects.filter(code__in=["T1", "T2"]))
        transfer_services.dispatch_transfer(
            transfer,
            actor=self.actor,
            picks={str(line.pk): {"unit_ids": [unit.pk for unit in units]}},
        )
        transfer_services.receive_transfer(
            transfer, lines=[(line, Decimal("2"))], actor=self.actor
        )

        for unit in units:
            unit.refresh_from_db()
            self.assertEqual(unit.status, StockUnit.Status.IN_STOCK)
            self.assertEqual(unit.warehouse_id, self.branch.pk)
            self.assertEqual(unit.incoming_rate, Decimal("500.000000"))
        self.assertEqual(
            StockValuationBin.objects.get(
                variant=self.variant, warehouse=self.branch
            ).stock_value,
            Decimal("1000.000000"),
        )
        self.assertEqual(integrity.tracking_invariant_violations(), [])

    def test_a_short_arrival_leaves_the_missing_handset_on_the_road(self):
        transfer = self._transfer(3)
        line = transfer.lines.first()
        units = list(StockUnit.objects.filter(code__in=["T1", "T2", "T3"]))
        transfer_services.dispatch_transfer(
            transfer,
            actor=self.actor,
            picks={str(line.pk): {"unit_ids": [unit.pk for unit in units]}},
        )
        transfer_services.receive_transfer(
            transfer,
            lines=[(line, Decimal("2"))],
            actor=self.actor,
            picks={str(line.pk): {"unit_codes": ["T1", "T2"]}},
        )

        stranded = StockUnit.objects.get(code="T3")
        self.assertEqual(stranded.status, StockUnit.Status.IN_TRANSIT)
        self.assertEqual(integrity.tracking_invariant_violations(), [])

    def test_a_lot_transfer_moves_a_number_and_the_lot_does_not_move(self):
        product = tracked_product(
            name="أموكسيسيلين", sku="TR-L", mode=Product.TrackingMode.BATCH
        )
        variant = product.default_variant
        receive(
            variant=variant,
            quantity=100,
            unit_cost="10.00",
            batches=[{"code": "LOT-A", "quantity": Decimal("100")}],
        )
        lot_before = StockBatch.objects.values().get(code_normalized="LOTA")

        transfer = StockTransfer.objects.create(
            source=self.source, destination=self.branch
        )
        line = transfer.lines.create(variant=variant, quantity=Decimal("25"))
        transfer_services.dispatch_transfer(transfer, actor=self.actor)
        transfer_services.receive_transfer(
            transfer, lines=[(line, Decimal("25"))], actor=self.actor
        )

        self.assertEqual(
            StockBatch.objects.values().get(code_normalized="LOTA"), lot_before
        )
        self.assertEqual(StockBatch.objects.count(), 1)
        self.assertEqual(
            StockBatchBalance.objects.get(
                warehouse=self.branch
            ).remaining_quantity,
            Decimal("25.000"),
        )
        self.assertEqual(integrity.tracking_invariant_violations(), [])


class ScanTheShelfTests(TestCase):
    """Counting a number of serialized articles is meaningless."""

    def setUp(self):
        self.user = _staff(
            "counter",
            perms=(
                "inventory.add_stockcount",
                "inventory.change_stockcount",
                "inventory.view_stockcount",
                "inventory.apply_stockcount",
            ),
        )
        self.client = APIClient()
        self.client.force_authenticate(self.user)
        self.product = tracked_product(
            name="آيفون", sku="SC-S", mode=Product.TrackingMode.SERIAL
        )
        self.variant = self.product.default_variant
        receive(
            variant=self.variant,
            quantity=3,
            unit_cost="500.00",
            units=[{"code": "S1"}, {"code": "S2"}, {"code": "S3"}],
        )
        self.count = self.client.post(
            "/api/stock-counts/start/", {"scope": "full"}, format="json"
        ).data

    def _scan(self, code):
        return self.client.post(
            f"/api/stock-counts/{self.count['id']}/scan/", {"code": code},
            format="json",
        )

    def test_typing_a_number_for_a_serialized_variant_is_refused(self):
        response = self.client.post(
            f"/api/stock-counts/{self.count['id']}/count/",
            {"variant": self.variant.pk, "counted_quantity": "3"},
            format="json",
        )
        self.assertEqual(response.status_code, 400)
        self.assertIn("امسح", str(response.data))

    def test_the_same_handset_scanned_twice_is_one_handset(self):
        self.assertEqual(self._scan("S1").status_code, 201)
        second = self._scan("S1")
        self.assertEqual(second.status_code, 200)
        self.assertFalse(second.data["created"])
        self.assertEqual(
            self.client.get(
                f"/api/stock-counts/{self.count['id']}/scan-reconciliation/"
            ).data["scanned"],
            1,
        )

    def test_the_one_that_was_not_scanned_is_written_off_at_its_own_cost(self):
        self._scan("S1")
        self._scan("S2")
        found = self.client.get(
            f"/api/stock-counts/{self.count['id']}/scan-reconciliation/"
        ).data
        self.assertEqual([row["code"] for row in found["missing"]], ["S3"])

        applied = self.client.post(
            f"/api/stock-counts/{self.count['id']}/apply/", {}, format="json"
        )
        self.assertEqual(applied.status_code, 200, applied.data)
        missing = StockUnit.objects.get(code="S3")
        self.assertEqual(missing.status, StockUnit.Status.WRITTEN_OFF)
        self.assertEqual(
            StockItem.objects.get(variant=self.variant).quantity_on_hand,
            Decimal("2"),
        )
        self.assertEqual(integrity.tracking_invariant_violations(), [])

    def test_a_code_nobody_has_seen_becomes_a_unit_on_the_worklist(self):
        for code in ("S1", "S2", "S3"):
            self._scan(code)
        self.client.post(
            f"/api/stock-counts/{self.count['id']}/scan/",
            {"code": "S-STRANGER", "variant": self.variant.pk},
            format="json",
        )

        found = self.client.get(
            f"/api/stock-counts/{self.count['id']}/scan-reconciliation/"
        ).data
        self.assertEqual([row["code"] for row in found["unknown"]], ["S-STRANGER"])

        self.client.post(
            f"/api/stock-counts/{self.count['id']}/apply/", {}, format="json"
        )
        self.assertEqual(
            StockItem.objects.get(variant=self.variant).quantity_on_hand,
            Decimal("4"),
        )
        self.assertEqual(integrity.tracking_invariant_violations(), [])

    def test_one_missing_and_one_found_are_two_events_not_a_net_of_zero(self):
        """The shelf counts the same either way, and the articles do not.

        A net of zero would write nothing at all: the missing handset still in
        stock, the found one still not existing, and a count that reported
        itself clean. This is exactly the shape §15.2 warns about — a defect
        invisible to a test that only ever checks the quantity.
        """
        self._scan("S1")
        self._scan("S2")
        # S3 never turns up; something nobody has seen does.
        self.client.post(
            f"/api/stock-counts/{self.count['id']}/scan/",
            {"code": "S-STRANGER", "variant": self.variant.pk},
            format="json",
        )

        applied = self.client.post(
            f"/api/stock-counts/{self.count['id']}/apply/", {}, format="json"
        )
        self.assertEqual(applied.status_code, 200, applied.data)

        self.assertEqual(
            StockUnit.objects.get(code="S3").status,
            StockUnit.Status.WRITTEN_OFF,
        )
        self.assertTrue(
            StockUnit.objects.filter(code="S-STRANGER").exists(),
            "the found article has to exist, not merely cancel the missing one",
        )
        # And the shelf is still three, which is the number that would have
        # made a netting bug invisible.
        self.assertEqual(
            StockItem.objects.get(variant=self.variant).quantity_on_hand,
            Decimal("3"),
        )
        self.assertEqual(integrity.tracking_invariant_violations(), [])

    def test_a_handset_found_here_that_the_books_had_elsewhere_is_relocated(self):
        branch = Warehouse.objects.create(name="فرع", code="br2")
        stray = StockUnit.objects.get(code="S3")
        # Put it in the other branch the way a real drift would: the row says
        # one place, the shelf holds another.
        StockItem.objects.get_or_create(variant=self.variant, warehouse=branch)
        from apps.inventory.services import lock_stock_item, save_stock_item_quantities

        here = lock_stock_item(variant=self.variant, warehouse=None)
        here.quantity_on_hand -= Decimal("1")
        save_stock_item_quantities(here)
        there = lock_stock_item(variant=self.variant, warehouse=branch)
        there.quantity_on_hand += Decimal("1")
        save_stock_item_quantities(there)
        stray.warehouse = branch
        stray.save(update_fields=["warehouse", "updated_at"])

        for code in ("S1", "S2", "S3"):
            self._scan(code)
        found = self.client.get(
            f"/api/stock-counts/{self.count['id']}/scan-reconciliation/"
        ).data
        self.assertEqual([row["code"] for row in found["relocated"]], ["S3"])

        self.client.post(
            f"/api/stock-counts/{self.count['id']}/apply/", {}, format="json"
        )
        stray.refresh_from_db()
        self.assertEqual(stray.warehouse_id, Warehouse.default_id())
        self.assertEqual(stray.status, StockUnit.Status.IN_STOCK)


class LotCountIsPerBalanceTests(TestCase):
    """A counter stands in one room counting the packs of one lot."""

    def setUp(self):
        self.user = _staff(
            "lotcounter",
            perms=(
                "inventory.add_stockcount",
                "inventory.change_stockcount",
                "inventory.view_stockcount",
                "inventory.apply_stockcount",
            ),
        )
        self.client = APIClient()
        self.client.force_authenticate(self.user)
        self.product = tracked_product(
            name="أموكسيسيلين", sku="SC-L", mode=Product.TrackingMode.BATCH
        )
        self.variant = self.product.default_variant
        receive(
            variant=self.variant,
            quantity=30,
            unit_cost="10.00",
            batches=[
                {"code": "L-A", "quantity": Decimal("20")},
                {"code": "L-B", "quantity": Decimal("10")},
            ],
        )
        self.count = self.client.post(
            "/api/stock-counts/start/", {"scope": "full"}, format="json"
        ).data

    def test_counting_a_lot_tracked_variant_without_naming_a_lot_is_refused(self):
        response = self.client.post(
            f"/api/stock-counts/{self.count['id']}/count/",
            {"variant": self.variant.pk, "counted_quantity": "30"},
            format="json",
        )
        self.assertEqual(response.status_code, 400)
        self.assertIn("الدفعة", str(response.data))

    def test_the_variance_is_against_that_lot_and_leaves_the_other_alone(self):
        lot_a = StockBatch.objects.get(code_normalized="LA")
        response = self.client.post(
            f"/api/stock-counts/{self.count['id']}/count/",
            {
                "variant": self.variant.pk,
                "batch": lot_a.pk,
                "counted_quantity": "18",
            },
            format="json",
        )
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(Decimal(str(response.data["expected_quantity"])), Decimal("20"))

        self.client.post(
            f"/api/stock-counts/{self.count['id']}/apply/", {}, format="json"
        )
        self.assertEqual(
            StockBatchBalance.objects.get(batch=lot_a).remaining_quantity,
            Decimal("18.000"),
        )
        self.assertEqual(
            StockBatchBalance.objects.get(
                batch__code_normalized="LB"
            ).remaining_quantity,
            Decimal("10.000"),
        )
        self.assertEqual(integrity.tracking_invariant_violations(), [])


class OpeningIdentificationTests(TestCase):
    """Forty anonymous iPhones, and the shop cannot lose them."""

    def setUp(self):
        self.user = _staff(
            "opener",
            perms=("inventory.add_stockunit", "inventory.view_stockunit"),
        )
        self.client = APIClient()
        self.client.force_authenticate(self.user)

    def _anonymous_stock(self, mode, quantity, cost="500.00"):
        product = tracked_product(
            name="آيفون", sku=f"OP-{mode}", mode=Product.TrackingMode.QUANTITY
        )
        variant = product.default_variant
        receive(variant=variant, quantity=quantity, unit_cost=cost)
        # The shop flips the switch. The guard allows it only through this run,
        # so the test sets the mode the way the migration path does.
        product.tracking_mode = mode
        product.save(update_fields=["tracking_mode", "updated_at"])
        return product, variant

    def test_the_bin_is_unchanged_by_construction(self):
        product, variant = self._anonymous_stock(Product.TrackingMode.SERIAL, 3)
        before = StockValuationBin.objects.get(variant=variant)

        response = self.client.post(
            "/api/stock-units/identify-opening/",
            {
                "variant": variant.pk,
                "units": [{"code": "O1"}, {"code": "O2"}, {"code": "O3"}],
            },
            format="json",
        )

        self.assertEqual(response.status_code, 201, response.data)
        after = StockValuationBin.objects.get(variant=variant)
        self.assertEqual(after.quantity, before.quantity)
        self.assertEqual(after.stock_value, before.stock_value)
        self.assertEqual(
            sorted(
                StockUnit.objects.filter(variant=variant).values_list(
                    "incoming_rate", flat=True
                )
            ),
            [Decimal("500.000000")] * 3,
        )
        self.assertEqual(integrity.tracking_invariant_violations(), [])

    def test_a_half_finished_run_is_refused_unless_it_says_it_is_half_finished(self):
        product, variant = self._anonymous_stock(Product.TrackingMode.SERIAL, 3)

        refused = self.client.post(
            "/api/stock-units/identify-opening/",
            {"variant": variant.pk, "units": [{"code": "P1"}]},
            format="json",
        )
        self.assertEqual(refused.status_code, 400)

        allowed = self.client.post(
            "/api/stock-units/identify-opening/",
            {
                "variant": variant.pk,
                "units": [{"code": "P1"}],
                "capture_later": True,
            },
            format="json",
        )
        self.assertEqual(allowed.status_code, 201, allowed.data)
        self.assertEqual(
            StockUnit.objects.filter(variant=variant, is_identified=False).count(), 2
        )

    def test_the_worklist_names_what_is_still_anonymous(self):
        product, variant = self._anonymous_stock(Product.TrackingMode.SERIAL, 4)
        rows = self.client.get("/api/stock-units/opening-worklist/").data
        self.assertEqual(len(rows), 1)
        self.assertEqual(Decimal(str(rows[0]["outstanding"])), Decimal("4"))
