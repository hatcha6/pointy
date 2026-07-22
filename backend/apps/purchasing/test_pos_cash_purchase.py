"""POS cash purchases: a cashier's drawer-paid PO from the sell screen.

The flow under test is ``create_pos_cash_purchase`` behind
``POST /api/purchase-orders/pos-cash-purchase/``: one call creates the PO,
receives it into stock, pays it in full in cash, and records the linked
register pay-out so ``RegisterSession.expected_cash`` reconciles by itself.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.models import ProductUnit, UnitOfMeasure
from apps.catalog.testing import create_product_with_default_variant
from apps.core.models import ShopSettings
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.inventory.models import StockItem
from apps.sales.models import RegisterCashMovement, RegisterSession
from apps.sales.register_summary import build_register_session_summary

from .models import PurchaseOrder, Supplier, SupplierPayment


def pos_cash_purchase_permission():
    return Permission.objects.get(
        content_type__app_label="purchasing",
        codename="add_pos_cash_purchase",
    )


class PosCashPurchaseTestCase(TestCase):
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()

        # The target persona: a cashier whose owner granted the single extra
        # permission through the per-user allow-list.
        self.cashier = User.objects.create_user(username="pcp-cashier", password="pass")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.cashier.user_permissions.add(pos_cash_purchase_permission())

        self.plain_cashier = User.objects.create_user(
            username="pcp-plain-cashier", password="pass"
        )
        self.plain_cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))

        self.manager = User.objects.create_user(username="pcp-manager", password="pass")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))

        self.cashier_client = APIClient()
        self.cashier_client.force_authenticate(user=self.cashier)
        self.plain_client = APIClient()
        self.plain_client.force_authenticate(user=self.plain_cashier)
        self.manager_client = APIClient()
        self.manager_client.force_authenticate(user=self.manager)

        self.supplier = Supplier.objects.create(name="مخبز الصباح")
        self.product = create_product_with_default_variant(
            name="Bread", sku="POS-BREAD", unit_price="0.50"
        )
        self.variant = self.product.default_variant

    def open_session(self, user, opening_cash=Decimal("100.00")):
        return RegisterSession.objects.create(
            owner=user,
            owner_key=f"user:{user.pk}",
            status=RegisterSession.Status.OPEN,
            opening_cash=opening_cash,
        )

    def post_purchase(self, client=None, **overrides):
        payload = {
            "supplier": self.supplier.pk,
            "lines": [
                {
                    "variant": self.variant.pk,
                    "quantity": "20",
                    "unit_cost": "0.35",
                }
            ],
        }
        payload.update(overrides)
        return (client or self.cashier_client).post(
            reverse("purchaseorder-pos-cash-purchase"),
            payload,
            format="json",
        )


class PosCashPurchaseFlowTests(PosCashPurchaseTestCase):
    def test_creates_received_paid_po_with_linked_drawer_payout(self):
        session = self.open_session(self.cashier)
        response = self.post_purchase()
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)

        order = PurchaseOrder.objects.get(pk=response.data["id"])
        self.assertEqual(order.status, PurchaseOrder.Status.RECEIVED)
        self.assertIsNotNone(order.received_at)
        self.assertEqual(order.total, Decimal("7.00"))
        self.assertEqual(response.data["payment_status"], "paid")
        self.assertEqual(Decimal(response.data["balance_due"]), Decimal("0.00"))

        stock_item = StockItem.objects.get(variant=self.variant)
        self.assertEqual(stock_item.quantity_on_hand, Decimal("20"))
        self.assertEqual(stock_item.quantity_expected, Decimal("0"))

        payment = SupplierPayment.objects.get(purchase_order=order)
        self.assertEqual(payment.method, SupplierPayment.Method.CASH)
        self.assertEqual(payment.amount, Decimal("7.00"))
        self.assertEqual(payment.register_session_id, session.pk)
        self.assertEqual(payment.created_by, self.cashier)

        movement = payment.cash_movement
        self.assertIsNotNone(movement)
        self.assertEqual(
            movement.movement_type, RegisterCashMovement.MovementType.PAY_OUT
        )
        self.assertEqual(movement.amount, Decimal("7.00"))
        self.assertEqual(movement.register_session_id, session.pk)
        self.assertIn(self.supplier.name, movement.reason)
        self.assertIn(order.order_number, movement.reason)

        session.refresh_from_db()
        self.assertEqual(session.pay_out_total, Decimal("7.00"))
        self.assertEqual(session.expected_cash, Decimal("93.00"))

    def test_pack_line_converts_to_base_units_and_pays_pack_total(self):
        ProductUnit.objects.create(
            product=self.product,
            unit=UnitOfMeasure.objects.get(code="carton"),
            factor_to_base=Decimal("24"),
        )
        session = self.open_session(self.cashier)
        response = self.post_purchase(
            lines=[
                {
                    "variant": self.variant.pk,
                    "quantity": "2",
                    "unit": "carton",
                    "unit_cost": "12.00",
                }
            ],
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)

        stock_item = StockItem.objects.get(variant=self.variant)
        self.assertEqual(stock_item.quantity_on_hand, Decimal("48"))

        session.refresh_from_db()
        # Drawer takes the pack total (2 × 12), never a base-unit figure.
        self.assertEqual(session.pay_out_total, Decimal("24.00"))
        line = response.data["lines"][0]
        self.assertEqual(Decimal(line["base_unit_cost"]), Decimal("0.50"))

    def test_requires_open_register_session(self):
        response = self.post_purchase()
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("register session", str(response.data))
        self.assertEqual(PurchaseOrder.objects.count(), 0)
        self.assertEqual(SupplierPayment.objects.count(), 0)
        self.assertEqual(RegisterCashMovement.objects.count(), 0)

    def test_closed_session_does_not_count_as_open(self):
        session = self.open_session(self.cashier)
        session.status = RegisterSession.Status.CLOSED
        session.save(update_fields=["status"])
        response = self.post_purchase()
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_permission_is_required(self):
        self.open_session(self.plain_cashier)
        response = self.post_purchase(client=self.plain_client)
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        self.assertEqual(PurchaseOrder.objects.count(), 0)

    def test_manager_role_holds_the_permission_implicitly(self):
        self.open_session(self.manager)
        response = self.post_purchase(client=self.manager_client)
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)

    def test_cap_rejects_purchases_above_the_shop_limit(self):
        ShopSettings.objects.get_or_create(pk=1)
        ShopSettings.objects.filter(pk=1).update(
            pos_cash_purchase_limit=Decimal("5.00")
        )
        self.open_session(self.cashier)
        response = self.post_purchase()
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("capped", str(response.data))
        # The whole purchase rolls back — no PO, no stock, no drawer effect.
        self.assertEqual(PurchaseOrder.objects.count(), 0)
        self.assertFalse(StockItem.objects.filter(variant=self.variant).exists())
        self.assertEqual(RegisterCashMovement.objects.count(), 0)

    def test_cap_allows_purchases_at_or_under_the_limit(self):
        ShopSettings.objects.get_or_create(pk=1)
        ShopSettings.objects.filter(pk=1).update(
            pos_cash_purchase_limit=Decimal("7.00")
        )
        self.open_session(self.cashier)
        response = self.post_purchase()
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)

    def test_zero_cap_means_no_cap(self):
        ShopSettings.objects.get_or_create(pk=1)
        ShopSettings.objects.filter(pk=1).update(
            pos_cash_purchase_limit=Decimal("0.00")
        )
        self.open_session(self.cashier)
        response = self.post_purchase()
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)

    def test_expiry_tracked_product_still_requires_expiry_date(self):
        self.product.tracks_expiry = True
        self.product.save(update_fields=["tracks_expiry"])
        self.open_session(self.cashier)
        response = self.post_purchase()
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(PurchaseOrder.objects.count(), 0)

        response = self.post_purchase(
            lines=[
                {
                    "variant": self.variant.pk,
                    "quantity": "20",
                    "unit_cost": "0.35",
                    "expiry_date": "2027-01-01",
                }
            ],
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)


class PosCashPurchaseReadAccessTests(PosCashPurchaseTestCase):
    """The narrow permission doubles as read access to the two lookups the POS
    sheet needs: the supplier list and last-cost prefill. Nothing else opens."""

    def test_grants_supplier_list_but_not_management(self):
        response = self.cashier_client.get(reverse("supplier-list"))
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        response = self.cashier_client.post(
            reverse("supplier-list"), {"name": "مورد جديد"}, format="json"
        )
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_plain_cashier_still_cannot_list_suppliers(self):
        response = self.plain_client.get(reverse("supplier-list"))
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_grants_last_cost_but_not_po_list(self):
        response = self.cashier_client.get(
            reverse("purchaseorder-last-cost"),
            {"product": self.product.pk, "variant": self.variant.pk},
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        response = self.cashier_client.get(reverse("purchaseorder-list"))
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)


class PosCashPurchaseReportingTests(PosCashPurchaseTestCase):
    def test_ledger_shows_purchase_once_and_keeps_standalone_payouts(self):
        session = self.open_session(self.cashier)
        response = self.post_purchase()
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        RegisterCashMovement.objects.create(
            register_session=session,
            movement_type=RegisterCashMovement.MovementType.PAY_OUT,
            amount=Decimal("3.00"),
            reason="سحب نقدي عادي",
            created_by=self.cashier,
        )

        ledger = self.manager_client.get(reverse("expense-ledger"))
        self.assertEqual(ledger.status_code, status.HTTP_200_OK)
        data = ledger.json()
        # The linked pay-out is represented by its purchase row only; the
        # standalone pay-out keeps its register_payout row.
        self.assertEqual(data["totals"]["register_payout"], "3.00")
        self.assertEqual(data["totals"]["purchase"], "7.00")
        payout_rows = [
            row for row in data["rows"] if row["source"] == "register_payout"
        ]
        self.assertEqual(len(payout_rows), 1)
        self.assertEqual(payout_rows[0]["amount"], "3.00")

    def test_register_summary_attributes_drawer_purchases(self):
        session = self.open_session(self.cashier)
        response = self.post_purchase()
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)

        summary = build_register_session_summary(session)
        self.assertEqual(summary["drawer_purchases"]["total"], "7.00")
        self.assertEqual(summary["drawer_purchases"]["count"], 1)
        self.assertEqual(summary["cash"]["pay_out_total"], "7.00")
        self.assertEqual(summary["cash"]["expected_cash"], "93.00")
