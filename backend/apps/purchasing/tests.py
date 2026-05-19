from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.models import Product
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.inventory.models import StockItem, StockMovement
from .models import (
    PurchaseOrder,
    PurchaseOrderAdjustment,
    PurchaseReceipt,
    Supplier,
    SupplierCredit,
    SupplierPayment,
)


class PurchaseOrderApiTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(
            username="purchase-manager",
            password="pass",
        )
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=self.user)
        self.product = Product.objects.create(
            sku="PUR-COFFEE",
            barcode="",
            name="Purchase coffee",
            unit_price=Decimal("4.00"),
        )
        self.supplier = Supplier.objects.create(name="Main supplier")

    def test_create_purchase_order_with_lines_calculates_totals(self):
        response = self.client.post(
            reverse("purchaseorder-list"),
            {
                "supplier": self.supplier.pk,
                "supplier_reference": "INV-100",
                "lines": [
                    {
                        "product": self.product.pk,
                        "quantity": 3,
                        "unit_cost": "2.50",
                    }
                ],
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data["status"], PurchaseOrder.Status.DRAFT)
        self.assertEqual(response.data["subtotal"], "7.50")
        self.assertEqual(response.data["total"], "7.50")
        self.assertTrue(response.data["order_number"].startswith("P"))
        self.assertEqual(len(response.data["lines"]), 1)

        order = PurchaseOrder.objects.get(pk=response.data["id"])
        self.assertEqual(order.lines.count(), 1)
        self.assertEqual(order.total, Decimal("7.50"))

    def test_purchase_order_due_date_and_accounting_fields_are_serialized(self):
        response = self.client.post(
            reverse("purchaseorder-list"),
            {
                "supplier": self.supplier.pk,
                "due_date": "2026-05-25",
                "lines": [
                    {
                        "product": self.product.pk,
                        "quantity": 3,
                        "unit_cost": "2.50",
                    }
                ],
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data["due_date"], "2026-05-25")
        self.assertEqual(response.data["paid_total"], "0.00")
        self.assertEqual(response.data["credit_applied_total"], "0.00")
        self.assertEqual(response.data["adjustment_credit_total"], "0.00")
        self.assertEqual(response.data["balance_due"], "7.50")
        self.assertEqual(response.data["payment_status"], "unpaid")
        self.assertFalse(response.data["is_overdue"])

    def test_purchase_order_requires_supplier(self):
        response = self.client.post(
            reverse("purchaseorder-list"),
            {
                "lines": [
                    {
                        "product": self.product.pk,
                        "quantity": 3,
                        "unit_cost": "2.50",
                    }
                ],
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("supplier", response.data)

    def test_purchase_order_detail_exposes_line_cost_change(self):
        previous = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.RECEIVED,
        )
        previous.lines.create(
            product=self.product,
            quantity=1,
            unit_cost=Decimal("2.00"),
        )
        create_response = self.client.post(
            reverse("purchaseorder-list"),
            {
                "supplier": self.supplier.pk,
                "lines": [
                    {
                        "product": self.product.pk,
                        "quantity": 3,
                        "unit_cost": "2.50",
                    }
                ],
            },
            format="json",
        )

        response = self.client.get(
            reverse("purchaseorder-detail", args=[create_response.data["id"]]),
        )

        self.assertEqual(create_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        line = response.data["lines"][0]
        self.assertEqual(line["previous_unit_cost"], "2.00")
        self.assertEqual(line["unit_cost_change"], "0.50")
        self.assertEqual(line["unit_cost_change_percent"], "25.00")
        self.assertTrue(line["unit_cost_changed"])

    def test_update_is_limited_to_draft_purchase_orders(self):
        order = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.SUBMITTED,
        )

        response = self.client.patch(
            reverse("purchaseorder-detail", args=[order.pk]),
            {"notes": "Too late"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("detail", response.data)

    def test_purchase_order_list_filters_by_supplier(self):
        other_supplier = Supplier.objects.create(name="Other supplier")
        first_order = PurchaseOrder.objects.create(supplier=self.supplier)
        second_order = PurchaseOrder.objects.create(supplier=other_supplier)

        response = self.client.get(
            reverse("purchaseorder-list"),
            {"supplier": self.supplier.pk},
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(len(response.data["results"]), 1)
        self.assertEqual(response.data["results"][0]["id"], first_order.pk)
        self.assertNotEqual(response.data["results"][0]["id"], second_order.pk)

    def test_submit_then_receive_increases_stock_transactionally(self):
        StockItem.objects.create(product=self.product, quantity_on_hand=5)
        create_response = self.client.post(
            reverse("purchaseorder-list"),
            {
                "supplier": self.supplier.pk,
                "lines": [
                    {
                        "product": self.product.pk,
                        "quantity": 4,
                        "unit_cost": "1.25",
                    }
                ],
            },
            format="json",
        )
        order_id = create_response.data["id"]

        submit_response = self.client.post(
            reverse("purchaseorder-submit", args=[order_id]),
            format="json",
        )

        self.assertEqual(submit_response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            submit_response.data["status"],
            PurchaseOrder.Status.SUBMITTED,
        )
        stock_item = StockItem.objects.get(product=self.product)
        self.assertEqual(stock_item.quantity_expected, 4)

        receive_response = self.client.post(
            reverse("purchaseorder-receive", args=[order_id]),
            format="json",
        )

        self.assertEqual(receive_response.status_code, status.HTTP_200_OK)
        self.assertEqual(receive_response.data["status"], PurchaseOrder.Status.RECEIVED)
        self.assertEqual(receive_response.data["lines"][0]["accepted_quantity"], 4)
        self.assertEqual(receive_response.data["lines"][0]["outstanding_quantity"], 0)
        self.assertEqual(len(receive_response.data["receipts"]), 1)

        stock_item = StockItem.objects.get(product=self.product)
        self.assertEqual(stock_item.quantity_on_hand, 9)
        self.assertEqual(stock_item.quantity_expected, 0)
        movement = StockMovement.objects.get(
            product=self.product,
            movement_type=StockMovement.Type.RECEIVE_EXPECTED,
        )
        self.assertEqual(movement.quantity, 4)
        self.assertEqual(movement.on_hand_before, 5)
        self.assertEqual(movement.on_hand_after, 9)
        self.assertEqual(movement.expected_before, 4)
        self.assertEqual(movement.expected_after, 0)
        self.assertEqual(movement.created_by, self.user)

    def test_partial_receipt_leaves_outstanding_expected_stock_open(self):
        StockItem.objects.create(product=self.product, quantity_on_hand=5)
        order = PurchaseOrder.objects.create(supplier=self.supplier)
        line = order.lines.create(
            product=self.product,
            quantity=10,
            unit_cost=Decimal("1.25"),
        )
        order.recalculate()
        order.save(update_fields=["subtotal", "total", "updated_at"])
        self.client.post(reverse("purchaseorder-submit", args=[order.pk]), format="json")

        response = self.client.post(
            reverse("purchaseorder-receive", args=[order.pk]),
            {
                "notes": "First carton only",
                "lines": [
                    {
                        "line": line.pk,
                        "accepted_quantity": 4,
                        "damaged_quantity": 2,
                    }
                ],
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["status"], PurchaseOrder.Status.PARTIALLY_RECEIVED)
        line_data = response.data["lines"][0]
        self.assertEqual(line_data["accepted_quantity"], 4)
        self.assertEqual(line_data["damaged_quantity"], 2)
        self.assertEqual(line_data["backordered_quantity"], 4)
        self.assertEqual(line_data["outstanding_quantity"], 4)
        self.assertEqual(line_data["adjustable_quantity"], 4)

        receipt_line = response.data["receipts"][0]["lines"][0]
        self.assertEqual(receipt_line["expected_reduction_quantity"], 6)
        self.assertEqual(receipt_line["outstanding_after"], 4)
        self.assertEqual(receipt_line["backordered_quantity"], 4)

        stock_item = StockItem.objects.get(product=self.product)
        self.assertEqual(stock_item.quantity_on_hand, 9)
        self.assertEqual(stock_item.quantity_expected, 4)
        self.assertTrue(
            StockMovement.objects.filter(
                product=self.product,
                movement_type=StockMovement.Type.RECEIVE_DAMAGED,
                quantity=2,
            ).exists()
        )

        finish_response = self.client.post(
            reverse("purchaseorder-receive", args=[order.pk]),
            format="json",
        )

        self.assertEqual(finish_response.status_code, status.HTTP_200_OK)
        self.assertEqual(finish_response.data["status"], PurchaseOrder.Status.RECEIVED)
        stock_item.refresh_from_db()
        self.assertEqual(stock_item.quantity_on_hand, 13)
        self.assertEqual(stock_item.quantity_expected, 0)

    def test_over_receipt_records_variance_and_stock_overage(self):
        StockItem.objects.create(product=self.product, quantity_on_hand=0)
        order = PurchaseOrder.objects.create(supplier=self.supplier)
        line = order.lines.create(
            product=self.product,
            quantity=3,
            unit_cost=Decimal("1.25"),
        )
        order.recalculate()
        order.save(update_fields=["subtotal", "total", "updated_at"])
        self.client.post(reverse("purchaseorder-submit", args=[order.pk]), format="json")

        response = self.client.post(
            reverse("purchaseorder-receive", args=[order.pk]),
            {"lines": [{"line": line.pk, "accepted_quantity": 5}]},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["status"], PurchaseOrder.Status.RECEIVED)
        self.assertEqual(response.data["lines"][0]["accepted_quantity"], 5)
        self.assertEqual(response.data["lines"][0]["over_received_quantity"], 2)
        self.assertEqual(response.data["receipts"][0]["lines"][0]["over_received_quantity"], 2)

        stock_item = StockItem.objects.get(product=self.product)
        self.assertEqual(stock_item.quantity_on_hand, 5)
        self.assertEqual(stock_item.quantity_expected, 0)
        self.assertTrue(
            StockMovement.objects.filter(
                product=self.product,
                movement_type=StockMovement.Type.INCREASE,
                quantity=2,
            ).exists()
        )

    def test_receipt_can_cancel_remaining_expected_quantity(self):
        StockItem.objects.create(product=self.product, quantity_on_hand=0)
        order = PurchaseOrder.objects.create(supplier=self.supplier)
        line = order.lines.create(
            product=self.product,
            quantity=5,
            unit_cost=Decimal("1.25"),
        )
        order.recalculate()
        order.save(update_fields=["subtotal", "total", "updated_at"])
        self.client.post(reverse("purchaseorder-submit", args=[order.pk]), format="json")

        response = self.client.post(
            reverse("purchaseorder-receive", args=[order.pk]),
            {
                "lines": [
                    {
                        "line": line.pk,
                        "accepted_quantity": 2,
                        "cancelled_quantity": 3,
                    }
                ]
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["status"], PurchaseOrder.Status.RECEIVED)
        self.assertEqual(response.data["lines"][0]["cancelled_quantity"], 3)
        stock_item = StockItem.objects.get(product=self.product)
        self.assertEqual(stock_item.quantity_on_hand, 2)
        self.assertEqual(stock_item.quantity_expected, 0)
        self.assertTrue(
            StockMovement.objects.filter(
                product=self.product,
                movement_type=StockMovement.Type.CANCEL_EXPECTED,
                quantity=3,
            ).exists()
        )

    def test_receipt_accepts_frontend_quantity_aliases(self):
        StockItem.objects.create(product=self.product, quantity_on_hand=0)
        order = PurchaseOrder.objects.create(supplier=self.supplier)
        line = order.lines.create(
            product=self.product,
            quantity=5,
            unit_cost=Decimal("1.25"),
        )
        order.recalculate()
        order.save(update_fields=["subtotal", "total", "updated_at"])
        self.client.post(reverse("purchaseorder-submit", args=[order.pk]), format="json")

        response = self.client.post(
            reverse("purchaseorder-receive", args=[order.pk]),
            {
                "note": "Frontend payload",
                "lines": [
                    {
                        "purchase_line": line.pk,
                        "quantity_received": 2,
                        "quantity_damaged": 1,
                        "quantity_rejected": 2,
                    }
                ],
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["status"], PurchaseOrder.Status.RECEIVED)
        self.assertEqual(response.data["receipts"][0]["notes"], "Frontend payload")
        line_data = response.data["lines"][0]
        self.assertEqual(line_data["accepted_quantity"], 2)
        self.assertEqual(line_data["damaged_quantity"], 1)
        self.assertEqual(line_data["cancelled_quantity"], 2)
        stock_item = StockItem.objects.get(product=self.product)
        self.assertEqual(stock_item.quantity_on_hand, 2)
        self.assertEqual(stock_item.quantity_expected, 0)

    def test_return_received_purchase_items_decreases_stock_and_records_adjustment(self):
        order = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.RECEIVED,
        )
        line = order.lines.create(
            product=self.product,
            quantity=4,
            unit_cost=Decimal("1.25"),
        )
        StockItem.objects.create(product=self.product, quantity_on_hand=5)

        response = self.client.post(
            reverse("purchaseorder-return-items", args=[order.pk]),
            {
                "reason": "Damaged case",
                "lines": [{"line": line.pk, "quantity": 2}],
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["lines"][0]["adjusted_quantity"], 2)
        self.assertEqual(response.data["lines"][0]["adjustable_quantity"], 2)
        self.assertTrue(response.data["can_return"])
        self.assertEqual(len(response.data["adjustments"]), 1)
        self.assertEqual(
            response.data["adjustments"][0]["adjustment_type"],
            PurchaseOrderAdjustment.AdjustmentType.RETURN,
        )
        self.assertEqual(response.data["adjustments"][0]["amount"], "2.50")
        self.assertEqual(
            response.data["adjustments"][0]["settlement_method"],
            PurchaseOrderAdjustment.SettlementMethod.SUPPLIER_CREDIT,
        )
        credit_data = response.data["adjustments"][0]["supplier_credit"]
        self.assertEqual(credit_data["supplier"], self.supplier.pk)
        self.assertEqual(credit_data["purchase_order"], order.pk)
        self.assertEqual(credit_data["amount"], "2.50")
        self.assertEqual(credit_data["remaining_amount"], "2.50")
        self.assertEqual(credit_data["status"], SupplierCredit.Status.OPEN)
        self.assertEqual(len(response.data["adjustments"][0]["credits"]), 1)
        self.assertEqual(
            response.data["adjustments"][0]["credits"][0]["amount"],
            "2.50",
        )
        self.assertEqual(SupplierCredit.objects.count(), 1)

        stock_item = StockItem.objects.get(product=self.product)
        self.assertEqual(stock_item.quantity_on_hand, 3)
        movement = StockMovement.objects.get(product=self.product)
        self.assertEqual(movement.movement_type, StockMovement.Type.DECREASE)
        self.assertEqual(movement.quantity, 2)
        self.assertEqual(movement.on_hand_before, 5)
        self.assertEqual(movement.on_hand_after, 3)
        self.assertEqual(movement.created_by, self.user)

    def test_refund_rejects_more_than_remaining_purchase_quantity(self):
        order = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.RECEIVED,
        )
        line = order.lines.create(
            product=self.product,
            quantity=2,
            unit_cost=Decimal("1.25"),
        )
        StockItem.objects.create(product=self.product, quantity_on_hand=5)
        self.client.post(
            reverse("purchaseorder-refund-items", args=[order.pk]),
            {"lines": [{"line": line.pk, "quantity": 1}]},
            format="json",
        )

        response = self.client.post(
            reverse("purchaseorder-refund-items", args=[order.pk]),
            {"lines": [{"line": line.pk, "quantity": 2}]},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("lines", response.data)
        self.assertEqual(StockItem.objects.get(product=self.product).quantity_on_hand, 4)

    def test_exchange_rejects_when_stock_is_not_available(self):
        order = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.RECEIVED,
        )
        line = order.lines.create(
            product=self.product,
            quantity=3,
            unit_cost=Decimal("1.25"),
        )
        StockItem.objects.create(product=self.product, quantity_on_hand=1)

        response = self.client.post(
            reverse("purchaseorder-exchange-items", args=[order.pk]),
            {"lines": [{"line": line.pk, "quantity": 2}]},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("stock", response.data)
        self.assertEqual(StockItem.objects.get(product=self.product).quantity_on_hand, 1)

    def test_purchase_adjustments_are_limited_to_received_orders(self):
        order = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.SUBMITTED,
        )
        line = order.lines.create(
            product=self.product,
            quantity=2,
            unit_cost=Decimal("1.25"),
        )

        response = self.client.post(
            reverse("purchaseorder-return-items", args=[order.pk]),
            {"lines": [{"line": line.pk, "quantity": 1}]},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("detail", response.data)

    def test_receive_rejects_draft_order_without_stock_change(self):
        order = PurchaseOrder.objects.create(supplier=self.supplier)
        order.lines.create(
            product=self.product,
            quantity=2,
            unit_cost=Decimal("1.00"),
        )
        StockItem.objects.create(product=self.product, quantity_on_hand=1)

        response = self.client.post(
            reverse("purchaseorder-receive", args=[order.pk]),
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("detail", response.data)
        self.assertEqual(StockItem.objects.get(product=self.product).quantity_on_hand, 1)
        self.assertEqual(StockMovement.objects.count(), 0)

    def test_duplicate_products_are_rejected(self):
        response = self.client.post(
            reverse("purchaseorder-list"),
            {
                "supplier": self.supplier.pk,
                "lines": [
                    {
                        "product": self.product.pk,
                        "quantity": 1,
                        "unit_cost": "1.00",
                    },
                    {
                        "product": self.product.pk,
                        "quantity": 2,
                        "unit_cost": "1.00",
                    },
                ],
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("lines", response.data)

    def test_cancel_submitted_purchase_order(self):
        order = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.SUBMITTED,
        )
        order.lines.create(
            product=self.product,
            quantity=2,
            unit_cost=Decimal("1.00"),
        )

        response = self.client.post(
            reverse("purchaseorder-cancel", args=[order.pk]),
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        order.refresh_from_db()
        self.assertEqual(order.status, PurchaseOrder.Status.CANCELLED)

    def test_cancel_rejects_received_purchase_order(self):
        order = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.RECEIVED,
        )

        response = self.client.post(
            reverse("purchaseorder-cancel", args=[order.pk]),
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        order.refresh_from_db()
        self.assertEqual(order.status, PurchaseOrder.Status.RECEIVED)

    def test_last_cost_returns_latest_non_cancelled_purchase_line_cost(self):
        cancelled = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.CANCELLED,
        )
        cancelled.lines.create(
            product=self.product,
            quantity=1,
            unit_cost=Decimal("9.99"),
        )
        first = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.RECEIVED,
        )
        first.lines.create(
            product=self.product,
            quantity=1,
            unit_cost=Decimal("1.25"),
        )
        latest = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.SUBMITTED,
        )
        latest.lines.create(
            product=self.product,
            quantity=1,
            unit_cost=Decimal("2.75"),
        )

        response = self.client.get(
            reverse("purchaseorder-last-cost"),
            {"product": self.product.pk},
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["unit_cost"], Decimal("2.75"))


class SupplierApiTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(
            username="supplier-manager",
            password="pass",
        )
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=self.user)

    def test_create_supplier_with_optional_phone_and_address(self):
        response = self.client.post(
            reverse("supplier-list"),
            {
                "name": "Main wholesaler",
                "contact_name": "Mona",
                "phone": "+21891222333",
                "email": "supplies@example.com",
                "address": "Tripoli",
                "notes": "Calls before delivery.",
                "is_active": True,
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        supplier = Supplier.objects.get(name="Main wholesaler")
        self.assertEqual(supplier.phone, "+21891222333")
        self.assertEqual(supplier.address, "Tripoli")

    def test_supplier_phone_is_optional(self):
        response = self.client.post(
            reverse("supplier-list"),
            {"name": "Phone later"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        supplier = Supplier.objects.get(name="Phone later")
        self.assertEqual(supplier.phone, "")

    def test_supplier_list_exposes_accounting_balances(self):
        supplier = Supplier.objects.create(name="Balance supplier")
        order = PurchaseOrder.objects.create(
            supplier=supplier,
            status=PurchaseOrder.Status.RECEIVED,
            subtotal=Decimal("10.00"),
            total=Decimal("10.00"),
        )
        adjustment = PurchaseOrderAdjustment.objects.create(
            purchase_order=order,
            adjustment_type=PurchaseOrderAdjustment.AdjustmentType.RETURN,
            amount=Decimal("2.00"),
            settlement_method=PurchaseOrderAdjustment.SettlementMethod.SUPPLIER_CREDIT,
            reason="Returned units",
        )
        SupplierCredit.objects.create(
            supplier=supplier,
            purchase_order=order,
            adjustment=adjustment,
            amount=Decimal("2.00"),
            remaining_amount=Decimal("2.00"),
            reason="Returned units",
        )
        SupplierPayment.objects.create(
            supplier=supplier,
            purchase_order=order,
            amount=Decimal("3.00"),
            method=SupplierPayment.Method.CASH,
        )

        response = self.client.get(reverse("supplier-list"))

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        row = response.data["results"][0]
        self.assertEqual(row["payable_balance"], "7.00")
        self.assertEqual(row["credit_balance"], "2.00")
        self.assertEqual(row["net_balance"], "5.00")


class SupplierPaymentApiTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(
            username="supplier-payment-manager",
            password="pass",
        )
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=self.user)
        self.product = Product.objects.create(
            sku="PUR-PAY",
            barcode="",
            name="Payment product",
            unit_price=Decimal("4.00"),
        )
        self.supplier = Supplier.objects.create(name="Payment supplier")

    def create_order(self, total=Decimal("7.50")):
        order = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.RECEIVED,
        )
        order.lines.create(
            product=self.product,
            quantity=3,
            unit_cost=(total / Decimal("3")).quantize(Decimal("0.01")),
        )
        order.recalculate()
        order.save(update_fields=["subtotal", "total", "updated_at"])
        return order

    def test_partial_supplier_payment_leaves_purchase_order_balance(self):
        order = self.create_order()

        response = self.client.post(
            reverse("supplierpayment-list"),
            {
                "supplier": self.supplier.pk,
                "purchase_order": order.pk,
                "amount": "3.00",
                "method": SupplierPayment.Method.CASH,
                "reference": "PAY-1",
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data["supplier_name"], self.supplier.name)
        self.assertEqual(response.data["purchase_order_number"], order.order_number)
        self.assertEqual(response.data["created_by_username"], self.user.username)

        detail = self.client.get(reverse("purchaseorder-detail", args=[order.pk]))
        self.assertEqual(detail.data["paid_total"], "3.00")
        self.assertEqual(detail.data["balance_due"], "4.50")
        self.assertEqual(detail.data["payment_status"], "partial")

    def test_supplier_payment_rejects_purchase_order_overpayment(self):
        order = self.create_order()

        response = self.client.post(
            reverse("supplierpayment-list"),
            {
                "supplier": self.supplier.pk,
                "purchase_order": order.pk,
                "amount": "8.00",
                "method": SupplierPayment.Method.CASH,
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("amount", response.data)
        self.assertEqual(SupplierPayment.objects.count(), 0)

    def test_supplier_credit_payment_is_limited_by_available_credit(self):
        order = self.create_order()
        credit_order = self.create_order(total=Decimal("2.00"))
        adjustment = PurchaseOrderAdjustment.objects.create(
            purchase_order=credit_order,
            adjustment_type=PurchaseOrderAdjustment.AdjustmentType.RETURN,
            amount=Decimal("2.00"),
            settlement_method=PurchaseOrderAdjustment.SettlementMethod.SUPPLIER_CREDIT,
        )
        SupplierCredit.objects.create(
            supplier=self.supplier,
            purchase_order=credit_order,
            adjustment=adjustment,
            amount=Decimal("2.00"),
            remaining_amount=Decimal("2.00"),
        )

        response = self.client.post(
            reverse("supplierpayment-list"),
            {
                "supplier": self.supplier.pk,
                "purchase_order": order.pk,
                "amount": "3.00",
                "method": SupplierPayment.Method.SUPPLIER_CREDIT,
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("amount", response.data)
        self.assertEqual(SupplierPayment.objects.count(), 0)

    def test_supplier_credit_payment_consumes_credit_and_reduces_order_balance(self):
        order = self.create_order()
        credit_order = self.create_order(total=Decimal("2.00"))
        adjustment = PurchaseOrderAdjustment.objects.create(
            purchase_order=credit_order,
            adjustment_type=PurchaseOrderAdjustment.AdjustmentType.RETURN,
            amount=Decimal("2.00"),
            settlement_method=PurchaseOrderAdjustment.SettlementMethod.SUPPLIER_CREDIT,
        )
        credit = SupplierCredit.objects.create(
            supplier=self.supplier,
            purchase_order=credit_order,
            adjustment=adjustment,
            amount=Decimal("2.00"),
            remaining_amount=Decimal("2.00"),
        )

        response = self.client.post(
            reverse("supplierpayment-list"),
            {
                "supplier": self.supplier.pk,
                "purchase_order": order.pk,
                "amount": "1.50",
                "method": SupplierPayment.Method.SUPPLIER_CREDIT,
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        credit.refresh_from_db()
        self.assertEqual(credit.remaining_amount, Decimal("0.50"))
        self.assertEqual(credit.status, SupplierCredit.Status.OPEN)

        detail = self.client.get(reverse("purchaseorder-detail", args=[order.pk]))
        self.assertEqual(detail.data["credit_applied_total"], "1.50")
        self.assertEqual(detail.data["balance_due"], "6.00")
