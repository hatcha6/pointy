"""Moving stock between a shop's places.

The first block is ported from ERPNext's ``test_stock_entry.py``, translated
into this system's vocabulary — their Material Transfer with ``add_to_transit``
is our dispatch-plus-receipt, and the invariants they assert about quantity,
conversion, negative balances and cancellation are the same invariants whatever
the schema. Their manufacturing, BOM and subcontracting tests have no analogue
here and are not ported: we refuse those features outright.

The second block is ours, and it is mostly about *value*. A box carried across
the room is worth what it was worth before it was picked up, and the shop's
total stock value must not so much as flicker while it is on the road.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase

from apps.catalog.testing import create_product_with_default_variant
from apps.core.models import ShopSettings
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.documents.errors import DocumentBlocked
from apps.documents.statuses import DocumentStatus
from apps.inventory import transfers as transfer_services
from apps.inventory.models import (
    StockItem,
    StockLedgerEntry,
    StockMovement,
    StockTransfer,
    StockTransferLine,
    Warehouse,
)
from apps.inventory.reporting import stock_cost_value
from apps.inventory.services import (
    build_stock_movement,
    create_stock_movements,
    lock_stock_item,
    save_stock_item_quantities,
    stock_snapshot,
)


def D(value):
    return Decimal(str(value))


class TransferTestCase(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.user = get_user_model().objects.create_user(username="m", password="p")
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.showroom = Warehouse.objects.get(pk=Warehouse.default_id())
        self.store = Warehouse.objects.create(
            name="المخزن", code="store", kind=Warehouse.Kind.STORE_ROOM
        )
        product = create_product_with_default_variant(
            name="أرز", sku="TR-1", barcode="", unit_price=D("10.00")
        )
        self.variant = product.default_variant

    # -- helpers ---------------------------------------------------------

    def stock(self, warehouse, quantity, unit_cost, variant=None):
        """Put valued stock in a place, the way a delivery would."""
        variant = variant or self.variant
        item = lock_stock_item(variant=variant, warehouse=warehouse)
        before = stock_snapshot(item)
        item.quantity_on_hand += D(quantity)
        save_stock_item_quantities(item)
        movement = build_stock_movement(
            stock_item=item,
            movement_type=StockMovement.Type.INCREASE,
            quantity=D(quantity),
            note="seed",
            created_by=self.user,
            before=before,
        )
        # ``create_stock_movements`` inserts *and* values in one call; the
        # warehouse is read off the movements themselves.
        create_stock_movements(
            [movement],
            voucher_type=StockLedgerEntry.VoucherType.ADJUSTMENT,
            unit_costs={variant.pk: D(unit_cost)},
        )
        return item

    def on_hand(self, warehouse, variant=None):
        variant = variant or self.variant
        row = StockItem.objects.filter(
            variant=variant or self.variant, warehouse=warehouse
        ).first()
        return row.quantity_on_hand if row else D("0.000")

    def transit(self, variant=None):
        return self.on_hand(
            Warehouse.objects.get(pk=Warehouse.transit_id()), variant=variant
        )

    def build_transfer(self, quantity="4", *, unit="", factor="1", variant=None):
        transfer = StockTransfer.objects.create(
            source=self.showroom, destination=self.store
        )
        StockTransferLine.objects.create(
            transfer=transfer,
            variant=variant or self.variant,
            quantity=D(quantity),
            unit=unit,
            unit_factor=D(factor),
        )
        return transfer

    def dispatch(self, transfer):
        return transfer_services.dispatch_transfer(transfer, actor=self.user)

    def receive(self, transfer, quantity=None):
        line = transfer.lines.first()
        quantity = line.outstanding_quantity if quantity is None else D(quantity)
        return transfer_services.receive_transfer(
            transfer, lines=[(line, quantity)], actor=self.user
        )


class PortedFromErpNextTests(TransferTestCase):
    def test_a_transfer_of_zero_or_less_is_refused(self):
        """Their ``test_stock_entry_qty``: refused at submission, not ignored."""
        self.stock(self.showroom, "10", "5.00")
        for bad in ("0", "-3"):
            transfer = self.build_transfer(bad)
            with self.assertRaises(Exception):
                self.dispatch(transfer)

    def test_a_dispatch_parks_the_goods_in_transit_and_a_receipt_clears_it(self):
        """Their ``test_add_to_transit_entry``: the interim warehouse holds the
        stock, and the transfer's progress follows the receipt."""
        self.stock(self.showroom, "10", "5.00")
        transfer = self.build_transfer("4")

        self.dispatch(transfer)
        transfer.refresh_from_db()
        self.assertEqual(self.on_hand(self.showroom), D("6.000"))
        self.assertEqual(self.transit(), D("4.000"))
        self.assertEqual(self.on_hand(self.store), D("0.000"))
        self.assertEqual(transfer.status, StockTransfer.Status.IN_TRANSIT)

        self.receive(transfer)
        transfer.refresh_from_db()
        self.assertEqual(self.transit(), D("0.000"))
        self.assertEqual(self.on_hand(self.store), D("4.000"))
        self.assertEqual(transfer.status, StockTransfer.Status.RECEIVED)

    def test_more_cannot_be_received_than_is_on_the_road(self):
        """Their ``test_transfer_qty_validation``."""
        self.stock(self.showroom, "10", "5.00")
        transfer = self.build_transfer("4")
        self.dispatch(transfer)
        with self.assertRaises(Exception):
            self.receive(transfer, "5")

    def test_a_line_moves_its_unit_converted_to_base(self):
        """Their conversion-factor case: two cartons of twelve is twenty-four
        pieces off the shelf, not two."""
        self.stock(self.showroom, "100", "1.00")
        transfer = self.build_transfer("2", unit="carton", factor="12")
        self.dispatch(transfer)
        self.assertEqual(self.on_hand(self.showroom), D("76.000"))
        self.assertEqual(self.transit(), D("24.000"))

    def test_a_transfer_cannot_drive_the_source_below_zero(self):
        """Their ``test_future_negative_sle``, at the source end."""
        self.stock(self.showroom, "3", "5.00")
        transfer = self.build_transfer("4")
        with self.assertRaises(Exception):
            self.dispatch(transfer)
        self.assertEqual(self.on_hand(self.showroom), D("3.000"))
        self.assertEqual(self.transit(), D("0.000"))

    def test_a_place_that_allows_it_may_go_below_zero(self):
        """Their #12651, which they cannot express: the policy is per place."""
        self.showroom.allow_overselling = Warehouse.OversellPolicy.ALLOW
        self.showroom.save(update_fields=["allow_overselling", "updated_at"])
        self.stock(self.showroom, "3", "5.00")
        transfer = self.build_transfer("4")
        self.dispatch(transfer)
        self.assertEqual(self.on_hand(self.showroom), D("-1.000"))

    def test_cancelling_a_dispatch_brings_the_goods_back(self):
        """Their cancellation invariant: undoing a stock entry returns the
        position it took, and leaves the trail saying so."""
        self.stock(self.showroom, "10", "5.00")
        transfer = self.build_transfer("4")
        self.dispatch(transfer)

        from apps.documents import services as document_services

        document_services.cancel(transfer, reason="wrong van", actor=self.user)
        transfer.refresh_from_db()
        self.assertEqual(self.on_hand(self.showroom), D("10.000"))
        self.assertEqual(self.transit(), D("0.000"))
        self.assertEqual(transfer.doc_status, DocumentStatus.CANCELLED)
        self.assertEqual(transfer.status, StockTransfer.Status.CANCELLED)

    def test_a_dispatch_cannot_be_undone_while_an_arrival_stands(self):
        """Where ERPNext cascades, we refuse. Cancelling the dispatch would
        otherwise reach into the destination's shelves without anyone asking."""
        self.stock(self.showroom, "10", "5.00")
        transfer = self.build_transfer("4")
        self.dispatch(transfer)
        self.receive(transfer)

        from apps.documents import services as document_services

        with self.assertRaises(DocumentBlocked):
            document_services.cancel(transfer, reason="x", actor=self.user)

    def test_undoing_an_arrival_puts_it_back_on_the_road(self):
        self.stock(self.showroom, "10", "5.00")
        transfer = self.build_transfer("4")
        self.dispatch(transfer)
        receipt = self.receive(transfer)

        from apps.documents import services as document_services

        document_services.cancel(receipt, reason="wrong shelf", actor=self.user)
        transfer.refresh_from_db()
        self.assertEqual(self.on_hand(self.store), D("0.000"))
        self.assertEqual(self.transit(), D("4.000"))
        self.assertEqual(transfer.lines.first().received_quantity, D("0.000"))

    def test_an_arrival_cannot_be_undone_once_the_goods_have_been_sold_on(self):
        """Their ``test_negative_batch`` corner: a receipt whose stock has since
        left cannot be cancelled, only corrected by a return."""
        self.stock(self.showroom, "10", "5.00")
        transfer = self.build_transfer("4")
        self.dispatch(transfer)
        receipt = self.receive(transfer)

        # Something takes the goods off the destination's shelf.
        row = lock_stock_item(variant=self.variant, warehouse=self.store)
        row.quantity_on_hand = D("1.000")
        save_stock_item_quantities(row)

        from apps.documents import services as document_services

        with self.assertRaises(Exception):
            document_services.cancel(receipt, reason="x", actor=self.user)


