"""الأمانات over the wire: the voucher, the payables screen and the drawer.

The endpoints are tested rather than the services because the interesting
failures here are at the boundary. Two in particular:

* the payout locks its units **inside** its own transaction — a view that
  evaluated the queryset first would take no lock at all, which is how the same
  payout is disbursed twice from two tills;
* the liability permissions are split on purpose (seeing what is owed is not the
  same as handing it over), and a split that silently stops being enforced is a
  split nobody notices has stopped.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.models import Product
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.customers.models import Customer
from apps.sales.models import RegisterCashMovement, RegisterSession
from apps.sales.services import checkout_order

from .models import ConsignorPayout, StockUnit
from .tracked_testing import receive, tracked_product

_USERS = 0


def _user(username, *, permissions=(), manager=False):
    global _USERS
    _USERS += 1
    user = get_user_model().objects.create_user(
        username=f"{username}-{_USERS}", password="pw"
    )
    if manager:
        user.groups.add(Group.objects.get(name=MANAGER_GROUP))
    for codename in permissions:
        app_label, code = codename.split(".")
        user.user_permissions.add(
            Permission.objects.get(
                content_type__app_label=app_label, codename=code
            )
        )
    return user


class ConsignmentApiTestCase(TestCase):
    """The fixture and the helpers, with no tests of their own.

    Split out so the classes below inherit the setup without inheriting each
    other's tests — subclassing a populated ``TestCase`` re-runs every one of
    its cases per subclass, which is four copies of this file's slowest work.
    """

    def setUp(self):
        ensure_role_groups()
        self.manager = _user("manager", manager=True)
        self.client = APIClient()
        self.client.force_authenticate(user=self.manager)
        self.product = tracked_product(
            name="ساعة",
            sku="API-RLX",
            mode=Product.TrackingMode.SERIAL,
            unit_price="12000.00",
        )
        self.variant = self.product.default_variant
        self.consignor = Customer.objects.create(
            full_name="سالم", phone="0912345678"
        )

    def _agreement(self, **overrides):
        body = {
            "consignor": self.consignor.pk,
            "payout_mode": "fixed",
            "payout_rate": "10000.00",
            "liability_policy": "owner_risk",
            **overrides,
        }
        response = self.client.post(
            reverse("consignment-agreement-list"), body, format="json"
        )
        self.assertEqual(
            response.status_code, status.HTTP_201_CREATED, response.data
        )
        return response.data

    def _submit(self, agreement_id, code="ROLEX-A"):
        return self.client.post(
            reverse("consignment-agreement-submit", args=[agreement_id]),
            {
                "items": [
                    {
                        "variant": self.variant.pk,
                        "code": code,
                        "declared_value": "12000.00",
                    }
                ]
            },
            format="json",
        )

    def _sell(self, unit, price="12000.00"):
        session = RegisterSession.objects.create(
            owner=self.manager,
            owner_key=f"user:{self.manager.pk}",
            status=RegisterSession.Status.OPEN,
            opening_cash=Decimal("0.00"),
        )
        return checkout_order(
            register_session=session,
            lines_data=[
                {
                    "variant": self.variant,
                    "quantity": Decimal("1"),
                    "effective_unit_price": Decimal(price),
                    "stock_units": [unit.pk],
                }
            ],
            payments_data=[{"method": "cash", "amount": Decimal(price)}],
        )


class ConsignmentApiTests(ConsignmentApiTestCase):
    # -- the voucher ---------------------------------------------------------

    def test_an_agreement_is_a_draft_until_it_is_signed(self):
        agreement = self._agreement()
        self.assertEqual(agreement["doc_status"], "draft")
        self.assertTrue(agreement["number"])
        # Nothing is on the shelf yet: submitting is what starts custody.
        self.assertEqual(StockUnit.objects.count(), 0)

    def test_signing_it_takes_the_goods_in(self):
        agreement = self._agreement()

        response = self._submit(agreement["id"])

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(response.data["doc_status"], "submitted")
        unit = StockUnit.objects.get()
        self.assertTrue(unit.is_consignment)
        self.assertEqual(unit.consignor_id, self.consignor.pk)
        self.assertEqual(unit.incoming_rate, Decimal("0.000000"))
        # The clause is copied at submit, from the shop's own sentence.
        self.assertTrue(response.data["liability_clause"])

    def test_a_fixed_agreement_without_a_payout_is_refused(self):
        response = self.client.post(
            reverse("consignment-agreement-list"),
            {
                "consignor": self.consignor.pk,
                "payout_mode": "fixed",
                "liability_policy": "owner_risk",
            },
            format="json",
        )
        # Not a nicety: the price floor is computed from it, and a null one
        # would silently disable the guard.
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("payout_rate", response.data)

    # -- the payables screen -------------------------------------------------

    def test_the_payables_list_shows_what_is_owed(self):
        agreement = self._agreement()
        self._submit(agreement["id"])
        unit = StockUnit.objects.get()
        self._sell(unit)

        response = self.client.get(
            reverse("stock-unit-consignment-payables")
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["total_due"], Decimal("10000.00"))
        row = response.data["results"][0]
        self.assertEqual(row["consignor_name"], "سالم")
        self.assertEqual(row["payout_due"], Decimal("10000.00"))

    def test_disbursing_opens_the_drawer_and_closes_the_payable(self):
        agreement = self._agreement()
        self._submit(agreement["id"])
        unit = StockUnit.objects.get()
        self._sell(unit)

        response = self.client.post(
            reverse("stock-unit-disburse-payout", args=[unit.pk]),
            {"method": "cash"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(response.data["amount"], "10000.00")
        self.assertTrue(response.data["number"])
        unit.refresh_from_db()
        self.assertIsNotNone(unit.consignor_paid_at)
        movement = RegisterCashMovement.objects.get()
        self.assertEqual(
            movement.movement_type, RegisterCashMovement.MovementType.PAY_OUT
        )
        self.assertEqual(ConsignorPayout.objects.count(), 1)

    def test_disbursing_twice_is_refused(self):
        agreement = self._agreement()
        self._submit(agreement["id"])
        unit = StockUnit.objects.get()
        self._sell(unit)
        self.client.post(
            reverse("stock-unit-disburse-payout", args=[unit.pk]),
            {"method": "cash"},
            format="json",
        )

        response = self.client.post(
            reverse("stock-unit-disburse-payout", args=[unit.pk]),
            {"method": "cash"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(ConsignorPayout.objects.count(), 1)

    def test_unsold_goods_go_back_to_their_owner(self):
        agreement = self._agreement()
        self._submit(agreement["id"])
        unit = StockUnit.objects.get()

        response = self.client.post(
            reverse("stock-unit-return-to-consignor", args=[unit.pk]),
            {},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        unit.refresh_from_db()
        self.assertEqual(unit.status, StockUnit.Status.RETURNED)
        self.assertEqual(ConsignorPayout.objects.count(), 0)

    def test_the_position_carries_the_four_figures(self):
        agreement = self._agreement()
        self._submit(agreement["id"])

        response = self.client.get(reverse("consignment-position"))

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["stock_value"], Decimal("0.00"))
        self.assertEqual(response.data["custody"]["unit_count"], 1)

    def test_the_statement_is_one_consignor_s_page(self):
        agreement = self._agreement()
        self._submit(agreement["id"])
        unit = StockUnit.objects.get()
        self._sell(unit)

        response = self.client.get(
            reverse("consignment-agreement-statement", args=[agreement["id"]])
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["sold_count"], 1)
        self.assertEqual(response.data["payable_total"], Decimal("10000.00"))
        self.assertEqual(response.data["commission_total"], Decimal("2000.00"))

    # -- permissions ---------------------------------------------------------

    def test_seeing_what_is_owed_is_not_being_able_to_pay_it(self):
        agreement = self._agreement()
        self._submit(agreement["id"])
        unit = StockUnit.objects.get()
        self._sell(unit)

        watcher = _user(
            "watcher",
            permissions=(
                "inventory.view_stockunit",
                "inventory.view_consignment_liability",
            ),
        )
        client = APIClient()
        client.force_authenticate(user=watcher)

        self.assertEqual(
            client.get(reverse("stock-unit-consignment-payables")).status_code,
            status.HTTP_200_OK,
        )
        self.assertEqual(
            client.post(
                reverse("stock-unit-disburse-payout", args=[unit.pk]),
                {"method": "cash"},
                format="json",
            ).status_code,
            status.HTTP_403_FORBIDDEN,
        )


class UnitWriteApiTests(TestCase):
    """The two writes a person owns without moving stock, and the one that does."""

    def setUp(self):
        ensure_role_groups()
        self.manager = _user("manager", manager=True)
        self.client = APIClient()
        self.client.force_authenticate(user=self.manager)
        self.product = tracked_product(
            name="iPhone",
            sku="API-IP",
            mode=Product.TrackingMode.SERIAL,
            unit_price="1500.00",
        )
        self.variant = self.product.default_variant
        receive(
            variant=self.variant,
            quantity=2,
            unit_cost="1000.00",
            units=[{"code": "IMEI-A"}, {"code": "IMEI-B"}],
        )

    def test_bulk_reprice_marks_a_shelf_down_in_one_write(self):
        ids = list(StockUnit.objects.values_list("pk", flat=True))

        response = self.client.post(
            reverse("stock-unit-bulk-reprice"),
            {"ids": ids, "percent": "-20.00"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(response.data["updated"], 2)
        for unit in StockUnit.objects.all():
            # Twenty percent off what it was actually asking, which for an
            # article with no price of its own is the variant's.
            self.assertEqual(unit.list_price, Decimal("1200.00"))

    def test_bulk_reprice_refuses_a_price_and_a_percent_together(self):
        response = self.client.post(
            reverse("stock-unit-bulk-reprice"),
            {"ids": [1], "price": "10.00", "percent": "-20.00"},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_writing_one_off_moves_the_stock_and_records_why(self):
        unit = StockUnit.objects.first()

        response = self.client.post(
            reverse("stock-unit-write-off", args=[unit.pk]),
            {"reason": "سقط وانكسر"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        unit.refresh_from_db()
        self.assertEqual(unit.status, StockUnit.Status.WRITTEN_OFF)
        # The shelf dropped by one, rather than a status flipping on a unit the
        # bin still counts.
        from .models import StockItem

        item = StockItem.objects.get(variant=self.variant)
        self.assertEqual(item.quantity_on_hand, Decimal("1.000"))

    def test_a_write_off_needs_a_reason(self):
        unit = StockUnit.objects.first()
        response = self.client.post(
            reverse("stock-unit-write-off", args=[unit.pk]),
            {"reason": "  "},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)


class ConsignmentSearchTests(ConsignmentApiTestCase):
    """§6.2.1 asks both lists to be searchable by the owner's name.

    Worth a test of its own because the failure is not a wrong result — it is a
    500 the moment anybody types, from a field name that does not exist on the
    model and that nothing but a search request ever evaluates.
    """

    def test_agreements_are_searchable_by_the_consignor_s_name(self):
        self._agreement()

        response = self.client.get(
            reverse("consignment-agreement-list"), {"search": "سالم"}
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(len(response.data["results"]), 1)

    def test_agreements_are_searchable_by_phone(self):
        self._agreement()

        response = self.client.get(
            reverse("consignment-agreement-list"), {"search": "0912345678"}
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(len(response.data["results"]), 1)

    def test_payouts_are_searchable_by_the_consignor_s_name(self):
        agreement = self._agreement()
        self._submit(agreement["id"])
        unit = StockUnit.objects.get()
        self._sell(unit)
        self.client.post(
            reverse("stock-unit-disburse-payout", args=[unit.pk]),
            {"method": "bank"},
            format="json",
        )

        response = self.client.get(
            reverse("consignor-payout-list"), {"search": "سالم"}
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(len(response.data["results"]), 1)

    def test_a_payout_names_the_articles_it_paid_for(self):
        """A voucher that says «10,000 د.ل» and not which watch is a receipt
        for nothing."""
        agreement = self._agreement()
        self._submit(agreement["id"])
        unit = StockUnit.objects.get()
        self._sell(unit)
        created = self.client.post(
            reverse("stock-unit-disburse-payout", args=[unit.pk]),
            {"method": "bank"},
            format="json",
        )

        self.assertEqual(created.status_code, status.HTTP_200_OK, created.data)
        lines = created.data["lines"]
        self.assertEqual(len(lines), 1)
        self.assertEqual(lines[0]["code"], unit.code)
        self.assertEqual(Decimal(lines[0]["payout_due"]), Decimal("10000.00"))


class ConsignmentPayablesPagingTests(ConsignmentApiTestCase):
    """Fifty unpaid consignments, and the fifty-first.

    The units list learned this already: a hand-rolled list that sends every row
    grows until it stops, and a screen that filters the page it is holding
    answers "nothing owing" for a consignor whose row is further down. On a
    screen about money owed to people that is the worst available wrong answer.
    """

    def _sell_all(self):
        """One till, one shift — 55 sessions for one owner is a constraint
        violation, and also not a thing a shop does."""
        session = RegisterSession.objects.create(
            owner=self.manager,
            owner_key=f"user:{self.manager.pk}",
            status=RegisterSession.Status.OPEN,
            opening_cash=Decimal("0.00"),
        )
        for unit in StockUnit.objects.filter(
            status=StockUnit.Status.IN_STOCK
        ).order_by("id"):
            checkout_order(
                register_session=session,
                lines_data=[
                    {
                        "variant": self.variant,
                        "quantity": Decimal("1"),
                        "effective_unit_price": Decimal("12000.00"),
                        "stock_units": [unit.pk],
                    }
                ],
                payments_data=[
                    {"method": "cash", "amount": Decimal("12000.00")}
                ],
            )

    def _sell_many(self, count):
        agreement = self._agreement()
        self.client.post(
            reverse("consignment-agreement-submit", args=[agreement["id"]]),
            {
                "items": [
                    {
                        "variant": self.variant.pk,
                        "code": f"ROLEX-{index:03d}",
                        "declared_value": "12000.00",
                    }
                    for index in range(count)
                ]
            },
            format="json",
        )
        self._sell_all()

    def test_the_list_is_paged_and_says_there_is_more(self):
        self._sell_many(55)

        response = self.client.get(
            reverse("stock-unit-consignment-payables")
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(response.data["count"], 55)
        self.assertEqual(len(response.data["results"]), 50)
        self.assertIsNotNone(response.data["next"])

    def test_the_headline_is_the_whole_liability_not_the_page_s(self):
        self._sell_many(55)

        response = self.client.get(reverse("stock-unit-consignment-payables"))

        # 55 watches at a 10,000 fixed payout each.
        self.assertEqual(
            Decimal(response.data["total_due"]), Decimal("550000.00")
        )

    def test_the_fifty_first_is_reachable(self):
        self._sell_many(55)

        response = self.client.get(
            reverse("stock-unit-consignment-payables"), {"page": 2}
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(len(response.data["results"]), 5)

    def test_search_reaches_a_row_that_is_not_on_the_first_page(self):
        self._sell_many(55)

        response = self.client.get(
            reverse("stock-unit-consignment-payables"), {"search": "ROLEX-054"}
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(len(response.data["results"]), 1)
        self.assertEqual(response.data["results"][0]["code"], "ROLEX-054")

    def test_search_finds_the_owner_by_name(self):
        self._sell_many(2)

        response = self.client.get(
            reverse("stock-unit-consignment-payables"), {"search": "سالم"}
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(len(response.data["results"]), 2)


class ConsignmentQueryScalingTests(ConsignmentApiTestCase):
    """Neither list may pay a query per row.

    The payables screen joins four ways to render one line — the owner, the
    product, the invoice and its balance — and a payout voucher names the
    articles it settled. Both are the classic N+1 shape, and both are read at a
    counter with somebody waiting.
    """

    def _consign_and_sell(self, count, prefix):
        agreement = self._agreement()
        self.client.post(
            reverse("consignment-agreement-submit", args=[agreement["id"]]),
            {
                "items": [
                    {
                        "variant": self.variant.pk,
                        "code": f"{prefix}-{index:03d}",
                        "declared_value": "12000.00",
                    }
                    for index in range(count)
                ]
            },
            format="json",
        )
        session = RegisterSession.objects.filter(
            owner_key=f"user:{self.manager.pk}",
            status=RegisterSession.Status.OPEN,
        ).first() or RegisterSession.objects.create(
            owner=self.manager,
            owner_key=f"user:{self.manager.pk}",
            status=RegisterSession.Status.OPEN,
            opening_cash=Decimal("0.00"),
        )
        for unit in StockUnit.objects.filter(
            status=StockUnit.Status.IN_STOCK
        ).order_by("id"):
            checkout_order(
                register_session=session,
                lines_data=[
                    {
                        "variant": self.variant,
                        "quantity": Decimal("1"),
                        "effective_unit_price": Decimal("12000.00"),
                        "stock_units": [unit.pk],
                    }
                ],
                payments_data=[{"method": "cash", "amount": Decimal("12000.00")}],
            )

    def _measure(self, url, params=None):
        from django.db import connection
        from django.test.utils import CaptureQueriesContext

        self.client.get(url, params or {})
        with CaptureQueriesContext(connection) as ctx:
            response = self.client.get(url, params or {})
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        return len(ctx.captured_queries)

    def test_the_payables_list_does_not_pay_a_query_per_row(self):
        url = reverse("stock-unit-consignment-payables")
        self._consign_and_sell(3, "A")
        small = self._measure(url)
        self._consign_and_sell(6, "B")
        large = self._measure(url)

        self.assertEqual(
            small,
            large,
            f"consignment payables scaled with rows: {small} -> {large} (N+1)",
        )

    def test_the_payouts_list_does_not_pay_a_query_per_voucher(self):
        url = reverse("consignor-payout-list")
        self._consign_and_sell(4, "C")
        units = list(StockUnit.objects.filter(status=StockUnit.Status.SOLD))
        for unit in units[:2]:
            self.client.post(
                reverse("stock-unit-disburse-payout", args=[unit.pk]),
                {"method": "bank"},
                format="json",
            )
        small = self._measure(url)
        for unit in units[2:]:
            self.client.post(
                reverse("stock-unit-disburse-payout", args=[unit.pk]),
                {"method": "bank"},
                format="json",
            )
        large = self._measure(url)

        self.assertEqual(
            small,
            large,
            f"consignor payouts scaled with rows: {small} -> {large} (N+1)",
        )
