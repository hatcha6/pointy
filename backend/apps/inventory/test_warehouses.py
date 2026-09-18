"""Warehouses: the invariants, and where each one came from.

The first block is ported from ERPNext's own ``test_warehouse.py`` and
``test_stock_entry.py``, translated into this system's vocabulary. Their thirteen
warehouse tests reduce to three that mean anything here — four exist only to hold
their nested-set tree together (we ship flat warehouses on purpose) and six test
perpetual-inventory GL accounts (we have no ledger). What survives is the part
that is about stock rather than about their schema.

The second block is ours, and most of it guards the promise that makes this
phase safe to ship: **a shop with one location must not be able to tell that
warehouses exist.**
"""

import pathlib
import re
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.db import connection
from django.test import TestCase
from django.test.utils import CaptureQueriesContext

from apps.catalog.models import ProductVariant
from apps.catalog.testing import create_product_with_default_variant
from apps.core.models import ShopSettings
from apps.core.roles import ensure_role_groups
from apps.inventory.models import (  # noqa: F401
    DEFAULT_WAREHOUSE_NAME,
    StockItem,
    StockLedgerEntry,
    Warehouse,
)
from apps.inventory.models import forget_default_warehouse
from apps.inventory.oversell import may_oversell
from apps.inventory.services import lock_stock_item, resolve_warehouse_id

BACKEND_ROOT = pathlib.Path(__file__).resolve().parent.parent.parent


class WarehouseBasicsTests(TestCase):
    def setUp(self):
        product = create_product_with_default_variant(
            name="سكر", sku="W-1", barcode="", unit_price=Decimal("5.00")
        )
        self.variant = product.default_variant

    # -- ported from ERPNext ------------------------------------------------

    def test_a_code_identifies_exactly_one_warehouse(self):
        """Their ``test_naming``. Ours is simpler because a flat warehouse has
        no generated tree-path name to check — just a code nothing else shares.
        """
        Warehouse.objects.create(name="المخزن", code="store")
        with self.assertRaises(Exception):
            Warehouse.objects.create(name="آخر", code="store")

    def test_a_warehouse_holding_stock_cannot_be_deleted(self):
        """Their ``Warehouse.on_trash`` first clause: *"Warehouse {0} can not be
        deleted as quantity exists for Item {1}"*."""
        store = Warehouse.objects.create(name="المخزن", code="store")
        StockItem.objects.create(
            variant=self.variant, warehouse=store, quantity_on_hand=Decimal("3")
        )
        self.assertIn("still hold stock", " ".join(store.deletion_blockers()))

    def test_a_warehouse_with_history_cannot_be_deleted(self):
        """Their ``on_trash`` second clause: stock ledger entries block deletion
        even once the quantity has gone back to zero. History is the reason —
        a location whose entries are still referenced cannot be un-happened."""
        store = Warehouse.objects.create(name="المخزن", code="store")
        StockLedgerEntry.objects.create(
            variant=self.variant,
            warehouse=store,
            posting_at="2026-01-01T00:00:00Z",
            quantity_change=Decimal("1"),
            balance_quantity=Decimal("1"),
            value_change=Decimal("1"),
            valuation_rate=Decimal("1"),
            balance_value=Decimal("1"),
            voucher_type=StockLedgerEntry.VoucherType.OPENING,
        )
        self.assertIn("history", " ".join(store.deletion_blockers()))

    def test_deletion_is_refused_rather_than_silently_unlinking(self):
        """Their ``test_unlinking_warehouse_from_item_defaults`` asserts that a
        deleted warehouse is *unlinked* from anything naming it as a default.
        We diverge deliberately: silently detaching a reference is how a shop
        finds out later that a number moved. The stock row's foreign key is
        ``PROTECT`` and the blocker list says so first."""
        store = Warehouse.objects.create(name="المخزن", code="store")
        StockItem.objects.create(
            variant=self.variant, warehouse=store, quantity_on_hand=Decimal("1")
        )
        self.assertTrue(store.deletion_blockers())

    # -- ours ---------------------------------------------------------------

    def test_a_shop_starts_with_exactly_one_warehouse_and_it_is_the_showroom(self):
        """Most shops in Libya are a single showroom with no back store at all.
        Nothing creates a store room on their behalf, and their one location is
        not called one."""
        default = Warehouse.objects.get(pk=Warehouse.default_id())
        self.assertEqual(Warehouse.objects.count(), 1)
        self.assertEqual(default.name, DEFAULT_WAREHOUSE_NAME)
        self.assertEqual(default.kind, Warehouse.Kind.SHOP_FLOOR)
        self.assertTrue(default.is_default)

    def test_the_default_warehouse_cannot_be_deleted(self):
        default = Warehouse.objects.get(pk=Warehouse.default_id())
        self.assertIn("default", " ".join(default.deletion_blockers()))

    def test_a_stock_row_written_without_a_warehouse_lands_in_the_default(self):
        """Every caller that has not learned about locations keeps working, and
        no code path of ours can write the null the column still permits."""
        item = StockItem.objects.create(
            variant=self.variant, quantity_on_hand=Decimal("4")
        )
        self.assertEqual(item.warehouse_id, Warehouse.default_id())

    def test_transit_is_a_state_rather_than_a_shop(self):
        transit = Warehouse.objects.create(
            name="في الطريق", code="transit", kind=Warehouse.Kind.TRANSIT
        )
        self.assertFalse(transit.sells_from)
        self.assertTrue(Warehouse.objects.get(pk=Warehouse.default_id()).sells_from)