class ValueCarriesTests(TransferTestCase):
    """A box carried across the room is worth what it was worth."""

    def test_the_shops_stock_value_does_not_move_when_stock_does(self):
        self.stock(self.showroom, "10", "5.00")
        before = stock_cost_value()

        transfer = self.build_transfer("4")
        self.dispatch(transfer)
        self.assertEqual(
            stock_cost_value(), before, "value changed while goods were in transit"
        )
        self.receive(transfer)
        self.assertEqual(
            stock_cost_value(), before, "value changed on arrival"
        )

    def test_the_goods_arrive_at_the_cost_they_left_at(self):
        """No rate is invented anywhere: issuing from the source decides it, and
        the receiving leg is told what it was."""
        from apps.inventory.models import StockValuationBin

        self.stock(self.showroom, "10", "5.00")
        transfer = self.build_transfer("4")
        self.dispatch(transfer)
        self.receive(transfer)

        destination = StockValuationBin.objects.get(
            variant=self.variant, warehouse=self.store
        )
        self.assertEqual(destination.quantity, D("4.000"))
        self.assertEqual(destination.valuation_rate, D("5.000000"))
        self.assertEqual(destination.stock_value, D("20.000000"))

    def test_a_transfer_books_no_profit(self):
        """The ledger entries for a move must net to zero: what leaves one place
        at cost arrives at the next at the same cost."""
        self.stock(self.showroom, "10", "5.00")
        transfer = self.build_transfer("4")
        self.dispatch(transfer)
        self.receive(transfer)

        moved = StockLedgerEntry.objects.filter(
            voucher_type__in=(
                StockLedgerEntry.VoucherType.TRANSFER,
                StockLedgerEntry.VoucherType.TRANSFER_RECEIPT,
            )
        )
        self.assertEqual(
            sum((entry.value_change for entry in moved), Decimal("0")),
            Decimal("0"),
            "a transfer created or destroyed value",
        )

    def test_transit_is_never_nowhere(self):
        """At every step, what the shop holds is conserved."""
        self.stock(self.showroom, "10", "5.00")
        transfer = self.build_transfer("6")

        def total():
            return (
                self.on_hand(self.showroom) + self.transit() + self.on_hand(self.store)
            )

        self.assertEqual(total(), D("10.000"))
        self.dispatch(transfer)
        self.assertEqual(total(), D("10.000"))
        self.receive(transfer, "2")
        self.assertEqual(total(), D("10.000"))
        self.receive(transfer, "4")
        self.assertEqual(total(), D("10.000"))


