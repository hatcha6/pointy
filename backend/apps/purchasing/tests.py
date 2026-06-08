from datetime import timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.core.exceptions import FieldError
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework import serializers, status
from rest_framework.test import APIClient

from apps.catalog.models import ProductVariant
from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.discounts.models import AppliedDiscount, DiscountRedemption, DiscountRule
from apps.inventory.models import StockBatch, StockItem, StockMovement
from apps.inventory.services import consume_expiring_stock_batches
from .models import (
    PurchaseLine,
    PurchaseOrder,
    PurchaseOrderAdjustment,
    PurchaseOrderAdjustmentLine,
    PurchaseOrderAuditEvent,
    PurchaseOrderLandedCostEntry,
    PurchaseReceipt,
    Supplier,
    SupplierCredit,
    SupplierPayment,
)
from .services import (
    adjust_purchase_order_items,
    receive_purchase_order,
    submit_purchase_order,
)


class PurchaseOrderLandedCostModelTests(TestCase):
    def setUp(self):
        self.supplier = Supplier.objects.create(name="Model supplier")
        self.products = [
            create_product_with_default_variant(
                sku=f"MODEL-PUR-{index}",
                barcode="",
                name=f"Model product {index}",
                unit_price=Decimal("1.00"),
            )
            for index in range(3)
        ]

    def test_recalculate_persists_deterministic_landed_cost_allocations(self):
        order = PurchaseOrder.objects.create(
            supplier=self.supplier,
            landed_cost_allocation_method=(
                PurchaseOrder.LandedCostAllocationMethod.QUANTITY
            ),
        )
        PurchaseOrderLandedCostEntry.objects.create(
            purchase_order=order,
            name="Freight",
            amount=Decimal("0.05"),
        )
        for product in self.products:
            order.lines.create(
                variant=product.default_variant,
                quantity=1,
                unit_cost=Decimal("1.00"),
            )

        order.recalculate()
        order.save(update_fields=["subtotal", "total", "updated_at"])

        order.refresh_from_db()
        lines = list(order.lines.order_by("created_at", "id"))
        self.assertEqual(order.subtotal, Decimal("3.00"))
        self.assertEqual(order.landed_cost_total, Decimal("0.05"))
        self.assertEqual(order.total, Decimal("3.05"))
        self.assertEqual(
            [line.allocated_landed_cost for line in lines],
            [Decimal("0.02"), Decimal("0.02"), Decimal("0.01")],
        )
        self.assertEqual(
            sum(line.allocated_landed_cost for line in lines),
            Decimal("0.05"),
        )
        self.assertEqual(lines[0].landed_unit_cost, Decimal("0.02"))
        self.assertEqual(lines[0].effective_unit_cost, Decimal("1.02"))


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
        self.product = create_product_with_default_variant(
            sku="PUR-COFFEE",
            barcode="",
            name="Purchase coffee",
            unit_price=Decimal("4.00"),
        )
        self.variant = self.product.default_variant
        self.other_product = create_product_with_default_variant(
            sku="PUR-TEA",
            barcode="",
            name="Purchase tea",
            unit_price=Decimal("3.00"),
        )
        self.other_variant = self.other_product.default_variant
        self.supplier = Supplier.objects.create(name="Main supplier")

    def purchase_order_payload(self, **overrides):
        payload = {
            "supplier": self.supplier.pk,
            "lines": [
                {
                    "variant": self.variant.pk,
                    "quantity": 3,
                    "unit_cost": "2.50",
                }
            ],
        }
        payload.update(overrides)
        return payload

    def authenticate_with_permissions(self, username, *permission_codes):
        user = get_user_model().objects.create_user(
            username=username,
            password="pass",
        )
        permissions = []
        for permission_code in permission_codes:
            app_label, codename = permission_code.split(".", 1)
            permissions.append(
                Permission.objects.get(
                    content_type__app_label=app_label,
                    codename=codename,
                )
            )
        user.user_permissions.add(*permissions)
        self.client.force_authenticate(user=user)
        return user

    def test_purchase_lines_reject_product_aliases(self):
        order = PurchaseOrder.objects.create(supplier=self.supplier)

        with self.assertRaises(TypeError):
            PurchaseLine.objects.create(
                purchase_order=order,
                product=self.product,
                quantity=1,
                unit_cost=Decimal("2.50"),
            )

        with self.assertRaises(FieldError):
            list(PurchaseLine.objects.filter(product=self.product))

    def test_create_purchase_order_with_lines_calculates_totals(self):
        response = self.client.post(
            reverse("purchaseorder-list"),
            self.purchase_order_payload(supplier_reference="INV-100"),
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data["status"], PurchaseOrder.Status.DRAFT)
        self.assertEqual(response.data["subtotal"], "7.50")
        self.assertEqual(response.data["discount_total"], "0.00")
        self.assertEqual(response.data["total"], "7.50")
        self.assertTrue(response.data["order_number"].startswith("P"))
        self.assertEqual(response.data["supplier_invoice_number"], "INV-100")
        self.assertEqual(response.data["supplier_reference"], "INV-100")
        self.assertEqual(len(response.data["lines"]), 1)
        self.assertEqual(
            response.data["lines"][0]["variant"],
            self.product.default_variant.pk,
        )
        self.assertEqual(response.data["lines"][0]["variant_name"], self.product.name)
        self.assertNotIn("tax_total", response.data)
        self.assertNotIn("tax_rate", response.data["lines"][0])

        order = PurchaseOrder.objects.get(pk=response.data["id"])
        self.assertEqual(order.lines.count(), 1)
        self.assertEqual(order.total, Decimal("7.50"))

    def test_create_purchase_order_replay_with_idempotency_key_returns_same_order(self):
        payload = self.purchase_order_payload(supplier_invoice_number="INV-IDEM")

        first_response = self.client.post(
            reverse("purchaseorder-list"),
            payload,
            format="json",
            HTTP_IDEMPOTENCY_KEY="purchase-order-retry-1",
        )
        second_response = self.client.post(
            reverse("purchaseorder-list"),
            payload,
            format="json",
            HTTP_IDEMPOTENCY_KEY="purchase-order-retry-1",
        )

        self.assertEqual(first_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(second_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(first_response["Idempotency-Replayed"], "false")
        self.assertEqual(second_response["Idempotency-Replayed"], "true")
        self.assertEqual(first_response.data["id"], second_response.data["id"])
        self.assertEqual(PurchaseOrder.objects.count(), 1)
        self.assertEqual(PurchaseLine.objects.count(), 1)
        self.assertEqual(PurchaseOrderAuditEvent.objects.count(), 1)

    def test_create_purchase_order_rejects_key_reused_with_different_body(self):
        first_response = self.client.post(
            reverse("purchaseorder-list"),
            self.purchase_order_payload(supplier_invoice_number="INV-CONFLICT"),
            format="json",
            HTTP_IDEMPOTENCY_KEY="purchase-order-conflict",
        )
        conflict_response = self.client.post(
            reverse("purchaseorder-list"),
            self.purchase_order_payload(
                supplier_invoice_number="INV-CONFLICT-2",
            ),
            format="json",
            HTTP_IDEMPOTENCY_KEY="purchase-order-conflict",
        )

        self.assertEqual(first_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(conflict_response.status_code, status.HTTP_409_CONFLICT)
        self.assertEqual(PurchaseOrder.objects.count(), 1)

    def test_expiry_tracked_product_requires_purchase_line_expiry_date(self):
        self.product.tracks_expiry = True
        self.product.save(update_fields=["tracks_expiry", "updated_at"])

        response = self.client.post(
            reverse("purchaseorder-list"),
            self.purchase_order_payload(),
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("expiry_date", response.data["lines"][0])

        expiry_date = timezone.localdate() + timedelta(days=45)
        response = self.client.post(
            reverse("purchaseorder-list"),
            self.purchase_order_payload(
                lines=[
                    {
                        "variant": self.variant.pk,
                        "quantity": 3,
                        "unit_cost": "2.50",
                        "expiry_date": expiry_date.isoformat(),
                    }
                ],
            ),
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        line_data = response.data["lines"][0]
        self.assertTrue(line_data["tracks_expiry"])
        self.assertEqual(line_data["expiry_date"], expiry_date.isoformat())

    def test_create_purchase_order_with_landed_costs_allocates_by_line_value(self):
        response = self.client.post(
            reverse("purchaseorder-list"),
            self.purchase_order_payload(
                landed_cost_entries=[
                    {"name": "شحن", "amount": "0.60"},
                    {"name": "تخليص", "amount": "0.30"},
                    {"name": "تحميل", "amount": "0.10"},
                ],
                landed_cost_allocation_method=(
                    PurchaseOrder.LandedCostAllocationMethod.LINE_VALUE
                ),
                lines=[
                    {
                        "variant": self.variant.pk,
                        "quantity": 3,
                        "unit_cost": "2.50",
                    },
                    {
                        "variant": self.other_variant.pk,
                        "quantity": 1,
                        "unit_cost": "2.50",
                    },
                ],
            ),
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data["subtotal"], "10.00")
        self.assertEqual(response.data["landed_cost_total"], "1.00")
        self.assertEqual(response.data["total"], "11.00")
        lines = sorted(response.data["lines"], key=lambda line: line["product"])
        self.assertEqual(lines[0]["allocated_landed_cost"], "0.75")
        self.assertEqual(lines[0]["landed_unit_cost"], "0.25")
        self.assertEqual(lines[0]["effective_unit_cost"], "2.75")
        self.assertEqual(lines[0]["effective_line_total"], "8.25")
        self.assertEqual(lines[1]["allocated_landed_cost"], "0.25")
        self.assertEqual(lines[1]["landed_unit_cost"], "0.25")
        self.assertEqual(lines[1]["effective_unit_cost"], "2.75")
        self.assertEqual(lines[1]["effective_line_total"], "2.75")

    def test_create_purchase_order_with_named_landed_cost_entries(self):
        response = self.client.post(
            reverse("purchaseorder-list"),
            self.purchase_order_payload(
                landed_cost_entries=[
                    {"name": "شحن طرابلس", "amount": "0.60"},
                    {"name": "تخليص جمركي", "amount": "0.40"},
                ],
                landed_cost_allocation_method=(
                    PurchaseOrder.LandedCostAllocationMethod.QUANTITY
                ),
                lines=[
                    {
                        "variant": self.variant.pk,
                        "quantity": 1,
                        "unit_cost": "1.00",
                    },
                    {
                        "variant": self.other_variant.pk,
                        "quantity": 3,
                        "unit_cost": "1.00",
                    },
                ],
            ),
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data["landed_cost_total"], "1.00")
        self.assertEqual(
            [entry["name"] for entry in response.data["landed_cost_entries"]],
            ["شحن طرابلس", "تخليص جمركي"],
        )
        self.assertEqual(
            [entry["amount"] for entry in response.data["landed_cost_entries"]],
            ["0.60", "0.40"],
        )
        lines = sorted(response.data["lines"], key=lambda line: line["quantity"])
        self.assertEqual(lines[0]["allocated_landed_cost"], "0.25")
        self.assertEqual(lines[1]["allocated_landed_cost"], "0.75")

    def test_legacy_landed_cost_fields_are_rejected(self):
        response = self.client.post(
            reverse("purchaseorder-list"),
            self.purchase_order_payload(
                shipping_amount="0.60",
                customs_amount="0.30",
                handling_amount="0.10",
            ),
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("shipping_amount", response.data)
        self.assertIn("customs_amount", response.data)
        self.assertIn("handling_amount", response.data)

    def test_create_purchase_order_with_landed_costs_allocates_by_quantity(self):
        response = self.client.post(
            reverse("purchaseorder-list"),
            self.purchase_order_payload(
                landed_cost_entries=[{"name": "شحن", "amount": "1.00"}],
                landed_cost_allocation_method=(
                    PurchaseOrder.LandedCostAllocationMethod.QUANTITY
                ),
                lines=[
                    {
                        "variant": self.variant.pk,
                        "quantity": 1,
                        "unit_cost": "1.00",
                    },
                    {
                        "variant": self.other_variant.pk,
                        "quantity": 2,
                        "unit_cost": "1.00",
                    },
                ],
            ),
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data["subtotal"], "3.00")
        self.assertEqual(response.data["total"], "4.00")
        allocations = [
            Decimal(line["allocated_landed_cost"])
            for line in response.data["lines"]
        ]
        self.assertEqual(sum(allocations), Decimal("1.00"))
        lines = sorted(response.data["lines"], key=lambda line: line["quantity"])
        self.assertEqual(lines[0]["allocated_landed_cost"], "0.33")
        self.assertEqual(lines[1]["allocated_landed_cost"], "0.67")

    def test_create_purchase_order_allocates_landed_cost_by_retail_value(self):
        response = self.client.post(
            reverse("purchaseorder-list"),
            self.purchase_order_payload(
                landed_cost_entries=[{"name": "تأمين", "amount": "7.00"}],
                landed_cost_allocation_method=(
                    PurchaseOrder.LandedCostAllocationMethod.RETAIL_VALUE
                ),
                lines=[
                    {
                        "variant": self.variant.pk,
                        "quantity": 1,
                        "unit_cost": "1.00",
                    },
                    {
                        "variant": self.other_variant.pk,
                        "quantity": 2,
                        "unit_cost": "1.00",
                    },
                ],
            ),
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        lines = sorted(response.data["lines"], key=lambda line: line["product"])
        self.assertEqual(lines[0]["allocated_landed_cost"], "2.80")
        self.assertEqual(lines[1]["allocated_landed_cost"], "4.20")

    def test_create_purchase_order_allocates_landed_cost_equally_by_line(self):
        response = self.client.post(
            reverse("purchaseorder-list"),
            self.purchase_order_payload(
                landed_cost_entries=[{"name": "رسوم مستند", "amount": "1.00"}],
                landed_cost_allocation_method=(
                    PurchaseOrder.LandedCostAllocationMethod.EQUAL
                ),
                lines=[
                    {
                        "variant": self.variant.pk,
                        "quantity": 1,
                        "unit_cost": "1.00",
                    },
                    {
                        "variant": self.other_variant.pk,
                        "quantity": 2,
                        "unit_cost": "1.00",
                    },
                ],
            ),
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        allocations = sorted(
            Decimal(line["allocated_landed_cost"])
            for line in response.data["lines"]
        )
        self.assertEqual(allocations, [Decimal("0.50"), Decimal("0.50")])

    def test_landed_cost_defaults_preserve_purchase_order_totals(self):
        response = self.client.post(
            reverse("purchaseorder-list"),
            self.purchase_order_payload(),
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data["landed_cost_entries"], [])
        self.assertEqual(response.data["landed_cost_total"], "0.00")
        self.assertEqual(response.data["total"], "7.50")
        line = response.data["lines"][0]
        self.assertEqual(line["allocated_landed_cost"], "0.00")
        self.assertEqual(line["landed_unit_cost"], "0.00")
        self.assertEqual(line["effective_unit_cost"], "2.50")

    def test_automatic_purchase_discount_reduces_payable_balance(self):
        DiscountRule.objects.create(
            name="Supplier ten percent",
            channel=DiscountRule.Channel.PURCHASING,
            value_type=DiscountRule.ValueType.PERCENTAGE,
            value=Decimal("10.00"),
        )

        response = self.client.post(
            reverse("purchaseorder-list"),
            self.purchase_order_payload(),
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data["subtotal"], "7.50")
        self.assertEqual(response.data["discount_total"], "0.75")
        self.assertEqual(response.data["total"], "6.75")
        self.assertEqual(response.data["balance_due"], "6.75")
        line = response.data["lines"][0]
        self.assertEqual(line["line_total"], "7.50")
        self.assertEqual(line["discount_amount"], "0.75")
        self.assertEqual(line["net_line_total"], "6.75")
        self.assertEqual(line["net_unit_cost"], "2.25")
        self.assertEqual(line["effective_unit_cost"], "2.25")

        supplier_response = self.client.get(reverse("supplier-detail", args=[self.supplier.pk]))
        self.assertEqual(supplier_response.data["payable_balance"], "6.75")
        self.assertEqual(supplier_response.data["total_bought"], "6.75")

    def test_purchase_coupon_discount_is_normalized_and_persisted_as_snapshot(self):
        DiscountRule.objects.create(
            name="Invoice coupon",
            channel=DiscountRule.Channel.PURCHASING,
            application_type=DiscountRule.ApplicationType.COUPON_CODE,
            coupon_code=" save2 ",
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("2.00"),
        )

        response = self.client.post(
            reverse("purchaseorder-list"),
            self.purchase_order_payload(discount_codes=[" save2 "]),
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data["discount_codes"], ["SAVE2"])
        self.assertEqual(response.data["discount_total"], "2.00")
        self.assertEqual(response.data["total"], "5.50")

        order = PurchaseOrder.objects.get(pk=response.data["id"])
        snapshot = AppliedDiscount.objects.get(document_object_id=order.pk)
        redemption = DiscountRedemption.objects.get(applied_discount=snapshot)
        line = order.lines.get()
        self.assertEqual(snapshot.document, order)
        self.assertEqual(snapshot.coupon_code, "SAVE2")
        self.assertEqual(snapshot.discount_amount, Decimal("2.00"))
        self.assertEqual(snapshot.allocations[0]["line_object_id"], line.pk)
        self.assertEqual(snapshot.allocations[0]["product_id"], self.product.pk)
        self.assertEqual(redemption.supplier, self.supplier)

    def test_purchase_discount_preview_reports_draft_backend_totals(self):
        DiscountRule.objects.create(
            name="Supplier automatic preview",
            channel=DiscountRule.Channel.PURCHASING,
            value_type=DiscountRule.ValueType.PERCENTAGE,
            value=Decimal("10.00"),
            priority=1,
            exclusive=False,
        )
        DiscountRule.objects.create(
            name="Supplier coupon preview",
            channel=DiscountRule.Channel.PURCHASING,
            application_type=DiscountRule.ApplicationType.COUPON_CODE,
            coupon_code="SUPSAVE",
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("1.00"),
            priority=2,
            exclusive=False,
        )

        response = self.client.post(
            reverse("purchaseorder-discount-preview"),
            {
                "supplier": self.supplier.pk,
                "discount_codes": [" supsave "],
                "landed_cost_entries": [
                    {"name": "شحن", "amount": "0.50"},
                ],
                "lines": [
                    {
                        "variant": self.variant.pk,
                        "quantity": 2,
                        "unit_cost": "5.00",
                    }
                ],
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(response.data["subtotal"], "10.00")
        self.assertEqual(response.data["discount_total"], "2.00")
        self.assertEqual(response.data["landed_cost_total"], "0.50")
        self.assertEqual(response.data["total"], "8.50")
        self.assertEqual(response.data["unapplied_discount_codes"], [])
        self.assertEqual(
            [discount["rule_name"] for discount in response.data["applied_discounts"]],
            ["Supplier automatic preview", "Supplier coupon preview"],
        )
        self.assertEqual(response.data["lines"][0]["discount_amount"], "2.00")
        self.assertEqual(response.data["lines"][0]["net_unit_cost"], "4.00")
        self.assertEqual(response.data["lines"][0]["effective_unit_cost"], "4.25")
        self.assertEqual(PurchaseOrder.objects.count(), 0)
        self.assertEqual(DiscountRedemption.objects.count(), 0)

    def test_purchase_discount_preview_accepts_named_landed_cost_entries(self):
        response = self.client.post(
            reverse("purchaseorder-discount-preview"),
            {
                "supplier": self.supplier.pk,
                "landed_cost_entries": [
                    {"name": "شحن", "amount": "0.25"},
                    {"name": "تحميل", "amount": "0.75"},
                ],
                "landed_cost_allocation_method": "quantity",
                "lines": [
                    {
                        "variant": self.variant.pk,
                        "quantity": 1,
                        "unit_cost": "2.00",
                    },
                    {
                        "variant": self.other_variant.pk,
                        "quantity": 3,
                        "unit_cost": "2.00",
                    },
                ],
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(response.data["landed_cost_total"], "1.00")
        self.assertEqual(response.data["total"], "9.00")
        lines = sorted(response.data["lines"], key=lambda line: line["quantity"])
        self.assertEqual(lines[0]["allocated_landed_cost"], "0.25")
        self.assertEqual(lines[1]["allocated_landed_cost"], "0.75")

    def test_purchase_discount_preview_reports_rounding_metadata(self):
        DiscountRule.objects.create(
            name="Rounded supplier preview",
            channel=DiscountRule.Channel.PURCHASING,
            value_type=DiscountRule.ValueType.PERCENTAGE,
            value=Decimal("10.00"),
            rounding_mode=DiscountRule.RoundingMode.DOWN,
            rounding_increment=Decimal("0.25"),
        )

        response = self.client.post(
            reverse("purchaseorder-discount-preview"),
            {
                "supplier": self.supplier.pk,
                "lines": [
                    {
                        "variant": self.variant.pk,
                        "quantity": 1,
                        "unit_cost": "10.10",
                    }
                ],
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(response.data["subtotal"], "10.10")
        self.assertEqual(response.data["discount_total"], "1.10")
        self.assertEqual(response.data["total"], "9.00")
        discount = response.data["applied_discounts"][0]
        self.assertEqual(discount["rounding_mode"], "down")
        self.assertEqual(discount["rounding_increment"], "0.25")
        self.assertEqual(discount["unrounded_discount_amount"], "1.01")
        self.assertEqual(discount["rounding_adjustment"], "0.09")

    def test_purchase_discount_preview_reports_unapplied_code(self):
        response = self.client.post(
            reverse("purchaseorder-discount-preview"),
            {
                "supplier": self.supplier.pk,
                "discount_code": "missing",
                "lines": [
                    {
                        "variant": self.variant.pk,
                        "quantity": 1,
                        "unit_cost": "2.50",
                    }
                ],
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(response.data["discount_total"], "0.00")
        self.assertEqual(response.data["unapplied_discount_codes"], ["MISSING"])

    def test_purchase_discount_update_replaces_snapshots_and_redemptions(self):
        DiscountRule.objects.create(
            name="Draft coupon",
            channel=DiscountRule.Channel.PURCHASING,
            application_type=DiscountRule.ApplicationType.COUPON_CODE,
            coupon_code="DRAFT",
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("2.00"),
        )
        create_response = self.client.post(
            reverse("purchaseorder-list"),
            self.purchase_order_payload(discount_codes=["draft"]),
            format="json",
        )
        order_id = create_response.data["id"]

        update_response = self.client.patch(
            reverse("purchaseorder-detail", args=[order_id]),
            {"discount_codes": []},
            format="json",
        )

        self.assertEqual(create_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(create_response.data["discount_total"], "2.00")
        self.assertEqual(update_response.status_code, status.HTTP_200_OK)
        self.assertEqual(update_response.data["discount_codes"], [])
        self.assertEqual(update_response.data["discount_total"], "0.00")
        self.assertEqual(update_response.data["total"], "7.50")
        self.assertEqual(update_response.data["applied_discounts"], [])
        self.assertEqual(AppliedDiscount.objects.count(), 0)
        self.assertEqual(DiscountRedemption.objects.count(), 0)

    def test_deleting_draft_purchase_clears_discount_audit_rows(self):
        DiscountRule.objects.create(
            name="Delete coupon",
            channel=DiscountRule.Channel.PURCHASING,
            application_type=DiscountRule.ApplicationType.COUPON_CODE,
            coupon_code="DELETE",
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("1.00"),
        )
        create_response = self.client.post(
            reverse("purchaseorder-list"),
            self.purchase_order_payload(discount_codes=["delete"]),
            format="json",
        )

        delete_response = self.client.delete(
            reverse("purchaseorder-detail", args=[create_response.data["id"]]),
        )

        self.assertEqual(create_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(delete_response.status_code, status.HTTP_204_NO_CONTENT)
        self.assertEqual(PurchaseOrder.objects.count(), 0)
        self.assertEqual(AppliedDiscount.objects.count(), 0)
        self.assertEqual(DiscountRedemption.objects.count(), 0)

    def test_line_and_document_purchase_discounts_feed_landed_cost_weights(self):
        line_rule = DiscountRule.objects.create(
            name="Unit supplier rebate",
            channel=DiscountRule.Channel.PURCHASING,
            scope=DiscountRule.Scope.LINE,
            value_type=DiscountRule.ValueType.FIXED_UNIT_AMOUNT,
            value=Decimal("1.00"),
            priority=1,
            exclusive=False,
        )
        line_rule.products.add(self.product)
        DiscountRule.objects.create(
            name="Document supplier rebate",
            channel=DiscountRule.Channel.PURCHASING,
            value_type=DiscountRule.ValueType.PERCENTAGE,
            value=Decimal("10.00"),
            priority=2,
            exclusive=False,
        )

        response = self.client.post(
            reverse("purchaseorder-list"),
            self.purchase_order_payload(
                landed_cost_entries=[
                    {"name": "شحن", "amount": "3.42"},
                ],
                landed_cost_allocation_method=(
                    PurchaseOrder.LandedCostAllocationMethod.LINE_VALUE
                ),
                lines=[
                    {
                        "variant": self.variant.pk,
                        "quantity": 2,
                        "unit_cost": "10.00",
                    },
                    {
                        "variant": self.other_variant.pk,
                        "quantity": 1,
                        "unit_cost": "20.00",
                    },
                ],
            ),
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data["subtotal"], "40.00")
        self.assertEqual(response.data["discount_total"], "5.80")
        self.assertEqual(response.data["landed_cost_total"], "3.42")
        self.assertEqual(response.data["total"], "37.62")
        lines = sorted(response.data["lines"], key=lambda line: line["product"])
        self.assertEqual(lines[0]["discount_amount"], "3.80")
        self.assertEqual(lines[0]["net_line_total"], "16.20")
        self.assertEqual(lines[0]["allocated_landed_cost"], "1.62")
        self.assertEqual(lines[0]["effective_line_total"], "17.82")
        self.assertEqual(lines[1]["discount_amount"], "2.00")
        self.assertEqual(lines[1]["net_line_total"], "18.00")
        self.assertEqual(lines[1]["allocated_landed_cost"], "1.80")
        self.assertEqual(lines[1]["effective_line_total"], "19.80")

    def test_invalid_disabled_or_expired_purchase_coupon_is_rejected(self):
        DiscountRule.objects.create(
            name="Disabled coupon",
            channel=DiscountRule.Channel.PURCHASING,
            application_type=DiscountRule.ApplicationType.COUPON_CODE,
            coupon_code="OFF",
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("1.00"),
            is_active=False,
        )
        DiscountRule.objects.create(
            name="Expired coupon",
            channel=DiscountRule.Channel.PURCHASING,
            application_type=DiscountRule.ApplicationType.COUPON_CODE,
            coupon_code="OLD",
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("1.00"),
            ends_at=timezone.now() - timezone.timedelta(days=1),
        )

        for code in ("MISSING", "OFF", "OLD"):
            with self.subTest(code=code):
                response = self.client.post(
                    reverse("purchaseorder-list"),
                    self.purchase_order_payload(discount_codes=[code]),
                    format="json",
                )

                self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
                self.assertIn("discount_codes", response.data)
                self.assertEqual(PurchaseOrder.objects.count(), 0)

    def test_purchase_coupon_respects_supplier_usage_limit(self):
        DiscountRule.objects.create(
            name="Supplier once",
            channel=DiscountRule.Channel.PURCHASING,
            application_type=DiscountRule.ApplicationType.COUPON_CODE,
            coupon_code="SUPONCE",
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("1.00"),
            per_supplier_usage_limit=1,
        )

        first_response = self.client.post(
            reverse("purchaseorder-list"),
            self.purchase_order_payload(discount_codes=["suponce"]),
            format="json",
        )
        second_response = self.client.post(
            reverse("purchaseorder-list"),
            self.purchase_order_payload(discount_codes=["suponce"]),
            format="json",
        )

        self.assertEqual(first_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(first_response.data["discount_total"], "1.00")
        self.assertEqual(second_response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("discount_codes", second_response.data)
        self.assertEqual(PurchaseOrder.objects.count(), 1)
        self.assertEqual(DiscountRedemption.objects.count(), 1)

    def test_negative_landed_cost_is_rejected(self):
        response = self.client.post(
            reverse("purchaseorder-list"),
            self.purchase_order_payload(
                landed_cost_entries=[{"name": "شحن", "amount": "-0.01"}],
            ),
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("landed_cost_entries", response.data)

    def test_invalid_landed_cost_allocation_method_is_rejected(self):
        response = self.client.post(
            reverse("purchaseorder-list"),
            self.purchase_order_payload(landed_cost_allocation_method="weight"),
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("landed_cost_allocation_method", response.data)

    def test_purchase_order_due_date_and_accounting_fields_are_serialized(self):
        due_date = timezone.localdate() + timezone.timedelta(days=7)
        response = self.client.post(
            reverse("purchaseorder-list"),
            {
                "supplier": self.supplier.pk,
                "due_date": due_date.isoformat(),
                "lines": [
                    {
                        "variant": self.variant.pk,
                        "quantity": 3,
                        "unit_cost": "2.50",
                    }
                ],
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data["due_date"], due_date.isoformat())
        self.assertEqual(response.data["paid_total"], "0.00")
        self.assertEqual(response.data["credit_applied_total"], "0.00")
        self.assertEqual(response.data["adjustment_credit_total"], "0.00")
        self.assertEqual(response.data["balance_due"], "7.50")
        self.assertEqual(response.data["payment_status"], "unpaid")
        self.assertFalse(response.data["is_overdue"])

    def test_purchase_order_supplier_invoice_fields_are_serialized(self):
        response = self.client.post(
            reverse("purchaseorder-list"),
            self.purchase_order_payload(
                supplier_invoice_number="INV-200",
                supplier_invoice_date="2026-05-18",
            ),
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(
            response.data["order_number"],
            PurchaseOrder.objects.get().order_number,
        )
        self.assertEqual(response.data["supplier_invoice_number"], "INV-200")
        self.assertEqual(response.data["supplier_invoice_date"], "2026-05-18")
        self.assertEqual(response.data["supplier_reference"], "INV-200")

    def test_supplier_reference_is_accepted_as_legacy_invoice_number(self):
        response = self.client.post(
            reverse("purchaseorder-list"),
            self.purchase_order_payload(supplier_reference="LEGACY-100"),
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        order = PurchaseOrder.objects.get(pk=response.data["id"])
        self.assertEqual(order.supplier_invoice_number, "LEGACY-100")
        self.assertEqual(response.data["supplier_invoice_number"], "LEGACY-100")
        self.assertEqual(response.data["supplier_reference"], "LEGACY-100")

    def test_duplicate_supplier_invoice_number_is_rejected_for_same_supplier(self):
        self.client.post(
            reverse("purchaseorder-list"),
            self.purchase_order_payload(supplier_invoice_number="DUP-100"),
            format="json",
        )

        response = self.client.post(
            reverse("purchaseorder-list"),
            self.purchase_order_payload(supplier_invoice_number="DUP-100"),
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("supplier_invoice_number", response.data)

    def test_supplier_invoice_number_can_repeat_for_different_suppliers(self):
        other_supplier = Supplier.objects.create(name="Other supplier")
        first_response = self.client.post(
            reverse("purchaseorder-list"),
            self.purchase_order_payload(supplier_invoice_number="SHARED-100"),
            format="json",
        )
        second_response = self.client.post(
            reverse("purchaseorder-list"),
            self.purchase_order_payload(
                supplier=other_supplier.pk,
                supplier_invoice_number="SHARED-100",
            ),
            format="json",
        )

        self.assertEqual(first_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(second_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(PurchaseOrder.objects.count(), 2)

    def test_blank_supplier_invoice_number_can_repeat(self):
        first_response = self.client.post(
            reverse("purchaseorder-list"),
            self.purchase_order_payload(supplier_invoice_number=""),
            format="json",
        )
        second_response = self.client.post(
            reverse("purchaseorder-list"),
            self.purchase_order_payload(supplier_invoice_number=""),
            format="json",
        )

        self.assertEqual(first_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(second_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(PurchaseOrder.objects.count(), 2)

    def test_update_duplicate_supplier_invoice_number_is_rejected(self):
        existing = PurchaseOrder.objects.create(
            supplier=self.supplier,
            supplier_invoice_number="UPDATE-DUP-100",
        )
        order = PurchaseOrder.objects.create(supplier=self.supplier)

        response = self.client.patch(
            reverse("purchaseorder-detail", args=[order.pk]),
            {"supplier_invoice_number": existing.supplier_invoice_number},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("supplier_invoice_number", response.data)
        order.refresh_from_db()
        self.assertEqual(order.supplier_invoice_number, "")

    def test_purchase_order_requires_supplier(self):
        response = self.client.post(
            reverse("purchaseorder-list"),
            {
                "lines": [
                    {
                        "variant": self.variant.pk,
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
            variant=self.variant,
            quantity=1,
            unit_cost=Decimal("2.00"),
        )
        create_response = self.client.post(
            reverse("purchaseorder-list"),
            {
                "supplier": self.supplier.pk,
                "lines": [
                    {
                        "variant": self.variant.pk,
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

    def test_purchase_order_workflow_actions_require_specific_permissions(self):
        draft_order = PurchaseOrder.objects.create(supplier=self.supplier)
        self.authenticate_with_permissions(
            "legacy-change-only",
            "purchasing.change_purchaseorder",
        )
        edit_response = self.client.patch(
            reverse("purchaseorder-detail", args=[draft_order.pk]),
            {"notes": "Requires draft edit permission"},
            format="json",
        )
        self.assertEqual(edit_response.status_code, status.HTTP_403_FORBIDDEN)

        submitted_order = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.SUBMITTED,
        )
        submitted_order.lines.create(
            variant=self.variant,
            quantity=1,
            unit_cost=Decimal("1.00"),
        )
        self.authenticate_with_permissions(
            "receive-without-stock",
            "purchasing.receive_purchaseorder",
        )
        receive_without_stock_response = self.client.post(
            reverse("purchaseorder-receive", args=[submitted_order.pk]),
            format="json",
        )
        self.assertEqual(
            receive_without_stock_response.status_code,
            status.HTTP_403_FORBIDDEN,
        )

        self.authenticate_with_permissions(
            "legacy-receive-only",
            "purchasing.change_purchaseorder",
            "inventory.add_stockmovement",
        )
        receive_response = self.client.post(
            reverse("purchaseorder-receive", args=[submitted_order.pk]),
            format="json",
        )
        self.assertEqual(receive_response.status_code, status.HTTP_403_FORBIDDEN)

        received_order = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.RECEIVED,
        )
        received_line = received_order.lines.create(
            variant=self.variant,
            quantity=1,
            unit_cost=Decimal("1.00"),
        )
        StockItem.objects.create(variant=self.variant, quantity_on_hand=1)
        self.authenticate_with_permissions(
            "legacy-adjust-only",
            "purchasing.change_purchaseorder",
            "inventory.add_stockmovement",
        )
        adjust_response = self.client.post(
            reverse("purchaseorder-return-items", args=[received_order.pk]),
            {"lines": [{"line": received_line.pk, "quantity": 1}]},
            format="json",
        )
        self.assertEqual(adjust_response.status_code, status.HTTP_403_FORBIDDEN)

        self.authenticate_with_permissions(
            "legacy-cancel-only",
            "purchasing.change_purchaseorder",
        )
        cancel_response = self.client.post(
            reverse("purchaseorder-cancel", args=[draft_order.pk]),
            format="json",
        )
        self.assertEqual(cancel_response.status_code, status.HTTP_403_FORBIDDEN)

    def test_purchase_order_audit_events_are_recorded_for_workflow_actions(self):
        create_response = self.client.post(
            reverse("purchaseorder-list"),
            self.purchase_order_payload(),
            format="json",
        )
        self.assertEqual(create_response.status_code, status.HTTP_201_CREATED)
        order = PurchaseOrder.objects.get(pk=create_response.data["id"])
        self.assertEqual(create_response.data["audit_events"][0]["action"], "created")

        update_response = self.client.patch(
            reverse("purchaseorder-detail", args=[order.pk]),
            {"notes": "Checked by manager"},
            format="json",
        )
        self.assertEqual(update_response.status_code, status.HTTP_200_OK)

        submit_response = self.client.post(
            reverse("purchaseorder-submit", args=[order.pk]),
            format="json",
        )
        self.assertEqual(submit_response.status_code, status.HTTP_200_OK)

        receive_response = self.client.post(
            reverse("purchaseorder-receive", args=[order.pk]),
            format="json",
        )
        self.assertEqual(receive_response.status_code, status.HTTP_200_OK)

        line = order.lines.get()
        adjust_response = self.client.post(
            reverse("purchaseorder-return-items", args=[order.pk]),
            {"lines": [{"line": line.pk, "quantity": 1}]},
            format="json",
        )
        self.assertEqual(adjust_response.status_code, status.HTTP_200_OK)

        actions = set(
            PurchaseOrderAuditEvent.objects.filter(purchase_order=order).values_list(
                "action",
                flat=True,
            )
        )
        self.assertEqual(
            actions,
            {
                PurchaseOrderAuditEvent.Action.CREATED,
                PurchaseOrderAuditEvent.Action.UPDATED,
                PurchaseOrderAuditEvent.Action.SUBMITTED,
                PurchaseOrderAuditEvent.Action.RECEIVED,
                PurchaseOrderAuditEvent.Action.ADJUSTED,
            },
        )
        self.assertTrue(
            PurchaseOrderAuditEvent.objects.filter(created_by=self.user).exists()
        )

        cancel_response = self.client.post(
            reverse("purchaseorder-list"),
            self.purchase_order_payload(),
            format="json",
        )
        cancel_order = PurchaseOrder.objects.get(pk=cancel_response.data["id"])
        response = self.client.post(
            reverse("purchaseorder-cancel", args=[cancel_order.pk]),
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertTrue(
            PurchaseOrderAuditEvent.objects.filter(
                purchase_order=cancel_order,
                action=PurchaseOrderAuditEvent.Action.CANCELLED,
                created_by=self.user,
            ).exists()
        )

        delete_response = self.client.post(
            reverse("purchaseorder-list"),
            self.purchase_order_payload(),
            format="json",
        )
        delete_order = PurchaseOrder.objects.get(pk=delete_response.data["id"])
        delete_order_number = delete_order.order_number
        response = self.client.delete(
            reverse("purchaseorder-detail", args=[delete_order.pk]),
        )
        self.assertEqual(response.status_code, status.HTTP_204_NO_CONTENT)
        self.assertFalse(PurchaseOrder.objects.filter(pk=delete_order.pk).exists())
        self.assertTrue(
            PurchaseOrderAuditEvent.objects.filter(
                purchase_order__isnull=True,
                order_number=delete_order_number,
                action=PurchaseOrderAuditEvent.Action.DELETED,
                created_by=self.user,
            ).exists()
        )

    def test_non_draft_purchase_order_delete_is_blocked(self):
        order = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.SUBMITTED,
        )

        response = self.client.delete(reverse("purchaseorder-detail", args=[order.pk]))

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("detail", response.data)
        self.assertTrue(PurchaseOrder.objects.filter(pk=order.pk).exists())
        self.assertFalse(
            PurchaseOrderAuditEvent.objects.filter(
                purchase_order=order,
                action=PurchaseOrderAuditEvent.Action.DELETED,
            ).exists()
        )

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
        StockItem.objects.create(variant=self.variant, quantity_on_hand=5)
        create_response = self.client.post(
            reverse("purchaseorder-list"),
            {
                "supplier": self.supplier.pk,
                "lines": [
                    {
                        "variant": self.variant.pk,
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
        stock_item = StockItem.objects.get(variant=self.variant)
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

        stock_item = StockItem.objects.get(variant=self.variant)
        self.assertEqual(stock_item.quantity_on_hand, 9)
        self.assertEqual(stock_item.quantity_expected, 0)
        movement = StockMovement.objects.get(
            variant=self.variant,
            movement_type=StockMovement.Type.RECEIVE_EXPECTED,
        )
        self.assertEqual(movement.quantity, 4)
        self.assertEqual(movement.on_hand_before, 5)
        self.assertEqual(movement.on_hand_after, 9)
        self.assertEqual(movement.expected_before, 4)
        self.assertEqual(movement.expected_after, 0)
        self.assertEqual(movement.created_by, self.user)

    def test_receive_purchase_order_replay_does_not_duplicate_receipt_or_stock(self):
        StockItem.objects.create(variant=self.variant, quantity_on_hand=5)
        create_response = self.client.post(
            reverse("purchaseorder-list"),
            self.purchase_order_payload(
                lines=[
                    {
                        "variant": self.variant.pk,
                        "quantity": 3,
                        "unit_cost": "1.25",
                    }
                ],
            ),
            format="json",
        )
        order_id = create_response.data["id"]
        self.client.post(reverse("purchaseorder-submit", args=[order_id]), format="json")

        first_response = self.client.post(
            reverse("purchaseorder-receive", args=[order_id]),
            format="json",
            HTTP_IDEMPOTENCY_KEY="purchase-receive-retry-1",
        )
        second_response = self.client.post(
            reverse("purchaseorder-receive", args=[order_id]),
            format="json",
            HTTP_IDEMPOTENCY_KEY="purchase-receive-retry-1",
        )

        self.assertEqual(first_response.status_code, status.HTTP_200_OK)
        self.assertEqual(second_response.status_code, status.HTTP_200_OK)
        self.assertEqual(first_response["Idempotency-Replayed"], "false")
        self.assertEqual(second_response["Idempotency-Replayed"], "true")
        self.assertEqual(len(first_response.data["receipts"]), 1)
        self.assertEqual(len(second_response.data["receipts"]), 1)
        self.assertEqual(PurchaseReceipt.objects.filter(purchase_order_id=order_id).count(), 1)
        self.assertEqual(
            StockMovement.objects.filter(
                variant=self.variant,
                movement_type=StockMovement.Type.RECEIVE_EXPECTED,
            ).count(),
            1,
        )
        stock_item = StockItem.objects.get(variant=self.variant)
        self.assertEqual(stock_item.quantity_on_hand, 8)
        self.assertEqual(stock_item.quantity_expected, 0)

    def test_partial_receipt_leaves_outstanding_expected_stock_open(self):
        StockItem.objects.create(variant=self.variant, quantity_on_hand=5)
        order = PurchaseOrder.objects.create(supplier=self.supplier)
        line = order.lines.create(
            variant=self.variant,
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

        stock_item = StockItem.objects.get(variant=self.variant)
        self.assertEqual(stock_item.quantity_on_hand, 9)
        self.assertEqual(stock_item.quantity_expected, 4)
        self.assertTrue(
            StockMovement.objects.filter(
                variant=self.variant,
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

    def test_receiving_expiry_tracked_stock_creates_batch(self):
        self.product.tracks_expiry = True
        self.product.save(update_fields=["tracks_expiry", "updated_at"])
        expiry_date = timezone.localdate() + timedelta(days=30)
        StockItem.objects.create(variant=self.variant, quantity_on_hand=0)
        order = PurchaseOrder.objects.create(supplier=self.supplier)
        line = order.lines.create(
            variant=self.variant,
            quantity=5,
            unit_cost=Decimal("1.25"),
            expiry_date=expiry_date,
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
                        "accepted_quantity": 4,
                    }
                ],
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        receipt_line = PurchaseReceipt.objects.get(
            purchase_order=order,
        ).lines.get()
        batch = StockBatch.objects.get(source_receipt_line=receipt_line)
        self.assertEqual(batch.variant, self.variant)
        self.assertEqual(batch.expiry_date, expiry_date)
        self.assertEqual(batch.received_quantity, 4)
        self.assertEqual(batch.remaining_quantity, 4)
        self.assertEqual(
            response.data["receipts"][0]["lines"][0]["expiry_date"],
            expiry_date.isoformat(),
        )

    def test_expiring_batches_are_consumed_by_earliest_expiry_first(self):
        self.product.tracks_expiry = True
        self.product.save(update_fields=["tracks_expiry", "updated_at"])
        StockItem.objects.create(variant=self.variant, quantity_on_hand=0)
        order = PurchaseOrder.objects.create(supplier=self.supplier)
        first_line = order.lines.create(
            variant=self.variant,
            quantity=3,
            unit_cost=Decimal("1.25"),
            expiry_date=timezone.localdate() + timedelta(days=10),
        )
        second_line = order.lines.create(
            variant=self.variant,
            quantity=5,
            unit_cost=Decimal("1.25"),
            expiry_date=timezone.localdate() + timedelta(days=30),
        )
        order.recalculate()
        order.save(update_fields=["subtotal", "total", "updated_at"])
        submit_purchase_order(order)
        receive_purchase_order(
            order,
            lines_data=[
                {"line": first_line, "accepted_quantity": 3},
                {"line": second_line, "accepted_quantity": 5},
            ],
        )
        batches = list(StockBatch.objects.order_by("expiry_date"))

        consumed = consume_expiring_stock_batches(variant=self.variant, quantity=4)

        self.assertEqual(consumed, 4)
        batches[0].refresh_from_db()
        batches[1].refresh_from_db()
        self.assertEqual(batches[0].remaining_quantity, 0)
        self.assertEqual(batches[1].remaining_quantity, 4)

    def test_receive_revalidates_stale_line_quantity_before_stocking(self):
        stock_item = StockItem.objects.create(variant=self.variant, quantity_on_hand=0)
        order = PurchaseOrder.objects.create(supplier=self.supplier)
        line = order.lines.create(
            variant=self.variant,
            quantity=4,
            unit_cost=Decimal("1.25"),
        )
        order.recalculate()
        order.save(update_fields=["subtotal", "total", "updated_at"])
        submit_purchase_order(order)
        stale_lines = [
            {
                "line": line,
                "accepted_quantity": 4,
                "damaged_quantity": 0,
                "cancelled_quantity": 0,
                "allowed_over_receipt_quantity": 0,
            }
        ]

        receive_purchase_order(
            order,
            lines_data=[
                {
                    "line": line,
                    "accepted_quantity": 2,
                    "damaged_quantity": 0,
                    "cancelled_quantity": 0,
                    "allowed_over_receipt_quantity": 0,
                }
            ],
        )

        with self.assertRaises(serializers.ValidationError):
            receive_purchase_order(order, lines_data=stale_lines)

        stock_item.refresh_from_db()
        self.assertEqual(stock_item.quantity_on_hand, 2)
        self.assertEqual(PurchaseReceipt.objects.count(), 1)

    def test_over_receipt_records_variance_and_stock_overage(self):
        StockItem.objects.create(variant=self.variant, quantity_on_hand=0)
        order = PurchaseOrder.objects.create(supplier=self.supplier)
        line = order.lines.create(
            variant=self.variant,
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

        stock_item = StockItem.objects.get(variant=self.variant)
        self.assertEqual(stock_item.quantity_on_hand, 5)
        self.assertEqual(stock_item.quantity_expected, 0)
        self.assertTrue(
            StockMovement.objects.filter(
                variant=self.variant,
                movement_type=StockMovement.Type.INCREASE,
                quantity=2,
            ).exists()
        )

    def test_receipt_can_cancel_remaining_expected_quantity(self):
        StockItem.objects.create(variant=self.variant, quantity_on_hand=0)
        order = PurchaseOrder.objects.create(supplier=self.supplier)
        line = order.lines.create(
            variant=self.variant,
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
        stock_item = StockItem.objects.get(variant=self.variant)
        self.assertEqual(stock_item.quantity_on_hand, 2)
        self.assertEqual(stock_item.quantity_expected, 0)
        self.assertTrue(
            StockMovement.objects.filter(
                variant=self.variant,
                movement_type=StockMovement.Type.CANCEL_EXPECTED,
                quantity=3,
            ).exists()
        )

    def test_receipt_accepts_frontend_quantity_aliases(self):
        StockItem.objects.create(variant=self.variant, quantity_on_hand=0)
        order = PurchaseOrder.objects.create(supplier=self.supplier)
        line = order.lines.create(
            variant=self.variant,
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
        stock_item = StockItem.objects.get(variant=self.variant)
        self.assertEqual(stock_item.quantity_on_hand, 2)
        self.assertEqual(stock_item.quantity_expected, 0)

    def test_return_received_purchase_items_decreases_stock_and_records_adjustment(self):
        order = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.RECEIVED,
        )
        line = order.lines.create(
            variant=self.variant,
            quantity=4,
            unit_cost=Decimal("1.25"),
        )
        StockItem.objects.create(variant=self.variant, quantity_on_hand=5)

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

        stock_item = StockItem.objects.get(variant=self.variant)
        self.assertEqual(stock_item.quantity_on_hand, 3)
        movement = StockMovement.objects.get(variant=self.variant)
        self.assertEqual(movement.movement_type, StockMovement.Type.DECREASE)
        self.assertEqual(movement.quantity, 2)
        self.assertEqual(movement.on_hand_before, 5)
        self.assertEqual(movement.on_hand_after, 3)
        self.assertEqual(movement.created_by, self.user)

    def test_purchase_return_uses_discounted_net_amount_for_supplier_credit(self):
        DiscountRule.objects.create(
            name="Quarter off",
            channel=DiscountRule.Channel.PURCHASING,
            value_type=DiscountRule.ValueType.PERCENTAGE,
            value=Decimal("25.00"),
        )
        StockItem.objects.create(variant=self.variant, quantity_on_hand=0)
        create_response = self.client.post(
            reverse("purchaseorder-list"),
            {
                "supplier": self.supplier.pk,
                "lines": [
                    {
                        "variant": self.variant.pk,
                        "quantity": 4,
                        "unit_cost": "10.00",
                    }
                ],
            },
            format="json",
        )
        order_id = create_response.data["id"]
        self.client.post(reverse("purchaseorder-submit", args=[order_id]), format="json")
        self.client.post(reverse("purchaseorder-receive", args=[order_id]), format="json")
        line = PurchaseOrder.objects.get(pk=order_id).lines.get()

        response = self.client.post(
            reverse("purchaseorder-return-items", args=[order_id]),
            {"lines": [{"line": line.pk, "quantity": 2}]},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        adjustment = response.data["adjustments"][0]
        self.assertEqual(adjustment["amount"], "15.00")
        self.assertEqual(adjustment["outbound_amount"], "15.00")
        self.assertEqual(adjustment["net_amount"], "-15.00")
        self.assertEqual(adjustment["lines"][0]["unit_cost"], "7.50")
        self.assertEqual(adjustment["lines"][0]["line_total"], "15.00")
        self.assertEqual(adjustment["supplier_credit"]["amount"], "15.00")

    def test_purchase_refund_and_exchange_use_discounted_net_amounts(self):
        DiscountRule.objects.create(
            name="Quarter off adjustments",
            channel=DiscountRule.Channel.PURCHASING,
            value_type=DiscountRule.ValueType.PERCENTAGE,
            value=Decimal("25.00"),
        )
        StockItem.objects.create(variant=self.variant, quantity_on_hand=0)
        refund_create_response = self.client.post(
            reverse("purchaseorder-list"),
            {
                "supplier": self.supplier.pk,
                "lines": [
                    {
                        "variant": self.variant.pk,
                        "quantity": 4,
                        "unit_cost": "10.00",
                    }
                ],
            },
            format="json",
        )
        refund_order_id = refund_create_response.data["id"]
        self.client.post(
            reverse("purchaseorder-submit", args=[refund_order_id]),
            format="json",
        )
        self.client.post(
            reverse("purchaseorder-receive", args=[refund_order_id]),
            format="json",
        )
        refund_line = PurchaseOrder.objects.get(pk=refund_order_id).lines.get()

        refund_response = self.client.post(
            reverse("purchaseorder-refund-items", args=[refund_order_id]),
            {"lines": [{"line": refund_line.pk, "quantity": 2}]},
            format="json",
        )

        exchange_create_response = self.client.post(
            reverse("purchaseorder-list"),
            {
                "supplier": self.supplier.pk,
                "lines": [
                    {
                        "variant": self.variant.pk,
                        "quantity": 4,
                        "unit_cost": "10.00",
                    }
                ],
            },
            format="json",
        )
        exchange_order_id = exchange_create_response.data["id"]
        self.client.post(
            reverse("purchaseorder-submit", args=[exchange_order_id]),
            format="json",
        )
        self.client.post(
            reverse("purchaseorder-receive", args=[exchange_order_id]),
            format="json",
        )
        exchange_line = PurchaseOrder.objects.get(pk=exchange_order_id).lines.get()

        exchange_response = self.client.post(
            reverse("purchaseorder-exchange-items", args=[exchange_order_id]),
            {"lines": [{"line": exchange_line.pk, "quantity": 2}]},
            format="json",
        )

        self.assertEqual(refund_response.status_code, status.HTTP_200_OK)
        refund_adjustment = refund_response.data["adjustments"][0]
        self.assertEqual(refund_adjustment["amount"], "15.00")
        self.assertEqual(refund_adjustment["settlement_method"], "refund")
        self.assertEqual(refund_adjustment["lines"][0]["unit_cost"], "7.50")
        self.assertEqual(SupplierPayment.objects.get().amount, Decimal("15.00"))
        self.assertEqual(SupplierPayment.objects.get().method, SupplierPayment.Method.REFUND)

        self.assertEqual(exchange_response.status_code, status.HTTP_200_OK)
        exchange_adjustment = exchange_response.data["adjustments"][0]
        self.assertEqual(exchange_adjustment["outbound_amount"], "15.00")
        self.assertEqual(exchange_adjustment["replacement_amount"], "15.00")
        self.assertEqual(exchange_adjustment["net_amount"], "0.00")
        self.assertEqual(exchange_adjustment["lines"][0]["unit_cost"], "7.50")
        self.assertEqual(
            exchange_adjustment["replacement_lines"][0]["unit_cost"],
            "7.50",
        )

    def test_refund_rejects_more_than_remaining_purchase_quantity(self):
        order = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.RECEIVED,
        )
        line = order.lines.create(
            variant=self.variant,
            quantity=2,
            unit_cost=Decimal("1.25"),
        )
        StockItem.objects.create(variant=self.variant, quantity_on_hand=5)
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
        self.assertEqual(StockItem.objects.get(variant=self.variant).quantity_on_hand, 4)

    def test_adjustment_revalidates_stale_line_quantity_before_stock_change(self):
        order = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.RECEIVED,
        )
        line = order.lines.create(
            variant=self.variant,
            quantity=2,
            unit_cost=Decimal("1.25"),
        )
        stock_item = StockItem.objects.create(variant=self.variant, quantity_on_hand=5)

        adjust_purchase_order_items(
            purchase_order=order,
            adjustment_type=PurchaseOrderAdjustment.AdjustmentType.RETURN,
            lines=[(line, 1)],
            reason="First adjustment",
        )

        with self.assertRaises(serializers.ValidationError):
            adjust_purchase_order_items(
                purchase_order=order,
                adjustment_type=PurchaseOrderAdjustment.AdjustmentType.RETURN,
                lines=[(line, 2)],
                reason="Stale adjustment",
            )

        stock_item.refresh_from_db()
        self.assertEqual(stock_item.quantity_on_hand, 4)
        self.assertEqual(PurchaseOrderAdjustment.objects.count(), 1)

    def test_exchange_rejects_when_stock_is_not_available(self):
        order = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.RECEIVED,
        )
        line = order.lines.create(
            variant=self.variant,
            quantity=3,
            unit_cost=Decimal("1.25"),
        )
        StockItem.objects.create(variant=self.variant, quantity_on_hand=1)

        response = self.client.post(
            reverse("purchaseorder-exchange-items", args=[order.pk]),
            {"lines": [{"line": line.pk, "quantity": 2}]},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["code"], "purchase_stock_already_sold")
        self.assertEqual(
            response.data["detail"],
            (
                "لا يمكن تعديل أمر الشراء لأن الكمية المستلمة بيعت أو لم تعد "
                "متوفرة في المخزون."
            ),
        )
        self.assertIn("stock", response.data)
        self.assertEqual(response.data["stock"][0]["requested"], "2")
        self.assertEqual(response.data["stock"][0]["available"], "1")
        self.assertEqual(StockItem.objects.get(variant=self.variant).quantity_on_hand, 1)

    def test_exchange_records_outbound_and_replacement_lines_with_new_cost(self):
        order = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.RECEIVED,
        )
        line = order.lines.create(
            variant=self.variant,
            quantity=4,
            unit_cost=Decimal("1.25"),
        )
        StockItem.objects.create(variant=self.variant, quantity_on_hand=5)
        StockItem.objects.create(variant=self.other_variant, quantity_on_hand=1)

        response = self.client.post(
            reverse("purchaseorder-exchange-items", args=[order.pk]),
            {
                "reason": "Wrong item",
                "lines": [{"line": line.pk, "quantity": 2}],
                "replacement_lines": [
                    {
                        "variant": self.other_variant.pk,
                        "quantity": 3,
                        "unit_cost": "2.00",
                    }
                ],
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        adjustment = response.data["adjustments"][0]
        self.assertEqual(
            adjustment["adjustment_type"],
            PurchaseOrderAdjustment.AdjustmentType.EXCHANGE,
        )
        self.assertEqual(adjustment["amount"], "2.50")
        self.assertEqual(adjustment["outbound_amount"], "2.50")
        self.assertEqual(adjustment["replacement_amount"], "6.00")
        self.assertEqual(adjustment["net_amount"], "3.50")
        self.assertEqual(adjustment["settlement_method"], "")
        self.assertIsNone(adjustment["supplier_credit"])
        self.assertEqual(adjustment["credits"], [])
        self.assertEqual(adjustment["lines"][0]["quantity"], 2)
        self.assertEqual(adjustment["lines"][0]["unit_cost"], "1.25")
        self.assertEqual(adjustment["replacement_lines"][0]["product"], self.other_product.pk)
        self.assertEqual(adjustment["replacement_lines"][0]["quantity"], 3)
        self.assertEqual(adjustment["replacement_lines"][0]["unit_cost"], "2.00")
        self.assertEqual(SupplierCredit.objects.count(), 0)
        self.assertEqual(SupplierPayment.objects.count(), 0)

        self.assertEqual(StockItem.objects.get(variant=self.variant).quantity_on_hand, 3)
        self.assertEqual(
            StockItem.objects.get(variant=self.other_variant).quantity_on_hand,
            4,
        )
        returned_movement = StockMovement.objects.get(
            variant=self.variant,
            movement_type=StockMovement.Type.DECREASE,
        )
        self.assertEqual(returned_movement.quantity, 2)
        self.assertEqual(returned_movement.on_hand_before, 5)
        self.assertEqual(returned_movement.on_hand_after, 3)
        self.assertEqual(returned_movement.created_by, self.user)
        replacement_movement = StockMovement.objects.get(
            variant=self.other_variant,
            movement_type=StockMovement.Type.INCREASE,
        )
        self.assertEqual(replacement_movement.quantity, 3)
        self.assertEqual(replacement_movement.on_hand_before, 1)
        self.assertEqual(replacement_movement.on_hand_after, 4)
        self.assertIn("استلام بديل مشتريات", replacement_movement.note)
        self.assertEqual(replacement_movement.created_by, self.user)

    def test_exchange_replacement_can_target_specific_variant(self):
        replacement_variant = ProductVariant.objects.create(
            product=self.other_product,
            name="Large",
            sku="PUR-TEA-L",
            unit_price=Decimal("3.50"),
        )
        order = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.RECEIVED,
        )
        line = order.lines.create(
            variant=self.variant,
            quantity=2,
            unit_cost=Decimal("1.25"),
        )
        StockItem.objects.create(variant=self.variant, quantity_on_hand=2)

        response = self.client.post(
            reverse("purchaseorder-exchange-items", args=[order.pk]),
            {
                "lines": [{"line": line.pk, "quantity": 1}],
                "replacement_lines": [
                    {
                        "variant": replacement_variant.pk,
                        "quantity": 1,
                        "unit_cost": "3.00",
                    }
                ],
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        replacement_line = response.data["adjustments"][0]["replacement_lines"][0]
        self.assertEqual(replacement_line["variant"], replacement_variant.pk)
        self.assertEqual(replacement_line["product"], self.other_product.pk)
        self.assertEqual(replacement_line["variant_name"], "Large")
        self.assertEqual(
            StockItem.objects.get(variant=replacement_variant).quantity_on_hand,
            1,
        )

    def test_exchange_replacement_lines_create_stock_item_when_missing(self):
        order = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.RECEIVED,
        )
        line = order.lines.create(
            variant=self.variant,
            quantity=2,
            unit_cost=Decimal("1.25"),
        )
        StockItem.objects.create(variant=self.variant, quantity_on_hand=2)

        response = self.client.post(
            reverse("purchaseorder-exchange-items", args=[order.pk]),
            {
                "lines": [{"line": line.pk, "quantity": 1}],
                "replacement_items": [
                    {
                        "variant": self.other_variant.pk,
                        "quantity": 2,
                        "unit_cost": "3.25",
                    }
                ],
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        replacement_stock = StockItem.objects.get(variant=self.other_variant)
        self.assertEqual(replacement_stock.quantity_on_hand, 2)
        self.assertEqual(
            response.data["adjustments"][0]["replacement_lines"][0]["unit_cost"],
            "3.25",
        )

    def test_exchange_rejects_empty_replacement_lines(self):
        order = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.RECEIVED,
        )
        line = order.lines.create(
            variant=self.variant,
            quantity=2,
            unit_cost=Decimal("1.25"),
        )
        StockItem.objects.create(variant=self.variant, quantity_on_hand=2)

        response = self.client.post(
            reverse("purchaseorder-exchange-items", args=[order.pk]),
            {
                "lines": [{"line": line.pk, "quantity": 1}],
                "replacement_lines": [],
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("replacement_lines", response.data)
        self.assertEqual(StockItem.objects.get(variant=self.variant).quantity_on_hand, 2)
        self.assertEqual(StockMovement.objects.count(), 0)

    def test_exchange_rejects_invalid_replacement_lines(self):
        order = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.RECEIVED,
        )
        line = order.lines.create(
            variant=self.variant,
            quantity=2,
            unit_cost=Decimal("1.25"),
        )
        StockItem.objects.create(variant=self.variant, quantity_on_hand=2)

        response = self.client.post(
            reverse("purchaseorder-exchange-items", args=[order.pk]),
            {
                "lines": [{"line": line.pk, "quantity": 1}],
                "replacement_lines": [
                    {
                        "quantity": 1,
                        "unit_cost": "-1.00",
                    }
                ],
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("replacement_lines", response.data)
        self.assertEqual(StockItem.objects.get(variant=self.variant).quantity_on_hand, 2)
        self.assertEqual(StockMovement.objects.count(), 0)

    def test_exchange_legacy_payload_replaces_same_items_without_net_stock_change(self):
        order = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.RECEIVED,
        )
        line = order.lines.create(
            variant=self.variant,
            quantity=3,
            unit_cost=Decimal("1.25"),
        )
        StockItem.objects.create(variant=self.variant, quantity_on_hand=5)

        response = self.client.post(
            reverse("purchaseorder-exchange-items", args=[order.pk]),
            {"lines": [{"line": line.pk, "quantity": 2}]},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        adjustment = response.data["adjustments"][0]
        self.assertEqual(adjustment["outbound_amount"], "2.50")
        self.assertEqual(adjustment["replacement_amount"], "2.50")
        self.assertEqual(adjustment["net_amount"], "0.00")
        self.assertEqual(adjustment["replacement_lines"][0]["product"], self.product.pk)
        self.assertEqual(adjustment["replacement_lines"][0]["quantity"], 2)
        self.assertEqual(adjustment["replacement_lines"][0]["unit_cost"], "1.25")
        self.assertEqual(StockItem.objects.get(variant=self.variant).quantity_on_hand, 5)
        self.assertEqual(
            StockMovement.objects.filter(variant=self.variant).count(),
            2,
        )

    def test_purchase_adjustments_are_limited_to_received_orders(self):
        order = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.SUBMITTED,
        )
        line = order.lines.create(
            variant=self.variant,
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
            variant=self.variant,
            quantity=2,
            unit_cost=Decimal("1.00"),
        )
        StockItem.objects.create(variant=self.variant, quantity_on_hand=1)

        response = self.client.post(
            reverse("purchaseorder-receive", args=[order.pk]),
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("detail", response.data)
        self.assertEqual(StockItem.objects.get(variant=self.variant).quantity_on_hand, 1)
        self.assertEqual(StockMovement.objects.count(), 0)

    def test_duplicate_products_are_rejected(self):
        response = self.client.post(
            reverse("purchaseorder-list"),
            {
                "supplier": self.supplier.pk,
                "lines": [
                    {
                        "variant": self.variant.pk,
                        "quantity": 1,
                        "unit_cost": "1.00",
                    },
                    {
                        "variant": self.variant.pk,
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
            variant=self.variant,
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
            variant=self.variant,
            quantity=1,
            unit_cost=Decimal("9.99"),
        )
        first = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.RECEIVED,
        )
        first.lines.create(
            variant=self.variant,
            quantity=1,
            unit_cost=Decimal("1.25"),
        )
        latest = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.SUBMITTED,
        )
        latest.lines.create(
            variant=self.variant,
            quantity=1,
            unit_cost=Decimal("2.75"),
        )

        response = self.client.get(
            reverse("purchaseorder-last-cost"),
            {"product": self.product.pk, "variant": self.variant.pk},
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["unit_cost"], Decimal("2.75"))

        alias_response = self.client.get(
            reverse("purchaseorder-variant-last-cost"),
            {"variant": self.variant.pk},
        )
        self.assertEqual(alias_response.status_code, status.HTTP_200_OK)
        self.assertEqual(alias_response.data["unit_cost"], Decimal("2.75"))

    def test_last_cost_requires_variant(self):
        response = self.client.get(
            reverse("purchaseorder-last-cost"),
            {"product": self.product.pk},
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("variant", response.data)

    def test_last_cost_can_target_a_specific_variant(self):
        variant = ProductVariant.objects.create(
            product=self.product,
            name="Large",
            sku="PUR-COFFEE-L",
            unit_price=Decimal("5.00"),
        )
        default_order = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.RECEIVED,
        )
        default_order.lines.create(
            variant=self.variant,
            quantity=1,
            unit_cost=Decimal("1.25"),
        )
        variant_order = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.RECEIVED,
        )
        variant_order.lines.create(
            variant=variant,
            quantity=1,
            unit_cost=Decimal("6.50"),
        )

        variant_response = self.client.get(
            reverse("purchaseorder-last-cost"),
            {"variant": variant.pk},
        )
        default_response = self.client.get(
            reverse("purchaseorder-last-cost"),
            {"product": self.product.pk, "variant": self.variant.pk},
        )

        self.assertEqual(variant_response.status_code, status.HTTP_200_OK)
        self.assertEqual(variant_response.data["product_id"], self.product.pk)
        self.assertEqual(variant_response.data["variant_id"], variant.pk)
        self.assertEqual(variant_response.data["unit_cost"], Decimal("6.50"))
        self.assertEqual(default_response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            default_response.data["variant_id"],
            self.product.default_variant.pk,
        )
        self.assertEqual(default_response.data["unit_cost"], Decimal("1.25"))

    def test_purchase_order_list_filters_by_product_and_variant_without_duplicates(
        self,
    ):
        variant = ProductVariant.objects.create(
            product=self.product,
            name="Large",
            sku="PUR-COFFEE-L",
            unit_price=Decimal("5.00"),
        )
        matching_order = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.RECEIVED,
        )
        matching_order.lines.create(
            variant=self.variant,
            quantity=1,
            unit_cost=Decimal("1.25"),
        )
        matching_order.lines.create(
            variant=variant,
            quantity=1,
            unit_cost=Decimal("2.75"),
        )
        other_order = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.RECEIVED,
        )
        other_order.lines.create(
            variant=self.other_variant,
            quantity=1,
            unit_cost=Decimal("3.00"),
        )

        product_response = self.client.get(
            reverse("purchaseorder-list"),
            {"product": self.product.pk},
        )
        variant_response = self.client.get(
            reverse("purchaseorder-list"),
            {"product": self.product.pk, "variant": variant.pk},
        )

        self.assertEqual(product_response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            [order["id"] for order in product_response.data["results"]],
            [matching_order.pk],
        )
        self.assertEqual(variant_response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            [order["id"] for order in variant_response.data["results"]],
            [matching_order.pk],
        )
        self.assertFalse(
            any(
                order["id"] == other_order.pk
                for order in product_response.data["results"]
            )
        )

    def test_receive_purchase_order_increases_exact_variant_stock(self):
        variant = ProductVariant.objects.create(
            product=self.product,
            name="Medium",
            sku="PUR-COFFEE-M",
            unit_price=Decimal("4.50"),
        )
        order = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.SUBMITTED,
        )
        line = order.lines.create(
            variant=variant,
            quantity=2,
            unit_cost=Decimal("2.10"),
        )
        StockItem.objects.create(variant=self.variant, quantity_on_hand=5)
        variant_stock = StockItem.objects.create(
            variant=variant,
            quantity_expected=2,
        )

        response = self.client.post(
            reverse("purchaseorder-receive", args=[order.pk]),
            {
                "lines": [
                    {
                        "line": line.pk,
                        "accepted_quantity": 2,
                    }
                ]
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        variant_stock.refresh_from_db()
        self.assertEqual(variant_stock.quantity_on_hand, 2)
        self.assertEqual(variant_stock.quantity_expected, 0)
        self.assertEqual(
            StockItem.objects.get(variant=self.product.default_variant).quantity_on_hand,
            5,
        )
        movement = StockMovement.objects.get(
            variant=variant,
            movement_type=StockMovement.Type.RECEIVE_EXPECTED,
        )
        self.assertEqual(movement.on_hand_after, 2)

    def test_product_cost_history_returns_purchase_lines_for_product(self):
        cancelled = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.CANCELLED,
        )
        cancelled.lines.create(
            variant=self.variant,
            quantity=1,
            unit_cost=Decimal("9.99"),
        )
        other_supplier = Supplier.objects.create(name="History supplier")
        first = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.RECEIVED,
        )
        first.lines.create(
            variant=self.variant,
            quantity=2,
            unit_cost=Decimal("1.25"),
        )
        latest = PurchaseOrder.objects.create(
            supplier=other_supplier,
            status=PurchaseOrder.Status.RECEIVED,
            submitted_at="2026-05-19T10:00:00Z",
            received_at="2026-05-20T10:00:00Z",
        )
        latest_line = latest.lines.create(
            variant=self.variant,
            quantity=3,
            unit_cost=Decimal("2.50"),
            landed_unit_cost=Decimal("0.25"),
            effective_unit_cost=Decimal("2.75"),
        )
        latest.lines.create(
            variant=self.other_variant,
            quantity=1,
            unit_cost=Decimal("3.00"),
        )

        response = self.client.get(
            reverse("purchaseorder-product-cost-history"),
            {"product": self.product.pk},
        )
        variant_response = self.client.get(
            reverse("purchaseorder-variant-cost-history"),
            {"variant": self.variant.pk},
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(variant_response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["count"], 2)
        self.assertEqual(variant_response.data["count"], 2)
        row = response.data["results"][0]
        self.assertEqual(row["id"], latest_line.pk)
        self.assertEqual(row["purchase_order"], latest.pk)
        self.assertEqual(row["order_number"], latest.order_number)
        self.assertEqual(row["supplier"], other_supplier.pk)
        self.assertEqual(row["supplier_name"], other_supplier.name)
        self.assertEqual(row["quantity"], 3)
        self.assertEqual(row["unit_cost"], "2.50")
        self.assertEqual(row["landed_unit_cost"], "0.25")
        self.assertEqual(row["effective_unit_cost"], "2.75")

    def test_product_margin_impact_compares_latest_and_previous_costs(self):
        previous = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.RECEIVED,
        )
        previous.lines.create(
            variant=self.variant,
            quantity=1,
            unit_cost=Decimal("1.00"),
        )
        latest = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.RECEIVED,
        )
        latest_line = latest.lines.create(
            variant=self.variant,
            quantity=1,
            unit_cost=Decimal("2.50"),
        )

        response = self.client.get(
            reverse("purchaseorder-product-margin-impact"),
            {"product": self.product.pk, "variant": self.variant.pk},
        )
        alias_response = self.client.get(
            reverse("purchaseorder-variant-margin-impact"),
            {"variant": self.variant.pk},
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(alias_response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["product"], self.product.pk)
        self.assertEqual(alias_response.data["variant"], self.variant.pk)
        self.assertEqual(response.data["product_name"], self.product.name)
        self.assertEqual(response.data["unit_price"], "4.00")
        self.assertEqual(response.data["latest_purchase_line"], latest_line.pk)
        self.assertEqual(response.data["latest_unit_cost"], "2.50")
        self.assertEqual(response.data["latest_effective_unit_cost"], "2.50")
        self.assertEqual(response.data["latest_margin_amount"], "1.50")
        self.assertEqual(response.data["latest_margin_percent"], "37.50")
        self.assertEqual(response.data["previous_unit_cost"], "1.00")
        self.assertEqual(response.data["previous_effective_unit_cost"], "1.00")
        self.assertEqual(response.data["previous_margin_amount"], "3.00")
        self.assertEqual(response.data["previous_margin_percent"], "75.00")
        self.assertEqual(response.data["unit_cost_delta"], "1.50")
        self.assertEqual(response.data["effective_unit_cost_delta"], "1.50")
        self.assertEqual(response.data["margin_amount_delta"], "-1.50")
        self.assertEqual(response.data["margin_percent_delta"], "-37.50")

    def test_product_margin_impact_requires_variant(self):
        response = self.client.get(
            reverse("purchaseorder-product-margin-impact"),
            {"product": self.product.pk},
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("variant", response.data)

    def test_outstanding_received_not_paid_returns_unpaid_received_orders(self):
        due_order = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.RECEIVED,
            due_date="2026-05-18",
            subtotal=Decimal("10.00"),
            total=Decimal("10.00"),
        )
        later_due_order = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.RECEIVED,
            due_date="2026-05-25",
            subtotal=Decimal("8.00"),
            total=Decimal("8.00"),
        )
        paid_order = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.RECEIVED,
            subtotal=Decimal("6.00"),
            total=Decimal("6.00"),
        )
        SupplierPayment.objects.create(
            supplier=self.supplier,
            purchase_order=paid_order,
            amount=Decimal("6.00"),
            method=SupplierPayment.Method.CASH,
        )
        PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.SUBMITTED,
            subtotal=Decimal("4.00"),
            total=Decimal("4.00"),
        )

        response = self.client.get(
            reverse("purchaseorder-outstanding-received-not-paid"),
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            [row["id"] for row in response.data["results"]],
            [due_order.pk, later_due_order.pk],
        )
        self.assertEqual(response.data["results"][0]["balance_due"], "10.00")
        self.assertEqual(response.data["results"][0]["payment_status"], "unpaid")

    def test_adjustment_history_filters_return_and_refund_rows(self):
        other_supplier = Supplier.objects.create(name="Adjustment supplier")
        order = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.RECEIVED,
        )
        line = order.lines.create(
            variant=self.variant,
            quantity=4,
            unit_cost=Decimal("1.25"),
        )
        refund_order = PurchaseOrder.objects.create(
            supplier=other_supplier,
            status=PurchaseOrder.Status.RECEIVED,
        )
        refund_line = refund_order.lines.create(
            variant=self.other_variant,
            quantity=2,
            unit_cost=Decimal("3.00"),
        )
        return_adjustment = PurchaseOrderAdjustment.objects.create(
            purchase_order=order,
            adjustment_type=PurchaseOrderAdjustment.AdjustmentType.RETURN,
            amount=Decimal("2.50"),
            outbound_amount=Decimal("2.50"),
            net_amount=Decimal("-2.50"),
            settlement_method=(
                PurchaseOrderAdjustment.SettlementMethod.SUPPLIER_CREDIT
            ),
            reason="Damaged",
        )
        PurchaseOrderAdjustmentLine.objects.create(
            adjustment=return_adjustment,
            purchase_line=line,
            variant=self.variant,
            quantity=2,
            unit_cost=Decimal("1.25"),
        )
        refund_adjustment = PurchaseOrderAdjustment.objects.create(
            purchase_order=refund_order,
            adjustment_type=PurchaseOrderAdjustment.AdjustmentType.REFUND,
            amount=Decimal("3.00"),
            outbound_amount=Decimal("3.00"),
            net_amount=Decimal("-3.00"),
            settlement_method=PurchaseOrderAdjustment.SettlementMethod.CASH,
            reason="Over supplied",
        )
        PurchaseOrderAdjustmentLine.objects.create(
            adjustment=refund_adjustment,
            purchase_line=refund_line,
            variant=self.other_variant,
            quantity=1,
            unit_cost=Decimal("3.00"),
        )

        response = self.client.get(
            reverse("purchaseorder-adjustment-history"),
            {
                "adjustment_type": PurchaseOrderAdjustment.AdjustmentType.RETURN,
                "supplier": self.supplier.pk,
                "product": self.product.pk,
            },
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["count"], 1)
        row = response.data["results"][0]
        self.assertEqual(row["adjustment"], return_adjustment.pk)
        self.assertEqual(row["adjustment_type"], "return")
        self.assertEqual(row["purchase_order"], order.pk)
        self.assertEqual(row["order_number"], order.order_number)
        self.assertEqual(row["supplier"], self.supplier.pk)
        self.assertEqual(row["supplier_name"], self.supplier.name)
        self.assertEqual(row["product"], self.product.pk)
        self.assertEqual(row["product_name"], self.product.name)
        self.assertEqual(row["quantity"], 2)
        self.assertEqual(row["unit_cost"], "1.25")
        self.assertEqual(row["line_total"], "2.50")


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

    def test_supplier_serialization_exposes_purchase_totals(self):
        supplier = Supplier.objects.create(name="Totals supplier")
        PurchaseOrder.objects.create(
            supplier=supplier,
            status=PurchaseOrder.Status.RECEIVED,
            subtotal=Decimal("10.00"),
            total=Decimal("10.00"),
        )
        PurchaseOrder.objects.create(
            supplier=supplier,
            status=PurchaseOrder.Status.SUBMITTED,
            subtotal=Decimal("5.00"),
            total=Decimal("5.00"),
        )
        PurchaseOrder.objects.create(
            supplier=supplier,
            status=PurchaseOrder.Status.CANCELLED,
            subtotal=Decimal("7.00"),
            total=Decimal("7.00"),
        )

        response = self.client.get(reverse("supplier-detail", args=[supplier.pk]))

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["total_bought"], "15.00")
        self.assertEqual(response.data["purchase_count"], 2)

    def test_supplier_purchase_history_returns_supplier_orders_newest_first(self):
        supplier = Supplier.objects.create(name="History supplier")
        older_order = PurchaseOrder.objects.create(
            supplier=supplier,
            status=PurchaseOrder.Status.RECEIVED,
            subtotal=Decimal("10.00"),
            total=Decimal("10.00"),
        )
        latest_order = PurchaseOrder.objects.create(
            supplier=supplier,
            status=PurchaseOrder.Status.SUBMITTED,
            subtotal=Decimal("5.00"),
            total=Decimal("5.00"),
        )
        PurchaseOrder.objects.create(
            supplier=Supplier.objects.create(name="Other supplier"),
            status=PurchaseOrder.Status.RECEIVED,
            subtotal=Decimal("7.00"),
            total=Decimal("7.00"),
        )

        response = self.client.get(
            reverse("supplier-purchase-history", args=[supplier.pk]),
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["count"], 2)
        self.assertEqual(
            [row["id"] for row in response.data["results"]],
            [latest_order.pk, older_order.pk],
        )


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
        self.product = create_product_with_default_variant(
            sku="PUR-PAY",
            barcode="",
            name="Payment product",
            unit_price=Decimal("4.00"),
        )
        self.variant = self.product.default_variant
        self.supplier = Supplier.objects.create(
            name="Payment supplier",
            contact_name="Mona",
            phone="+21891222333",
            email="payables@example.com",
            address="Tripoli",
        )

    def create_order(self, total=Decimal("7.50")):
        order = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.RECEIVED,
        )
        order.lines.create(
            variant=self.variant,
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
        self.assertEqual(detail.data["supplier_contact_name"], "Mona")
        self.assertEqual(detail.data["supplier_phone"], "+21891222333")
        self.assertEqual(detail.data["supplier_email"], "payables@example.com")
        self.assertEqual(detail.data["supplier_address"], "Tripoli")
        self.assertEqual(detail.data["paid_total"], "3.00")
        self.assertEqual(detail.data["balance_due"], "4.50")
        self.assertEqual(detail.data["payment_status"], "partial")

    def test_supplier_payment_replay_with_idempotency_key_returns_same_payment(self):
        order = self.create_order()
        payload = {
            "supplier": self.supplier.pk,
            "purchase_order": order.pk,
            "amount": "3.00",
            "method": SupplierPayment.Method.CASH,
            "reference": "PAY-IDEM",
        }

        first_response = self.client.post(
            reverse("supplierpayment-list"),
            payload,
            format="json",
            HTTP_IDEMPOTENCY_KEY="supplier-payment-retry-1",
        )
        second_response = self.client.post(
            reverse("supplierpayment-list"),
            payload,
            format="json",
            HTTP_IDEMPOTENCY_KEY="supplier-payment-retry-1",
        )

        self.assertEqual(first_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(second_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(first_response["Idempotency-Replayed"], "false")
        self.assertEqual(second_response["Idempotency-Replayed"], "true")
        self.assertEqual(first_response.data["id"], second_response.data["id"])
        self.assertEqual(SupplierPayment.objects.count(), 1)
        order.refresh_from_db()
        self.assertEqual(order.paid_total, Decimal("3.00"))

    def test_supplier_payment_rejects_key_reused_with_different_body(self):
        order = self.create_order()

        first_response = self.client.post(
            reverse("supplierpayment-list"),
            {
                "supplier": self.supplier.pk,
                "purchase_order": order.pk,
                "amount": "3.00",
                "method": SupplierPayment.Method.CASH,
            },
            format="json",
            HTTP_IDEMPOTENCY_KEY="supplier-payment-conflict",
        )
        conflict_response = self.client.post(
            reverse("supplierpayment-list"),
            {
                "supplier": self.supplier.pk,
                "purchase_order": order.pk,
                "amount": "2.00",
                "method": SupplierPayment.Method.CASH,
            },
            format="json",
            HTTP_IDEMPOTENCY_KEY="supplier-payment-conflict",
        )

        self.assertEqual(first_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(conflict_response.status_code, status.HTTP_409_CONFLICT)
        self.assertEqual(SupplierPayment.objects.count(), 1)

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