class QuantityAccessorTests(TestCase):
    def setUp(self):
        product = create_product_with_default_variant(
            name="أرز", sku="W-2", barcode="", unit_price=Decimal("5.00")
        )
        self.variant = product.default_variant
        self.showroom = Warehouse.objects.get(pk=Warehouse.default_id())
        self.store = Warehouse.objects.create(
            name="المخزن", code="store", kind=Warehouse.Kind.STORE_ROOM
        )
        StockItem.objects.create(
            variant=self.variant, warehouse=self.showroom, quantity_on_hand=Decimal("3")
        )
        StockItem.objects.create(
            variant=self.variant, warehouse=self.store, quantity_on_hand=Decimal("40")
        )

    def _fresh(self):
        return ProductVariant.objects.get(pk=self.variant.pk)

    def test_the_total_is_the_sum_of_the_parts(self):
        variant = self._fresh()
        self.assertEqual(variant.quantity_on_hand, Decimal("43.000"))
        self.assertEqual(
            variant.quantity_on_hand_at(self.showroom)
            + variant.quantity_on_hand_at(self.store),
            variant.quantity_on_hand,
        )

    def test_asking_about_one_place_does_not_answer_about_another(self):
        """The whole reason ``variant.stock`` was deleted rather than pointed at
        the default warehouse: a property that silently answered about one
        location would tell a cashier standing in the showroom about the forty
        in the back."""
        variant = self._fresh()
        self.assertEqual(variant.quantity_on_hand_at(self.showroom), Decimal("3.000"))
        self.assertEqual(variant.quantity_on_hand_at(self.store), Decimal("40.000"))

    def test_an_annotated_queryset_answers_without_another_query(self):
        """A page of products must not pay a query per row for its totals."""
        from django.db.models import Sum

        queryset = ProductVariant.objects.filter(pk=self.variant.pk).annotate(
            **{ProductVariant.ON_HAND_ANNOTATION: Sum("stock_items__quantity_on_hand")}
        )
        with CaptureQueriesContext(connection) as ctx:
            variant = queryset.first()
            total = variant.quantity_on_hand
        self.assertEqual(total, Decimal("43.000"))
        self.assertEqual(len(ctx), 1, "the annotation was not used")

    def test_a_prefetched_variant_answers_without_another_query(self):
        queryset = ProductVariant.objects.filter(pk=self.variant.pk).prefetch_related(
            "stock_items"
        )
        with CaptureQueriesContext(connection) as ctx:
            variant = queryset.first()
            total = variant.quantity_on_hand
            here = variant.quantity_on_hand_at(self.store)
        self.assertEqual(total, Decimal("43.000"))
        self.assertEqual(here, Decimal("40.000"))
        self.assertEqual(len(ctx), 2, "the prefetch was not used")