class PartialArrivalTests(TransferTestCase):
    def test_a_transfer_that_half_arrives_says_so(self):
        self.stock(self.showroom, "10", "5.00")
        transfer = self.build_transfer("6")
        self.dispatch(transfer)

        self.receive(transfer, "2")
        transfer.refresh_from_db()
        self.assertEqual(transfer.status, StockTransfer.Status.PARTIALLY_RECEIVED)
        self.assertEqual(self.transit(), D("4.000"))
        self.assertEqual(self.on_hand(self.store), D("2.000"))

        self.receive(transfer, "4")
        transfer.refresh_from_db()
        self.assertEqual(transfer.status, StockTransfer.Status.RECEIVED)

    def test_cancelling_a_half_arrived_transfer_is_blocked_by_the_arrival(self):
        self.stock(self.showroom, "10", "5.00")
        transfer = self.build_transfer("6")
        self.dispatch(transfer)
        self.receive(transfer, "2")

        from apps.documents import services as document_services

        with self.assertRaises(DocumentBlocked):
            document_services.cancel(transfer, reason="x", actor=self.user)


class TransferGuardTests(TransferTestCase):
    def test_a_transfer_must_go_somewhere_else(self):
        """Refused by the database, not merely by the service — a row that says
        it moved stock from a place to itself is not a document with a mistake
        in it, it is not a document."""
        from django.db import IntegrityError, transaction

        with self.assertRaises(IntegrityError), transaction.atomic():
            StockTransfer.objects.create(
                source=self.showroom, destination=self.showroom
            )

    def test_an_empty_transfer_cannot_be_dispatched(self):
        transfer = StockTransfer.objects.create(
            source=self.showroom, destination=self.store
        )
        with self.assertRaises(Exception):
            self.dispatch(transfer)

    def test_a_dispatched_transfer_cannot_be_dispatched_again(self):
        self.stock(self.showroom, "10", "5.00")
        transfer = self.build_transfer("4")
        self.dispatch(transfer)
        with self.assertRaises(Exception):
            self.dispatch(transfer)

    def test_the_transfer_is_frozen_once_it_is_on_the_road(self):
        """It is a submitted document like any other: what it says it moved is
        not a figure anyone gets to revise afterwards."""
        from apps.documents.errors import DocumentFrozen

        self.stock(self.showroom, "10", "5.00")
        transfer = self.build_transfer("4")
        self.dispatch(transfer)
        transfer.refresh_from_db()
        transfer.source = self.store
        with self.assertRaises(DocumentFrozen):
            transfer.save(update_fields=["source", "updated_at"])

    def test_the_note_may_still_be_corrected(self):
        self.stock(self.showroom, "10", "5.00")
        transfer = self.build_transfer("4")
        self.dispatch(transfer)
        transfer.refresh_from_db()
        transfer.note = "عبر السائق الثاني"
        transfer.save(update_fields=["note", "updated_at"])

    def test_the_trail_records_who_sent_it(self):
        from apps.documents.models import DocumentEvent

        self.stock(self.showroom, "10", "5.00")
        transfer = self.build_transfer("4")
        self.dispatch(transfer)
        events = DocumentEvent.objects.filter(
            document_type="stock_transfer", object_id=transfer.pk
        )
        self.assertTrue(events.exists())
        self.assertEqual(events.first().actor_id, self.user.pk)


