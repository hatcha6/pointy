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


class ConsignmentApiTests(TestCase):
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