class OversellPolicyTests(TestCase):
    """ERPNext ships this setting twice — once on the company and once on the
    item — and their issue #45414 is a user watching invoices submit below zero
    while the company setting is off, because the two interact and one path
    forgets to ask. Their #12651 has been asking for a per-warehouse setting for
    years, which their company-level shape cannot express.
    """

    def setUp(self):
        self.settings = ShopSettings.load()
        self.showroom = Warehouse.objects.get(pk=Warehouse.default_id())
        self.store = Warehouse.objects.create(name="المخزن", code="store")

    def test_a_warehouse_with_no_opinion_follows_the_shop(self):
        self.settings.allow_overselling = True
        self.assertTrue(may_oversell(self.showroom, variant=None, settings=self.settings))
        self.settings.allow_overselling = False
        self.assertFalse(may_oversell(self.showroom, variant=None, settings=self.settings))

    def test_a_warehouse_may_refuse_what_the_shop_allows(self):
        """The case #12651 asks for: a showroom that will not sell what it has
        not got, in a shop that tolerates it elsewhere."""
        self.settings.allow_overselling = True
        self.showroom.allow_overselling = Warehouse.OversellPolicy.REFUSE
        self.assertFalse(may_oversell(self.showroom, variant=None, settings=self.settings))

    def test_a_warehouse_may_allow_what_the_shop_refuses(self):
        self.settings.allow_overselling = False
        self.store.allow_overselling = Warehouse.OversellPolicy.ALLOW
        self.assertTrue(may_oversell(self.store, variant=None, settings=self.settings))

    def test_a_stock_row_resolves_the_policy_of_the_place_it_is_in(self):
        self.settings.allow_overselling = False
        self.store.allow_overselling = Warehouse.OversellPolicy.ALLOW
        self.store.save(update_fields=["allow_overselling", "updated_at"])
        product = create_product_with_default_variant(
            name="ملح", sku="W-3", barcode="", unit_price=Decimal("1.00")
        )
        row = StockItem.objects.create(
            variant=product.default_variant, warehouse=self.store
        )
        self.assertTrue(may_oversell(row, variant=None, settings=self.settings))

    def test_only_one_function_decides_whether_stock_may_go_below_zero(self):
        """The census that stops #45414 happening here.

        ``ShopSettings.allow_overselling`` is a stored preference; deciding
        *from* it is ``may_oversell``'s job alone. A second reader is a second
        place that can forget a warehouse's own policy, which is exactly the
        divergence their two flags produced.
        """
        if not (BACKEND_ROOT / "apps" / "inventory" / "oversell.py").exists():
            # Compiled build: ``compile_backend.py`` deletes every ``.py`` it
            # turns into a ``.so``. Enforced by the source-suite job.
            self.skipTest("static source guard; enforced by the source test run")

        allowed = {
            # Declares the shop-wide preference.
            "apps/core/models.py",
            # Reads and writes it as a setting, which is not deciding with it.
            "apps/core/serializers.py",
            "apps/core/views.py",
            # Declares the per-warehouse policy.
            "apps/inventory/models.py",
            # Puts it on the wire so an owner can set it, and offers it as a
            # list filter. Exposing a stored preference is not deciding with it.
            "apps/inventory/serializers.py",
            # The one place that decides.
            "apps/inventory/oversell.py",
            # Tells the assistant what the shop's posture is; never gates a write.
            "apps/ai/relay_stream.py",
            # Turns it off wholesale so the run is deterministic.
            "apps/sales/business_simulation.py",
        }
        pattern = re.compile(r"\ballow_overselling\b")
        found = set()
        for path in sorted(BACKEND_ROOT.glob("apps/**/*.py")):
            relative = path.relative_to(BACKEND_ROOT).as_posix()
            if "/test" in relative or relative.endswith("tests.py"):
                continue
            if "migrations/" in relative:
                continue
            if pattern.search(path.read_text()):
                found.add(relative)

        unexpected = sorted(found - allowed)
        self.assertFalse(
            unexpected,
            "New code reads the overselling flag directly instead of asking "
            f"apps.inventory.oversell.may_oversell(): {unexpected}. A second "
            "reader cannot see a warehouse's own policy — this is ERPNext "
            "issue #45414, and this test is how we do not ship it.",
        )