class TransferLockOrderingTests(TransferTestCase):
    def test_every_row_a_transfer_touches_is_locked_in_one_ascending_pass(self):
        """Two transfers running in opposite directions between the same pair of
        places would deadlock if each locked "its own" warehouse first. Taking
        every row in one ``(variant_id, warehouse_id)`` pass makes that
        impossible — which is what the second sort column added in 2a was for.
        """
        from django.db import connection
        from django.test.utils import CaptureQueriesContext

        self.stock(self.showroom, "10", "5.00")
        transfer = self.build_transfer("4")
        with CaptureQueriesContext(connection) as ctx:
            self.dispatch(transfer)
        locking = [
            " ".join(query["sql"].split())
            for query in ctx.captured_queries
            if "FOR UPDATE" in query["sql"] and "inventory_stockitem" in query["sql"]
        ]
        self.assertTrue(locking)
        self.assertIn(
            'ORDER BY "inventory_stockitem"."variant_id" ASC, '
            '"inventory_stockitem"."warehouse_id" ASC',
            locking[0],
        )


class ShopWithOneWarehouseTests(TransferTestCase):
    def test_a_shop_that_never_transfers_never_sees_a_transit_location(self):
        """Transit is created on demand. A shop with one room should never find
        a second one it did not open sitting in its warehouse list."""
        self.assertFalse(
            Warehouse.objects.filter(kind=Warehouse.Kind.TRANSIT).exists()
        )

    def test_the_shop_setting_still_decides_when_a_place_has_no_opinion(self):
        settings = ShopSettings.load()
        settings.allow_overselling = True
        settings.save()
        ShopSettings.load()

        self.stock(self.showroom, "1", "5.00")
        transfer = self.build_transfer("4")
        self.dispatch(transfer)
        self.assertEqual(self.on_hand(self.showroom), D("-3.000"))