class LockOrderingTests(TestCase):
    """The most delicate thing this migration touched.

    ``lock_stock_items`` sorts ascending so two concurrent carts sharing a
    product cannot deadlock. The key is now a pair, and the ordering has to
    extend to it before the transfer document — the first caller that will span
    two warehouses in one statement — arrives in 2c.
    """

    def setUp(self):
        ensure_role_groups()
        get_user_model().objects.create_user(username="m", password="p")
        self.warehouses = [
            Warehouse.objects.get(pk=Warehouse.default_id()),
            Warehouse.objects.create(name="المخزن", code="store"),
        ]
        self.variants = [
            create_product_with_default_variant(
                name=f"صنف {i}", sku=f"L-{i}", barcode="", unit_price=Decimal("1.00")
            ).default_variant
            for i in range(3)
        ]

    def test_rows_are_locked_in_ascending_variant_and_warehouse_order(self):
        from apps.inventory.services import lock_stock_items

        with CaptureQueriesContext(connection) as ctx:
            lock_stock_items(self.variants, warehouse=self.warehouses[1])
        locking = [
            " ".join(q["sql"].split())
            for q in ctx.captured_queries
            if "FOR UPDATE" in q["sql"] and "inventory_stockitem" in q["sql"]
        ]
        self.assertTrue(locking, "no locking statement was issued")
        self.assertIn('ORDER BY "inventory_stockitem"."variant_id" ASC', locking[0])
        self.assertIn('"inventory_stockitem"."warehouse_id" ASC', locking[0])

    def test_the_same_variant_in_two_places_is_two_rows(self):
        first = lock_stock_item(variant=self.variants[0], warehouse=self.warehouses[0])
        second = lock_stock_item(variant=self.variants[0], warehouse=self.warehouses[1])
        self.assertNotEqual(first.pk, second.pk)

    def test_a_caller_that_names_no_warehouse_gets_the_default(self):
        self.assertEqual(resolve_warehouse_id(None), Warehouse.default_id())
        self.assertEqual(
            lock_stock_item(variant=self.variants[0]).warehouse_id,
            Warehouse.default_id(),
        )


class InvisibilityTests(TestCase):
    """The promise that makes this phase safe to ship.

    A shop with one location must not be able to tell that warehouses exist —
    and the measurable half of that is the cashier's critical path. Asserted as
    "no warehouse queries at all" rather than as a total, so it keeps meaning
    something as the rest of checkout changes around it.
    """

    def setUp(self):
        ensure_role_groups()
        self.user = get_user_model().objects.create_user(username="m", password="p")
        self.variants = []
        for index in range(3):
            product = create_product_with_default_variant(
                name=f"صنف {index}",
                sku=f"INV-{index}",
                barcode="",
                unit_price=Decimal("5.00"),
            )
            StockItem.objects.create(
                variant=product.default_variant, quantity_on_hand=Decimal("1000")
            )
            self.variants.append(product.default_variant)

    def _sell(self, lines):
        from apps.sales.models import RegisterSession
        from apps.sales.services import checkout_order

        session = getattr(self, "_session", None)
        if session is None:
            session = RegisterSession.objects.create(
                owner=self.user,
                owner_key=f"user:{self.user.pk}",
                opening_cash=Decimal("0.00"),
            )
            self._session = session
        return checkout_order(
            register_session=session,
            lines_data=[
                {"variant": self.variants[i], "quantity": Decimal("1")}
                for i in range(lines)
            ],
            payments_data=[{"method": "cash", "amount": Decimal("5.00") * lines}],
        )

    def test_a_checkout_asks_the_warehouse_table_nothing(self):
        """``default_id()`` is resolved several times inside one sale — twice by
        the valuation engine, once by the stock lock, once by the oversell
        policy. Every one of them is served from the cached singleton, so the
        table is never touched on the path the cashier waits on."""
        self._sell(1)  # warm caches and settings singletons
        with CaptureQueriesContext(connection) as ctx:
            self._sell(2)
        warehouse_queries = [
            query["sql"]
            for query in ctx.captured_queries
            if "inventory_warehouse" in query["sql"]
        ]
        self.assertEqual(
            warehouse_queries,
            [],
            "checkout resolves the warehouse from the database instead of the "
            "cached singleton",
        )

    def tearDown(self):
        # This class rewrites which warehouse is the default. The rows roll back
        # with the test; the process-level cache does not, so it is cleared here
        # rather than left to poison whatever runs next.
        forget_default_warehouse()

    def test_the_cache_does_not_outlive_the_row_it_names(self):
        """A stale default warehouse id would sell out of a location that is no
        longer there. Any write to the table forgets it."""
        first = Warehouse.default_id()
        Warehouse.objects.filter(pk=first).update(name="مخزن")
        Warehouse.objects.get(pk=first).save(update_fields=["name", "updated_at"])
        self.assertEqual(Warehouse.default_id(), first)

        Warehouse.objects.filter(pk=first).update(is_default=False)
        replacement = Warehouse.objects.create(
            name="آخر", code="other", is_default=True
        )
        self.assertEqual(Warehouse.default_id(), replacement.pk)


class WarehouseApiTests(TestCase):
    """The CRUD surface a shop uses to open its second location."""

    def setUp(self):
        from django.contrib.auth.models import Group
        from rest_framework.test import APIClient

        from apps.core.roles import INVENTORY_CLERK_GROUP, MANAGER_GROUP

        ensure_role_groups()
        self.manager = get_user_model().objects.create_user(username="m", password="p")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.clerk = get_user_model().objects.create_user(username="c", password="p")
        self.clerk.groups.add(Group.objects.get(name=INVENTORY_CLERK_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(user=self.manager)

    def _url(self, pk=None):
        from django.urls import reverse

        return (
            reverse("warehouse-detail", args=[pk])
            if pk
            else reverse("warehouse-list")
        )

    def test_a_new_shop_lists_exactly_its_showroom(self):
        response = self.client.get(self._url())
        self.assertEqual(response.status_code, 200)
        rows = response.data["results"] if "results" in response.data else response.data
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["name"], DEFAULT_WAREHOUSE_NAME)
        self.assertTrue(rows[0]["is_default"])
        self.assertFalse(rows[0]["can_delete"])

    def test_a_manager_can_open_a_store_room(self):
        response = self.client.post(
            self._url(),
            {"name": "المخزن", "code": "store", "kind": Warehouse.Kind.STORE_ROOM},
            format="json",
        )
        self.assertEqual(response.status_code, 201, response.data)
        self.assertFalse(response.data["is_default"])
        self.assertTrue(response.data["can_delete"])

    def test_a_transit_location_cannot_be_opened_by_hand(self):
        """Transit is a state the transfer document puts stock into. A shop that
        could create one would have somewhere to sell from that nothing is ever
        meant to sell from."""
        response = self.client.post(
            self._url(),
            {"name": "عابر", "code": "t1", "kind": Warehouse.Kind.TRANSIT},
            format="json",
        )
        self.assertEqual(response.status_code, 400, response.data)

    def test_deleting_a_warehouse_holding_stock_is_refused_with_its_reasons(self):
        store = Warehouse.objects.create(name="المخزن", code="store")
        product = create_product_with_default_variant(
            name="زيت", sku="API-1", barcode="", unit_price=Decimal("9.00")
        )
        StockItem.objects.create(
            variant=product.default_variant,
            warehouse=store,
            quantity_on_hand=Decimal("2"),
        )
        response = self.client.delete(self._url(store.pk))
        self.assertEqual(response.status_code, 400, response.data)
        self.assertTrue(response.data["blockers"])

    def test_an_empty_warehouse_can_be_closed(self):
        store = Warehouse.objects.create(name="المخزن", code="store")
        self.assertEqual(self.client.delete(self._url(store.pk)).status_code, 204)
        self.assertFalse(Warehouse.objects.filter(pk=store.pk).exists())

    def test_the_default_warehouse_cannot_be_deleted_through_the_api(self):
        default = Warehouse.objects.get(pk=Warehouse.default_id())
        self.assertEqual(self.client.delete(self._url(default.pk)).status_code, 400)

    def test_a_clerk_may_look_but_not_open_or_close(self):
        from rest_framework.test import APIClient

        client = APIClient()
        client.force_authenticate(user=self.clerk)
        self.assertEqual(client.get(self._url()).status_code, 200)
        self.assertEqual(
            client.post(
                self._url(), {"name": "x", "code": "x"}, format="json"
            ).status_code,
            403,
        )

    def test_the_list_costs_the_same_however_many_places_a_shop_keeps(self):
        from django.urls import reverse  # noqa: F401

        self.client.get(self._url())  # warm
        with CaptureQueriesContext(connection) as one:
            self.client.get(self._url())
        for index in range(5):
            Warehouse.objects.create(name=f"مخزن {index}", code=f"w{index}")
        with CaptureQueriesContext(connection) as many:
            self.client.get(self._url())
        self.assertEqual(
            len(one),
            len(many),
            "the warehouse list scales with the number of warehouses",
        )


class StockCountScopeTests(TestCase):
    """A count is of one place.

    Counting "the shop" while stock sits in a store room out the back is how a
    variance report becomes fiction: every unit in the back reads as missing
    from the front.
    """

    def setUp(self):
        ensure_role_groups()
        self.user = get_user_model().objects.create_user(username="m", password="p")
        product = create_product_with_default_variant(
            name="طحين", sku="SC-1", barcode="", unit_price=Decimal("4.00")
        )
        self.variant = product.default_variant
        self.showroom = Warehouse.objects.get(pk=Warehouse.default_id())
        self.store = Warehouse.objects.create(name="المخزن", code="store")
        StockItem.objects.create(
            variant=self.variant, warehouse=self.showroom, quantity_on_hand=Decimal("2")
        )
        StockItem.objects.create(
            variant=self.variant, warehouse=self.store, quantity_on_hand=Decimal("90")
        )

    def test_a_count_records_the_place_it_counted(self):
        from apps.inventory.models import StockCount

        count = StockCount.objects.create(owner=self.user, owner_key="k")
        self.assertEqual(count.warehouse_id, self.showroom.pk)

    def test_a_count_of_the_store_room_does_not_see_the_showroom(self):
        from apps.inventory.models import StockCount
        from apps.inventory.services import lock_stock_item

        count = StockCount.objects.create(
            owner=self.user, owner_key="k2", warehouse=self.store
        )
        row = lock_stock_item(variant=self.variant, warehouse=count.warehouse_id)
        self.assertEqual(row.quantity_on_hand, Decimal("90.000"))


class SumEqualsPartsTests(TestCase):
    """Whatever a report says the shop holds must equal what the places hold.

    This is the invariant that catches the bug class 2a creates: anything that
    was keyed on a variant while a variant had exactly one stock row, and now
    silently keeps the last warehouse it saw instead of adding them up.
    """

    def setUp(self):
        product = create_product_with_default_variant(
            name="عدس", sku="SUM-1", barcode="", unit_price=Decimal("6.00")
        )
        self.variant = product.default_variant
        self.showroom = Warehouse.objects.get(pk=Warehouse.default_id())
        self.store = Warehouse.objects.create(name="المخزن", code="store")

    def _bin(self, warehouse, quantity, value):
        from apps.inventory.models import StockValuationBin

        StockValuationBin.objects.create(
            variant=self.variant,
            warehouse=warehouse,
            quantity=Decimal(quantity),
            stock_value=Decimal(value),
            valuation_rate=Decimal(value) / Decimal(quantity),
        )

    def test_the_stock_schedule_adds_up_the_places_rather_than_the_last_one(self):
        from apps.inventory.reporting import (
            stock_cost_value,
            stock_position_by_variant,
        )

        self._bin(self.showroom, "3", "30.00")
        self._bin(self.store, "40", "400.00")

        quantity, value = stock_position_by_variant()[self.variant.pk]
        self.assertEqual(quantity, Decimal("43.000"))
        self.assertEqual(value, Decimal("430.00"))
        # And the per-line figures still add up to the headline total, which is
        # the whole point of a schedule.
        self.assertEqual(value, stock_cost_value())

    def test_one_warehouse_reads_exactly_as_it_always_did(self):
        from apps.inventory.reporting import stock_position_by_variant

        self._bin(self.showroom, "7", "70.00")
        self.assertEqual(
            stock_position_by_variant()[self.variant.pk],
            (Decimal("7.000"), Decimal("70.00")),
        )