class TransferApiTests(TransferTestCase):
    def setUp(self):
        super().setUp()
        from rest_framework.test import APIClient

        self.client = APIClient()
        self.client.force_authenticate(user=self.user)

    def _url(self, suffix="", pk=None):
        from django.urls import reverse

        name = f"stock-transfer-{suffix}" if suffix else "stock-transfer-list"
        return reverse(name, args=[pk] if pk else None)

    def test_the_whole_journey_over_http(self):
        """Create, send, receive — the three verbs a shop actually uses."""
        self.stock(self.showroom, "10", "5.00")

        created = self.client.post(
            self._url(),
            {
                "source": self.showroom.pk,
                "destination": self.store.pk,
                "lines": [{"variant": self.variant.pk, "quantity": "4"}],
            },
            format="json",
        )
        self.assertEqual(created.status_code, 201, created.data)
        transfer_id = created.data["id"]
        self.assertEqual(created.data["status"], StockTransfer.Status.DRAFT)
        self.assertTrue(created.data["transfer_number"])

        sent = self.client.post(self._url("send-off", transfer_id))
        self.assertEqual(sent.status_code, 200, sent.data)
        self.assertEqual(sent.data["status"], StockTransfer.Status.IN_TRANSIT)
        self.assertEqual(self.transit(), D("4.000"))

        line_id = sent.data["lines"][0]["id"]
        arrived = self.client.post(
            self._url("receive", transfer_id),
            {"lines": [{"line": line_id, "quantity": "4"}]},
            format="json",
        )
        self.assertEqual(arrived.status_code, 200, arrived.data)
        self.assertEqual(arrived.data["status"], StockTransfer.Status.RECEIVED)
        self.assertEqual(self.on_hand(self.store), D("4.000"))

    def test_a_transfer_to_the_same_place_is_refused_before_it_is_created(self):
        response = self.client.post(
            self._url(),
            {
                "source": self.showroom.pk,
                "destination": self.showroom.pk,
                "lines": [{"variant": self.variant.pk, "quantity": "1"}],
            },
            format="json",
        )
        self.assertEqual(response.status_code, 400, response.data)

    def test_a_transfer_cannot_be_addressed_to_the_road(self):
        transit = Warehouse.objects.get(pk=Warehouse.transit_id())
        response = self.client.post(
            self._url(),
            {
                "source": self.showroom.pk,
                "destination": transit.pk,
                "lines": [{"variant": self.variant.pk, "quantity": "1"}],
            },
            format="json",
        )
        self.assertEqual(response.status_code, 400, response.data)

    def test_an_empty_transfer_is_refused(self):
        response = self.client.post(
            self._url(),
            {"source": self.showroom.pk, "destination": self.store.pk, "lines": []},
            format="json",
        )
        self.assertEqual(response.status_code, 400, response.data)

    def test_cancelling_requires_a_reason_and_records_it(self):
        self.stock(self.showroom, "10", "5.00")
        transfer = self.build_transfer("4")
        self.dispatch(transfer)

        blank = self.client.post(self._url("cancel", transfer.pk), {}, format="json")
        self.assertEqual(blank.status_code, 400, blank.data)

        done = self.client.post(
            self._url("cancel", transfer.pk),
            {"reason": "السائق رجع"},
            format="json",
        )
        self.assertEqual(done.status_code, 200, done.data)
        self.assertEqual(done.data["cancel_reason"], "السائق رجع")
        self.assertEqual(done.data["cancelled_by_username"], self.user.username)
        self.assertEqual(self.on_hand(self.showroom), D("10.000"))

    def test_a_line_from_another_transfer_cannot_be_received_here(self):
        self.stock(self.showroom, "20", "5.00")
        first = self.build_transfer("4")
        second = self.build_transfer("4")
        self.dispatch(first)
        self.dispatch(second)
        response = self.client.post(
            self._url("receive", first.pk),
            {"lines": [{"line": second.lines.first().pk, "quantity": "1"}]},
            format="json",
        )
        self.assertEqual(response.status_code, 400, response.data)

    def test_the_list_costs_the_same_however_many_transfers_there_are(self):
        from django.db import connection
        from django.test.utils import CaptureQueriesContext

        self.stock(self.showroom, "500", "5.00")
        for _ in range(2):
            self.dispatch(self.build_transfer("1"))
        self.client.get(self._url())
        with CaptureQueriesContext(connection) as few:
            self.client.get(self._url())
        for _ in range(6):
            self.dispatch(self.build_transfer("1"))
        with CaptureQueriesContext(connection) as many:
            self.client.get(self._url())
        self.assertEqual(
            len(few), len(many), "the transfer list scales with the row count"
        )
