from datetime import timedelta

from django.utils import timezone
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.models import BillOfMaterials, BomLine, Product, ProductVariant
from apps.catalog.testing import create_product_with_default_variant
from apps.core.models import ShopSettings
from apps.core.roles import (
    CASHIER_GROUP,
    MANAGER_GROUP,
    TECHNICIAN_GROUP,
    ensure_role_groups,
    pointy_domain_data_exists,
)
from apps.customers.models import Asset, AssetType, Customer
from apps.documents import trail
from apps.documents.models import DocumentEvent
from apps.documents.reconciliation import reconcile_lifecycles
from apps.documents.statuses import DocumentStatus
from apps.employees.models import Employee
from apps.inventory.models import StockItem
from apps.purchasing.models import PurchaseLine, PurchaseOrder, Supplier
from apps.purchasing.services import receive_purchase_order, submit_purchase_order
from apps.sales.models import Order, RegisterSession
from apps.sales.services import latest_sale_unit_cost
from .models import Job, WorkflowTemplate
from .services import LABOR_PRODUCT_SKU


def create_user_with_role(username, role):
    user = get_user_model().objects.create_user(username=username, password="pass")
    user.groups.add(Group.objects.get(name=role))
    return user


def authenticated_client(user):
    client = APIClient()
    client.force_authenticate(user=user)
    return client


def asset_type(slug="phone"):
    """A seeded asset type by slug — the shop-editable replacement for the old
    ``Asset.AssetType`` enum."""
    from apps.customers.models import AssetType

    return AssetType.objects.get(slug=slug)


def repair_template():
    return WorkflowTemplate.objects.get(job_type="repair", is_system=True)


def production_template():
    return WorkflowTemplate.objects.get(job_type="production", is_system=True)


def stage(template, code):
    return template.stages.get(code=code)


class OperationsTestCase(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.manager = create_user_with_role("ops-manager", MANAGER_GROUP)
        self.technician = create_user_with_role("ops-tech", TECHNICIAN_GROUP)
        self.cashier = create_user_with_role("ops-cashier", CASHIER_GROUP)
        self.customer = Customer.objects.create(full_name="أحمد علي", phone="0911")
        self.asset = Asset.objects.create(
            customer=self.customer,
            asset_type=asset_type("phone"),
            brand="Apple",
            model_name="iPhone 15 Pro",
            imei="356789",
        )
        self.part = create_product_with_default_variant(
            sku="SCREEN-15P",
            name="شاشة آيفون",
            unit_price=Decimal("120.00"),
        )
        self.part_variant = self.part.default_variant
        StockItem.objects.create(variant=self.part_variant, quantity_on_hand=10)

    def create_repair_job(self, client=None, **overrides):
        client = client or authenticated_client(self.technician)
        payload = {
            "workflow_template": repair_template().pk,
            "customer": self.customer.pk,
            "asset_ids": [self.asset.pk],
            "symptoms": "شاشة مكسورة",
            **overrides,
        }
        response = client.post(reverse("job-list"), payload, format="json")
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        return response.data


class WorkflowSeedTests(OperationsTestCase):
    def test_default_workflows_are_seeded(self):
        self.assertEqual(
            set(
                WorkflowTemplate.objects.filter(is_system=True).values_list(
                    "job_type", flat=True
                )
            ),
            {"repair", "production", "kitchen"},
        )
        template = repair_template()
        self.assertEqual(template.stages.filter(is_initial=True).count(), 1)
        self.assertTrue(template.stages.filter(is_terminal=True).exists())

    def test_seeded_workflows_do_not_block_initial_setup(self):
        get_user_model().objects.all().delete()
        Asset.objects.all().delete()
        Customer.objects.all().delete()
        StockItem.objects.all().delete()
        Product.objects.all().delete()
        self.assertFalse(pointy_domain_data_exists())


class JobLifecycleTests(OperationsTestCase):
    def test_create_job_sets_number_stage_and_channel(self):
        data = self.create_repair_job()

        job = Job.objects.get(pk=data["id"])
        self.assertTrue(job.job_number.startswith("REP-"))
        self.assertEqual(job.current_stage.code, "received")
        self.assertEqual(job.status, Job.Status.OPEN)
        self.assertEqual(job.sales_channel.slug, "pos")
        self.assertEqual(job.job_assets.first().asset_id, self.asset.pk)
        self.assertEqual(job.stage_events.count(), 1)
        self.assertIsNotNone(data["next_stage"])
        self.assertEqual(data["next_stage"]["code"], "diagnosing")

    def test_forward_transition_allowed_for_technician(self):
        client = authenticated_client(self.technician)
        data = self.create_repair_job(client=client)
        job = Job.objects.get(pk=data["id"])

        response = client.post(
            reverse("job-transition", args=[job.pk]),
            {"to_stage": stage(job.workflow_template, "diagnosing").pk},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        job.refresh_from_db()
        self.assertEqual(job.current_stage.code, "diagnosing")
        self.assertEqual(job.stage_events.count(), 2)

    def test_any_stage_is_reachable_by_whoever_can_change_the_job(self):
        # Skipping ahead and stepping back used to be a manager's correction.
        # A counter that has to click through every stage to record a phone
        # that is already fixed stops keeping the board current, so any stage
        # is a move — the gates it passes still hold (test_counter_workflow).
        client = authenticated_client(self.technician)
        data = self.create_repair_job(client=client)
        job = Job.objects.get(pk=data["id"])
        client.patch(
            reverse("job-detail", args=[job.pk]),
            {"approved_price": "100.00"},
            format="json",
        )

        skip = client.post(
            reverse("job-transition", args=[job.pk]),
            {"to_stage": stage(job.workflow_template, "repairing").pk},
            format="json",
        )
        self.assertEqual(skip.status_code, status.HTTP_200_OK, skip.data)

        backward = client.post(
            reverse("job-transition", args=[job.pk]),
            {"to_stage": stage(job.workflow_template, "received").pk},
            format="json",
        )
        self.assertEqual(backward.status_code, status.HTTP_200_OK, backward.data)

    def test_approval_gate_blocks_forward_until_price_approved(self):
        client = authenticated_client(self.manager)
        data = self.create_repair_job(client=client)
        job = Job.objects.get(pk=data["id"])
        template = job.workflow_template
        client.post(
            reverse("job-transition", args=[job.pk]),
            {"to_stage": stage(template, "waiting_approval").pk},
            format="json",
        )

        blocked = client.post(
            reverse("job-transition", args=[job.pk]),
            {"to_stage": stage(template, "repairing").pk},
            format="json",
        )
        self.assertEqual(blocked.status_code, status.HTTP_400_BAD_REQUEST)

        client.patch(
            reverse("job-detail", args=[job.pk]),
            {"approved_price": "150.00"},
            format="json",
        )
        allowed = client.post(
            reverse("job-transition", args=[job.pk]),
            {"to_stage": stage(template, "repairing").pk},
            format="json",
        )
        self.assertEqual(allowed.status_code, status.HTTP_200_OK, allowed.data)

    def test_terminal_stage_completes_and_locks_job(self):
        client = authenticated_client(self.manager)
        data = self.create_repair_job(client=client)
        job = Job.objects.get(pk=data["id"])
        # Jumping straight to the end passes the approval gate, which wants a
        # price; zero is a real one (a warranty repair), and leaves nothing to
        # settle at the handover.
        client.patch(
            reverse("job-detail", args=[job.pk]),
            {"approved_price": "0.00"},
            format="json",
        )
        response = client.post(
            reverse("job-transition", args=[job.pk]),
            {"to_stage": stage(job.workflow_template, "delivered").pk},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        job.refresh_from_db()
        self.assertEqual(job.status, Job.Status.COMPLETED)
        self.assertIsNotNone(job.completed_at)

        edit = client.patch(
            reverse("job-detail", args=[job.pk]),
            {"technician_notes": "x"},
            format="json",
        )
        self.assertEqual(edit.status_code, status.HTTP_400_BAD_REQUEST)


class JobMaterialTests(OperationsTestCase):
    def test_adding_material_consumes_stock(self):
        client = authenticated_client(self.technician)
        data = self.create_repair_job(client=client)

        response = client.post(
            reverse("job-add-material", args=[data["id"]]),
            {"variant": self.part_variant.pk, "quantity": 2},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        stock = StockItem.objects.get(variant=self.part_variant)
        self.assertEqual(stock.quantity_on_hand, 8)
        material = response.data["materials"][0]
        self.assertTrue(material["is_consumed"])
        self.assertEqual(material["unit_price"], "120.00")

    def test_insufficient_stock_is_rejected(self):
        client = authenticated_client(self.technician)
        data = self.create_repair_job(client=client)

        response = client.post(
            reverse("job-add-material", args=[data["id"]]),
            {"variant": self.part_variant.pk, "quantity": 99},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        stock = StockItem.objects.get(variant=self.part_variant)
        self.assertEqual(stock.quantity_on_hand, 10)

    def test_reversing_material_restores_stock(self):
        client = authenticated_client(self.technician)
        data = self.create_repair_job(client=client)
        client.post(
            reverse("job-add-material", args=[data["id"]]),
            {"variant": self.part_variant.pk, "quantity": 2},
            format="json",
        )
        job = Job.objects.get(pk=data["id"])
        material = job.materials.first()

        response = client.post(
            reverse("job-reverse-material", args=[job.pk, material.pk]),
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        stock = StockItem.objects.get(variant=self.part_variant)
        self.assertEqual(stock.quantity_on_hand, 10)

    def test_cancel_with_consumed_materials_requires_manager(self):
        client = authenticated_client(self.technician)
        data = self.create_repair_job(client=client)
        client.post(
            reverse("job-add-material", args=[data["id"]]),
            {"variant": self.part_variant.pk, "quantity": 3},
            format="json",
        )

        denied = client.post(reverse("job-cancel", args=[data["id"]]))
        self.assertEqual(denied.status_code, status.HTTP_400_BAD_REQUEST)

        manager_client = authenticated_client(self.manager)
        allowed = manager_client.post(reverse("job-cancel", args=[data["id"]]))
        self.assertEqual(allowed.status_code, status.HTTP_200_OK, allowed.data)
        stock = StockItem.objects.get(variant=self.part_variant)
        self.assertEqual(stock.quantity_on_hand, 10)
        job = Job.objects.get(pk=data["id"])
        self.assertEqual(job.status, Job.Status.CANCELLED)


class JobInvoiceTests(OperationsTestCase):
    def open_register(self, user):
        return RegisterSession.objects.create(
            owner=user,
            owner_key=f"user:{user.pk}",
            status=RegisterSession.Status.OPEN,
        )

    def test_invoice_creates_paid_order_without_double_stock_hit(self):
        client = authenticated_client(self.cashier)
        data = self.create_repair_job(client=client)
        # Parts are the technician's job; the cashier only collects payment.
        tech_client = authenticated_client(self.technician)
        material_response = tech_client.post(
            reverse("job-add-material", args=[data["id"]]),
            {"variant": self.part_variant.pk, "quantity": 1},
            format="json",
        )
        self.assertEqual(material_response.status_code, status.HTTP_200_OK)
        self.open_register(self.cashier)

        response = client.post(
            reverse("job-invoice", args=[data["id"]]),
            {
                "labor_total": "30.00",
                "payments": [{"method": "cash", "amount": "150.00"}],
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        job = Job.objects.get(pk=data["id"])
        self.assertIsNotNone(job.order)
        self.assertEqual(job.order.status, Order.Status.PAID)
        self.assertEqual(job.order.total, Decimal("150.00"))
        self.assertEqual(job.order.sales_channel.slug, "pos")
        # Paying does NOT finish a repair: the shop is still holding the
        # customer's phone. The job stays open on its stage until someone hands
        # it back, which is a separate, recorded act.
        self.assertEqual(job.status, Job.Status.OPEN)
        self.assertFalse(job.current_stage.is_terminal)
        self.assertIsNone(job.completed_at)
        self.assertEqual(job.settlement_state, "settled")
        self.assertEqual(job.custody_state, "with_shop")
        # Stock moved once, when the technician used the part.
        stock = StockItem.objects.get(variant=self.part_variant)
        self.assertEqual(stock.quantity_on_hand, 9)
        labor_line = job.order.lines.get(variant__sku=LABOR_PRODUCT_SKU)
        self.assertEqual(labor_line.unit_price, Decimal("30.00"))
        self.assertTrue(labor_line.variant.product.is_service)

    def test_invoice_consumes_pending_materials_and_bills_them(self):
        # The app adds materials "pending" (consume_now=False) by default, so
        # invoicing must finalize them: move their stock and bill them, with the
        # cashier's payment total matching the materials total they were shown.
        client = authenticated_client(self.cashier)
        data = self.create_repair_job(client=client)
        tech_client = authenticated_client(self.technician)
        material_response = tech_client.post(
            reverse("job-add-material", args=[data["id"]]),
            {"variant": self.part_variant.pk, "quantity": 1, "consume_now": False},
            format="json",
        )
        self.assertEqual(material_response.status_code, status.HTTP_200_OK)
        # Pending: stock has not moved yet.
        self.assertEqual(
            StockItem.objects.get(variant=self.part_variant).quantity_on_hand, 10
        )
        self.open_register(self.cashier)

        response = client.post(
            reverse("job-invoice", args=[data["id"]]),
            {
                "labor_total": "30.00",
                "payments": [{"method": "cash", "amount": "150.00"}],
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        job = Job.objects.get(pk=data["id"])
        self.assertEqual(job.order.total, Decimal("150.00"))
        self.assertEqual(job.status, Job.Status.OPEN)
        self.assertEqual(job.settlement_state, "settled")
        self.assertTrue(job.materials.get().is_consumed)
        # Stock moved exactly once, at invoice time.
        self.assertEqual(
            StockItem.objects.get(variant=self.part_variant).quantity_on_hand, 9
        )

    def test_invoice_skips_reversed_pending_material(self):
        client = authenticated_client(self.cashier)
        data = self.create_repair_job(client=client)
        tech_client = authenticated_client(self.technician)
        material_response = tech_client.post(
            reverse("job-add-material", args=[data["id"]]),
            {"variant": self.part_variant.pk, "quantity": 1, "consume_now": False},
            format="json",
        )
        material_id = material_response.data["materials"][0]["id"]
        reversal = tech_client.post(
            reverse("job-reverse-material", args=[data["id"], material_id]),
            format="json",
        )
        self.assertEqual(reversal.status_code, status.HTTP_200_OK, reversal.data)
        self.open_register(self.cashier)

        response = client.post(
            reverse("job-invoice", args=[data["id"]]),
            {
                "labor_total": "30.00",
                "payments": [{"method": "cash", "amount": "30.00"}],
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        job = Job.objects.get(pk=data["id"])
        self.assertEqual(job.order.total, Decimal("30.00"))
        # A reversed pending material must never move stock.
        self.assertEqual(
            StockItem.objects.get(variant=self.part_variant).quantity_on_hand, 10
        )

    def test_invoice_requires_matching_payment_total(self):
        client = authenticated_client(self.cashier)
        data = self.create_repair_job(client=client)
        self.open_register(self.cashier)

        response = client.post(
            reverse("job-invoice", args=[data["id"]]),
            {
                "labor_total": "30.00",
                "payments": [{"method": "cash", "amount": "10.00"}],
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_credit_job_invoice_respects_the_customer_credit_limit(self):
        """A repair settled on آجل is credit issued by another door, and a
        ceiling one door ignores is not a ceiling."""
        ShopSettings.load()
        ShopSettings.objects.filter(pk=1).update(
            enforce_customer_credit_limits=True,
            default_customer_credit_limit=Decimal("10.00"),
        )
        client = authenticated_client(self.cashier)
        data = self.create_repair_job(client=client)
        self.open_register(self.cashier)

        response = client.post(
            reverse("job-invoice", args=[data["id"]]),
            {"labor_total": "30.00", "sale_type": "credit", "payments": []},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["code"], "credit_limit_exceeded")

    def test_a_down_payment_can_bring_a_credit_job_under_the_limit(self):
        ShopSettings.load()
        ShopSettings.objects.filter(pk=1).update(
            enforce_customer_credit_limits=True,
            default_customer_credit_limit=Decimal("10.00"),
        )
        client = authenticated_client(self.cashier)
        data = self.create_repair_job(client=client)
        self.open_register(self.cashier)

        response = client.post(
            reverse("job-invoice", args=[data["id"]]),
            {
                "labor_total": "30.00",
                "sale_type": "credit",
                "payments": [{"method": "cash", "amount": "25.00"}],
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(response.data["order_balance_due"], "5.00")

    def test_invoice_requires_open_register_session(self):
        client = authenticated_client(self.cashier)
        data = self.create_repair_job(client=client)

        response = client.post(
            reverse("job-invoice", args=[data["id"]]),
            {
                "labor_total": "30.00",
                "payments": [{"method": "cash", "amount": "30.00"}],
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_technician_cannot_invoice(self):
        tech_client = authenticated_client(self.technician)
        data = self.create_repair_job(client=tech_client)

        response = tech_client.post(
            reverse("job-invoice", args=[data["id"]]),
            {
                "labor_total": "30.00",
                "payments": [{"method": "cash", "amount": "30.00"}],
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)


class ProductionTests(OperationsTestCase):
    def setUp(self):
        super().setUp()
        self.flour = create_product_with_default_variant(
            sku="FLOUR",
            name="دقيق",
            unit_price=Decimal("2.00"),
        )
        StockItem.objects.create(
            variant=self.flour.default_variant,
            quantity_on_hand=100,
        )
        self.bread = create_product_with_default_variant(
            sku="BREAD",
            name="خبز",
            unit_price=Decimal("1.00"),
        )
        self.bom = BillOfMaterials.objects.create(
            variant=self.bread.default_variant,
            name="وصفة الخبز",
            output_quantity=10,
        )
        BomLine.objects.create(
            bom=self.bom,
            component_variant=self.flour.default_variant,
            quantity=5,
            waste_percent=Decimal("0.00"),
        )

    def test_production_job_consumes_recipe_and_receives_output(self):
        client = authenticated_client(self.manager)
        response = client.post(
            reverse("job-list"),
            {
                "workflow_template": production_template().pk,
                "bom": self.bom.pk,
                "batches": 2,
            },
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        job = Job.objects.get(pk=response.data["id"])
        self.assertEqual(job.output_quantity, 20)
        # Materials are pending until the consuming stage.
        self.assertEqual(StockItem.objects.get(variant=self.flour.default_variant).quantity_on_hand, 100)

        template = job.workflow_template
        client.post(
            reverse("job-transition", args=[job.pk]),
            {"to_stage": stage(template, "in_production").pk},
            format="json",
        )
        self.assertEqual(
            StockItem.objects.get(variant=self.flour.default_variant).quantity_on_hand,
            90,
        )

        client.post(
            reverse("job-transition", args=[job.pk]),
            {"to_stage": stage(template, "quality_check").pk},
            format="json",
        )
        finished = client.post(
            reverse("job-transition", args=[job.pk]),
            {"to_stage": stage(template, "finished").pk},
            format="json",
        )
        self.assertEqual(finished.status_code, status.HTTP_200_OK, finished.data)

        job.refresh_from_db()
        self.assertEqual(job.status, Job.Status.COMPLETED)
        self.assertEqual(
            StockItem.objects.get(variant=self.bread.default_variant).quantity_on_hand,
            20,
        )
        self.assertIsNotNone(job.output_received_at)
        # 10 flour at 0 purchase cost — cost comes from purchasing history,
        # which is empty here, so unit cost is 0; the field is still stamped.
        self.assertIsNotNone(job.output_unit_cost)

    def test_produced_goods_cost_feeds_margin_costing(self):
        job = Job.objects.create(
            workflow_template=production_template(),
            job_type="production",
            current_stage=production_template().initial_stage(),
            output_variant=self.bread.default_variant,
            output_quantity=10,
            output_unit_cost=Decimal("0.45"),
        )
        Job.objects.filter(pk=job.pk).update(
            output_received_at=job.created_at,
        )

        self.assertEqual(
            latest_sale_unit_cost(self.bread.default_variant),
            Decimal("0.45"),
        )


class WorkflowTemplateApiTests(OperationsTestCase):
    def test_manager_can_edit_stages_and_sync_order(self):
        client = authenticated_client(self.manager)
        template = repair_template()
        detail = client.get(reverse("workflow-template-detail", args=[template.pk]))
        stages = detail.data["stages"]
        stages[1]["name"] = "فحص أولي"

        response = client.put(
            reverse("workflow-template-detail", args=[template.pk]),
            {
                "name": detail.data["name"],
                "job_type": detail.data["job_type"],
                "is_active": True,
                "stages": stages,
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        template.refresh_from_db()
        self.assertEqual(template.stages.all()[1].name, "فحص أولي")

    def test_stage_validation_requires_one_initial_and_a_terminal(self):
        client = authenticated_client(self.manager)
        response = client.post(
            reverse("workflow-template-list"),
            {
                "name": "بدون نهاية",
                "job_type": "repair",
                "is_active": True,
                "stages": [
                    {"code": "a", "name": "أ", "is_initial": True},
                    {"code": "b", "name": "ب"},
                ],
            },
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_system_template_cannot_be_deleted(self):
        client = authenticated_client(self.manager)
        response = client.delete(
            reverse("workflow-template-detail", args=[repair_template().pk])
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_stage_with_jobs_cannot_be_removed(self):
        client = authenticated_client(self.manager)
        self.create_repair_job(client=authenticated_client(self.technician))
        template = repair_template()
        detail = client.get(reverse("workflow-template-detail", args=[template.pk]))
        stages = [s for s in detail.data["stages"] if s["code"] != "received"]
        stages[0]["is_initial"] = True

        response = client.put(
            reverse("workflow-template-detail", args=[template.pk]),
            {
                "name": detail.data["name"],
                "job_type": detail.data["job_type"],
                "is_active": True,
                "stages": stages,
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)


class AssetApiTests(OperationsTestCase):
    def test_asset_crud_and_history_count(self):
        client = authenticated_client(self.technician)
        self.create_repair_job(client=client)

        response = client.get(
            reverse("asset-list"),
            {"customer": self.customer.pk},
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        asset = response.data["results"][0]
        self.assertEqual(asset["job_count"], 1)
        self.assertEqual(asset["display_name"], "Apple iPhone 15 Pro")

    def test_asset_with_history_cannot_be_deleted(self):
        manager_client = authenticated_client(self.manager)
        self.create_repair_job()
        response = manager_client.delete(reverse("asset-detail", args=[self.asset.pk]))
        self.assertEqual(response.status_code, status.HTTP_409_CONFLICT)


class PublicJobTrackingTests(OperationsTestCase):
    def test_public_tracking_hidden_without_relay(self):
        data = self.create_repair_job()
        job = Job.objects.get(pk=data["id"])

        response = APIClient().get(
            reverse("public-job-detail", args=[job.public_token])
        )

        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)


class _KitchenPosSetup(OperationsTestCase):
    """Shared POS→kitchen fixture: a prepared 'burger' with a meat recipe."""

    def setUp(self):
        super().setUp()
        ShopSettings.load()
        ShopSettings.objects.update(enable_kitchen_operations=True)
        self.meat = create_product_with_default_variant(
            sku="MEAT",
            name="لحم مفروم",
            unit_price=Decimal("30.00"),
        )
        self.meat.unit = Product.Unit.KILOGRAM
        self.meat.save(update_fields=["unit"])
        StockItem.objects.create(
            variant=self.meat.default_variant,
            quantity_on_hand=Decimal("5.000"),
        )
        self.burger = create_product_with_default_variant(
            sku="BURGER",
            name="برجر",
            unit_price=Decimal("12.00"),
        )
        self.burger.is_prepared = True
        self.burger.save(update_fields=["is_prepared"])
        self.bom = BillOfMaterials.objects.create(
            variant=self.burger.default_variant,
            name="وصفة البرجر",
            output_quantity=1,
        )
        BomLine.objects.create(
            bom=self.bom,
            component_variant=self.meat.default_variant,
            quantity=Decimal("0.150"),
        )

    def checkout_burgers(self, count):
        client = authenticated_client(self.cashier)
        RegisterSession.objects.create(
            owner=self.cashier,
            owner_key=f"user:{self.cashier.pk}",
            status=RegisterSession.Status.OPEN,
        )
        response = client.post(
            reverse("order-checkout"),
            {
                "lines": [
                    {"variant": self.burger.default_variant.pk, "quantity": count}
                ],
                "payment_method": "cash",
                "amount_received": str(Decimal("12.00") * count),
            },
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        return response.data


class KitchenFromPosTests(_KitchenPosSetup):
    """The staged lane (foundation for a future KDS): ingredients wait."""

    def setUp(self):
        super().setUp()
        ShopSettings.objects.update(kitchen_auto_complete=False)

    def test_paid_order_opens_kitchen_job_with_weighted_ingredients(self):
        data = self.checkout_burgers(2)

        job = Job.objects.get(order_id=data["id"])
        self.assertEqual(job.job_type, "kitchen")
        self.assertEqual(job.current_stage.code, "received")
        self.assertIn("برجر", job.symptoms)
        material = job.materials.get()
        self.assertEqual(material.quantity, Decimal("0.300"))
        self.assertIsNone(material.consumed_at)
        # The dish itself never had stock, and ingredients wait for the kitchen.
        self.assertFalse(
            StockItem.objects.filter(
                variant=self.burger.default_variant
            ).exists()
        )
        self.assertEqual(
            StockItem.objects.get(variant=self.meat.default_variant).quantity_on_hand,
            Decimal("5.000"),
        )

    def test_preparing_stage_consumes_weighted_ingredients(self):
        data = self.checkout_burgers(2)
        job = Job.objects.get(order_id=data["id"])
        kitchen = job.workflow_template

        client = authenticated_client(self.manager)
        response = client.post(
            reverse("job-transition", args=[job.pk]),
            {"to_stage": stage(kitchen, "preparing").pk},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(
            StockItem.objects.get(variant=self.meat.default_variant).quantity_on_hand,
            Decimal("4.700"),
        )

    def test_kitchen_job_skipped_when_mode_disabled(self):
        ShopSettings.objects.update(enable_kitchen_operations=False)
        data = self.checkout_burgers(1)
        self.assertFalse(Job.objects.filter(order_id=data["id"]).exists())


    def test_full_counter_loop_moves_ingredients_exactly_once(self):
        """The café flow the customer described: order, pay, wait, collect.

        The staged lane is what a counter with a pickup point actually needs —
        the customer paid at the till and is standing there waiting for a name
        to be called — and the one thing that must hold across all four steps is
        that the meat leaves stock once, at "preparing", and never again.
        """
        data = self.checkout_burgers(2)
        job = Job.objects.get(order_id=data["id"])
        kitchen = job.workflow_template
        client = authenticated_client(self.manager)

        stock = lambda: StockItem.objects.get(  # noqa: E731
            variant=self.meat.default_variant
        ).quantity_on_hand

        # Paid, but nothing has been cooked yet.
        self.assertEqual(job.current_stage.code, "received")
        self.assertEqual(stock(), Decimal("5.000"))

        for code, expected_stock in (
            ("preparing", Decimal("4.700")),
            ("ready", Decimal("4.700")),
            ("served", Decimal("4.700")),
        ):
            response = client.post(
                reverse("job-transition", args=[job.pk]),
                {"to_stage": stage(kitchen, code).pk},
                format="json",
            )
            self.assertEqual(
                response.status_code, status.HTTP_200_OK, f"{code}: {response.data}"
            )
            self.assertEqual(stock(), expected_stock, f"stock after {code}")

        job.refresh_from_db()
        self.assertEqual(job.status, Job.Status.COMPLETED)
        self.assertEqual(job.materials.get().consumed_at is None, False)

    def test_kitchen_handover_is_not_gated_on_payment(self):
        """A served plate is not custody, and the sale was already paid.

        The settlement gate exists for repairs, where the shop is holding
        someone's phone. Applying it to a kitchen order would wedge every café:
        the job is born already linked to a paid order, and there is nothing to
        hand back.
        """
        data = self.checkout_burgers(1)
        job = Job.objects.get(order_id=data["id"])
        served = stage(job.workflow_template, "served")

        self.assertFalse(served.requires_settlement)
        self.assertFalse(served.releases_custody)


class KitchenChitOnlyTests(_KitchenPosSetup):
    """The default lane: the job auto-completes and consumes at checkout."""

    def test_paid_order_auto_completes_job_and_consumes_ingredients(self):
        data = self.checkout_burgers(2)

        job = Job.objects.get(order_id=data["id"])
        self.assertEqual(job.status, Job.Status.COMPLETED)
        self.assertTrue(job.current_stage.is_terminal)
        self.assertIsNotNone(job.completed_at)
        material = job.materials.get()
        self.assertEqual(material.quantity, Decimal("0.300"))
        self.assertIsNotNone(material.consumed_at)
        # Ingredients leave stock at the sale: 5.000 - 0.300.
        self.assertEqual(
            StockItem.objects.get(variant=self.meat.default_variant).quantity_on_hand,
            Decimal("4.700"),
        )
        # Born linked to the paid POS order, so it is never invoiced separately.
        self.assertEqual(job.order_id, data["id"])

    def test_auto_completed_job_records_stage_event_to_terminal(self):
        data = self.checkout_burgers(1)
        job = Job.objects.get(order_id=data["id"])
        terminal_event = job.stage_events.order_by("-id").first()
        self.assertTrue(terminal_event.to_stage.is_terminal)


class WeightedCheckoutTests(OperationsTestCase):
    def setUp(self):
        super().setUp()
        self.meat = create_product_with_default_variant(
            sku="MEAT-KG",
            name="لحم بقري",
            unit_price=Decimal("8.00"),
        )
        self.meat.unit = Product.Unit.KILOGRAM
        self.meat.save(update_fields=["unit"])
        StockItem.objects.create(
            variant=self.meat.default_variant,
            quantity_on_hand=Decimal("10.000"),
        )
        self.client_api = authenticated_client(self.cashier)
        RegisterSession.objects.create(
            owner=self.cashier,
            owner_key=f"user:{self.cashier.pk}",
            status=RegisterSession.Status.OPEN,
        )

    def test_checkout_sells_fractional_weight_and_decrements_stock(self):
        response = self.client_api.post(
            reverse("order-checkout"),
            {
                "lines": [
                    {"variant": self.meat.default_variant.pk, "quantity": "1.250"}
                ],
                "payment_method": "cash",
                "amount_received": "10.00",
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        self.assertEqual(response.data["total"], "10.00")
        line = response.data["lines"][0]
        self.assertEqual(float(line["quantity"]), 1.25)
        self.assertEqual(line["unit"], "kg")
        self.assertEqual(
            StockItem.objects.get(variant=self.meat.default_variant).quantity_on_hand,
            Decimal("8.750"),
        )

    def test_piece_products_accept_fractional_quantities(self):
        # Piece (non-weighted) products sell in fractions too — ringing up 0.5
        # of anything is the cashier's choice since 0b970001.
        response = self.client_api.post(
            reverse("order-checkout"),
            {
                "lines": [{"variant": self.part_variant.pk, "quantity": "0.5"}],
                "payment_method": "cash",
                "amount_received": "60.00",
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        self.assertEqual(response.data["total"], "60.00")
        self.assertEqual(float(response.data["lines"][0]["quantity"]), 0.5)
        self.assertEqual(
            StockItem.objects.get(variant=self.part_variant).quantity_on_hand,
            Decimal("9.500"),
        )

    def test_partial_weight_return_restores_stock(self):
        checkout = self.client_api.post(
            reverse("order-checkout"),
            {
                "lines": [
                    {"variant": self.meat.default_variant.pk, "quantity": "2.000"}
                ],
                "payment_method": "cash",
                "amount_received": "16.00",
            },
            format="json",
        )
        order_id = checkout.data["id"]
        line_id = checkout.data["lines"][0]["id"]

        response = self.client_api.post(
            reverse("order-return-items", args=[order_id]),
            {
                "reason": "وزن زائد",
                "lines": [{"line": line_id, "quantity": "0.500"}],
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(
            StockItem.objects.get(variant=self.meat.default_variant).quantity_on_hand,
            Decimal("8.500"),
        )
        self.assertEqual(float(response.data["lines"][0]["returned_quantity"]), 0.5)


class ServiceProductTests(OperationsTestCase):
    def test_service_products_skip_stock_checks_at_checkout(self):
        service = Product.objects.create(name="رسوم توصيل", is_service=True)
        variant = ProductVariant.objects.create(
            product=service,
            name="",
            sku="SVC-DLV",
            unit_price=Decimal("5.00"),
            is_default=True,
        )
        cashier_client = authenticated_client(self.cashier)
        RegisterSession.objects.create(
            owner=self.cashier,
            owner_key=f"user:{self.cashier.pk}",
            status=RegisterSession.Status.OPEN,
        )

        response = cashier_client.post(
            reverse("order-checkout"),
            {
                "lines": [{"variant": variant.pk, "quantity": 1}],
                "payment_method": "cash",
                "amount_received": "5.00",
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        self.assertFalse(StockItem.objects.filter(variant=variant).exists())


class RecipeMadeToOrderApiTests(OperationsTestCase):
    """Creating a recipe should default its output to made-to-order so the POS
    sells it without needing its own stock (the kitchen job consumes the recipe).
    """

    def setUp(self):
        super().setUp()
        self.dish = create_product_with_default_variant(
            sku="DISH-1",
            name="طبق اليوم",
            unit_price=Decimal("15.00"),
        )
        self.ingredient = create_product_with_default_variant(
            sku="ING-1",
            name="مكوّن",
            unit_price=Decimal("2.00"),
        )

    def _recipe_payload(self, **overrides):
        payload = {
            "name": "وصفة طبق اليوم",
            "variant": self.dish.default_variant.pk,
            "output_quantity": 1,
            "lines": [
                {
                    "component_variant": self.ingredient.default_variant.pk,
                    "quantity": "1.000",
                }
            ],
        }
        payload.update(overrides)
        return payload

    def test_creating_recipe_marks_output_made_to_order_by_default(self):
        client = authenticated_client(self.manager)
        response = client.post(
            reverse("bom-list"), self._recipe_payload(), format="json"
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        self.assertTrue(response.data["is_prepared"])
        self.dish.refresh_from_db()
        self.assertTrue(self.dish.is_prepared)

    def test_produce_to_stock_recipe_keeps_output_stocked(self):
        client = authenticated_client(self.manager)
        response = client.post(
            reverse("bom-list"),
            self._recipe_payload(make_to_order=False),
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        self.assertFalse(response.data["is_prepared"])
        self.dish.refresh_from_db()
        self.assertFalse(self.dish.is_prepared)

    def test_editing_recipe_without_flag_keeps_existing_choice(self):
        # Produce-to-stock recipe; a later edit that omits the flag must not
        # silently flip the product back to made-to-order.
        client = authenticated_client(self.manager)
        created = client.post(
            reverse("bom-list"),
            self._recipe_payload(make_to_order=False),
            format="json",
        )
        bom_id = created.data["id"]
        response = client.patch(
            reverse("bom-detail", args=[bom_id]),
            {"name": "اسم محدّث"},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.dish.refresh_from_db()
        self.assertFalse(self.dish.is_prepared)


class AssignJobTests(OperationsTestCase):
    def setUp(self):
        super().setUp()
        # An employee who also has a system login, and one who does not.
        self.linked_employee = Employee.objects.create(
            full_name="فني الإصلاح",
            user=self.technician,
        )
        self.unlinked_employee = Employee.objects.create(full_name="فني بدون حساب")

    def _new_job(self):
        return Job.objects.get(pk=self.create_repair_job()["id"])

    def test_manager_assigns_employee_and_syncs_user(self):
        job = self._new_job()
        response = authenticated_client(self.manager).post(
            reverse("job-assign", args=[job.pk]),
            {"employee_id": self.linked_employee.pk},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(response.data["assigned_employee"], self.linked_employee.pk)
        self.assertEqual(response.data["assigned_employee_name"], "فني الإصلاح")
        job.refresh_from_db()
        self.assertEqual(job.assigned_employee_id, self.linked_employee.pk)
        # The login is stamped so the "assigned to me" board keeps working.
        self.assertEqual(job.assigned_to_id, self.technician.pk)

    def test_assigning_unlinked_employee_clears_user(self):
        job = self._new_job()
        client = authenticated_client(self.manager)
        client.post(
            reverse("job-assign", args=[job.pk]),
            {"employee_id": self.linked_employee.pk},
            format="json",
        )
        client.post(
            reverse("job-assign", args=[job.pk]),
            {"employee_id": self.unlinked_employee.pk},
            format="json",
        )
        job.refresh_from_db()
        self.assertEqual(job.assigned_employee_id, self.unlinked_employee.pk)
        self.assertIsNone(job.assigned_to_id)

    def test_assign_null_unassigns(self):
        job = self._new_job()
        client = authenticated_client(self.manager)
        client.post(
            reverse("job-assign", args=[job.pk]),
            {"employee_id": self.linked_employee.pk},
            format="json",
        )
        client.post(
            reverse("job-assign", args=[job.pk]),
            {"employee_id": None},
            format="json",
        )
        job.refresh_from_db()
        self.assertIsNone(job.assigned_employee_id)
        self.assertIsNone(job.assigned_to_id)

    def test_technician_cannot_assign(self):
        job = self._new_job()
        response = authenticated_client(self.technician).post(
            reverse("job-assign", args=[job.pk]),
            {"employee_id": self.linked_employee.pk},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_cannot_assign_cancelled_job(self):
        job = self._new_job()
        client = authenticated_client(self.manager)
        client.post(reverse("job-cancel", args=[job.pk]), {}, format="json")
        response = client.post(
            reverse("job-assign", args=[job.pk]),
            {"employee_id": self.linked_employee.pk},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_create_job_assigned_to_employee(self):
        response = authenticated_client(self.manager).post(
            reverse("job-list"),
            {
                "workflow_template": repair_template().pk,
                "customer": self.customer.pk,
                "asset_ids": [self.asset.pk],
                "symptoms": "بطارية",
                "assigned_employee_id": self.linked_employee.pk,
            },
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        job = Job.objects.get(pk=response.data["id"])
        self.assertEqual(job.assigned_employee_id, self.linked_employee.pk)
        self.assertEqual(job.assigned_to_id, self.technician.pk)


class JobSettlementAndCustodyTests(OperationsTestCase):
    """The repair loop's central promise: property does not leave unpaid.

    Before the settlement gate, invoicing drove a repair straight to "تم
    التسليم" and marked it complete, so the shop's records claimed the customer
    had their phone back at the instant the cashier took the money — and a phone
    that was never paid for could be handed over with nothing recording it.
    """

    def open_register(self, user):
        return RegisterSession.objects.create(
            owner=user,
            owner_key=f"user:{user.pk}",
            status=RegisterSession.Status.OPEN,
        )

    def bill_something(self, job_id, client=None):
        """Put a real part on the job so there is money to settle."""
        client = client or authenticated_client(self.technician)
        response = client.post(
            reverse("job-add-material", args=[job_id]),
            {"variant": self.part_variant.pk, "quantity": 1},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)

    def park_at_ready(self, job_id, approved_price="0.00"):
        """Walk the job to "جاهز للتسليم", the stage before handover.

        Only the *next* stage is an everyday move, so a test that jumps straight
        to the last stage would trip the pre-existing skip-stages guard and
        never reach the settlement gate it means to exercise. The approval gate
        in the middle needs a price; zero is a real answer (a warranty repair
        the customer approved at no charge).
        """
        manager_client = authenticated_client(self.manager)
        manager_client.patch(
            reverse("job-detail", args=[job_id]),
            {"approved_price": approved_price},
            format="json",
        )
        template = repair_template()
        for code in ("diagnosing", "waiting_approval", "repairing", "testing", "ready"):
            response = manager_client.post(
                reverse("job-transition", args=[job_id]),
                {"to_stage": stage(template, code).pk, "note": "تقدم"},
                format="json",
            )
            self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)

    def test_seeded_repair_terminal_stage_gates_on_settlement(self):
        delivered = stage(repair_template(), "delivered")
        self.assertTrue(delivered.requires_settlement)
        self.assertTrue(delivered.releases_custody)

    def test_unpaid_job_cannot_be_handed_over(self):
        client = authenticated_client(self.cashier)
        data = self.create_repair_job(client=client)
        self.bill_something(data["id"])
        self.park_at_ready(data["id"])

        blocked = client.post(
            reverse("job-transition", args=[data["id"]]),
            {"to_stage": stage(repair_template(), "delivered").pk},
            format="json",
        )

        self.assertEqual(blocked.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(blocked.data.get("code"), "settlement_required")
        job = Job.objects.get(pk=data["id"])
        self.assertEqual(job.status, Job.Status.OPEN)
        self.assertIsNone(job.handed_over_at)

    def test_paid_job_hands_over_and_records_who_collected(self):
        client = authenticated_client(self.cashier)
        data = self.create_repair_job(client=client)
        self.bill_something(data["id"])
        self.open_register(self.cashier)
        invoiced = client.post(
            reverse("job-invoice", args=[data["id"]]),
            {
                "labor_total": "30.00",
                "payments": [{"method": "cash", "amount": "150.00"}],
            },
            format="json",
        )
        self.assertEqual(invoiced.status_code, status.HTTP_200_OK, invoiced.data)
        self.park_at_ready(data["id"], approved_price="150.00")

        handover = client.post(
            reverse("job-transition", args=[data["id"]]),
            {
                "to_stage": stage(repair_template(), "delivered").pk,
                "handed_over_to": "أخوه محمد",
            },
            format="json",
        )

        self.assertEqual(handover.status_code, status.HTTP_200_OK, handover.data)
        job = Job.objects.get(pk=data["id"])
        self.assertEqual(job.status, Job.Status.COMPLETED)
        self.assertIsNotNone(job.handed_over_at)
        self.assertEqual(job.handed_over_to, "أخوه محمد")
        self.assertEqual(job.custody_state, "released")

    def test_free_warranty_repair_needs_no_settlement(self):
        # Nothing was billed, so there is nothing to settle and no override
        # should be needed — otherwise staff learn to reach for the override.
        client = authenticated_client(self.cashier)
        data = self.create_repair_job(client=client)
        self.park_at_ready(data["id"])

        handover = client.post(
            reverse("job-transition", args=[data["id"]]),
            {"to_stage": stage(repair_template(), "delivered").pk},
            format="json",
        )

        self.assertEqual(handover.status_code, status.HTTP_200_OK, handover.data)
        self.assertEqual(
            Job.objects.get(pk=data["id"]).status, Job.Status.COMPLETED
        )

    def test_cashier_cannot_force_release_but_manager_can(self):
        client = authenticated_client(self.cashier)
        data = self.create_repair_job(client=client)
        self.bill_something(data["id"])
        self.park_at_ready(data["id"])

        refused = client.post(
            reverse("job-transition", args=[data["id"]]),
            {
                "to_stage": stage(repair_template(), "delivered").pk,
                "force_release": True,
                "note": "زبون قديم",
            },
            format="json",
        )
        self.assertEqual(refused.status_code, status.HTTP_400_BAD_REQUEST)

        manager_client = authenticated_client(self.manager)
        allowed = manager_client.post(
            reverse("job-transition", args=[data["id"]]),
            {
                "to_stage": stage(repair_template(), "delivered").pk,
                "force_release": True,
                "note": "زبون قديم، يدفع الأسبوع القادم",
            },
            format="json",
        )
        self.assertEqual(allowed.status_code, status.HTTP_200_OK, allowed.data)
        self.assertIsNotNone(Job.objects.get(pk=data["id"]).handed_over_at)

    def test_force_release_requires_a_reason(self):
        manager_client = authenticated_client(self.manager)
        data = self.create_repair_job(client=manager_client)
        self.bill_something(data["id"], client=manager_client)
        self.park_at_ready(data["id"])

        response = manager_client.post(
            reverse("job-transition", args=[data["id"]]),
            {
                "to_stage": stage(repair_template(), "delivered").pk,
                "force_release": True,
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_credit_invoice_counts_as_settled_and_leaves_a_balance(self):
        client = authenticated_client(self.cashier)
        data = self.create_repair_job(client=client)
        self.bill_something(data["id"])
        self.open_register(self.cashier)

        invoiced = client.post(
            reverse("job-invoice", args=[data["id"]]),
            {
                "labor_total": "30.00",
                "sale_type": "credit",
                "payments": [{"method": "cash", "amount": "50.00"}],
            },
            format="json",
        )

        self.assertEqual(invoiced.status_code, status.HTTP_200_OK, invoiced.data)
        job = Job.objects.get(pk=data["id"])
        self.assertEqual(job.order.sale_type, Order.SaleType.CREDIT)
        self.assertEqual(job.order.total, Decimal("150.00"))
        self.assertEqual(job.order.amount_paid, Decimal("50.00"))
        self.assertEqual(job.order.balance_due, Decimal("100.00"))
        self.assertEqual(job.order.status, Order.Status.OPEN)
        # آجل against a named customer is a decision, not an oversight: the
        # customer may take their phone.
        self.assertEqual(job.settlement_state, "deposit_paid")
        self.park_at_ready(data["id"], approved_price="150.00")
        handover = client.post(
            reverse("job-transition", args=[data["id"]]),
            {"to_stage": stage(repair_template(), "delivered").pk},
            format="json",
        )
        self.assertEqual(handover.status_code, status.HTTP_200_OK, handover.data)

    def test_credit_invoice_may_take_no_payment_at_all(self):
        client = authenticated_client(self.cashier)
        data = self.create_repair_job(client=client)
        self.bill_something(data["id"])
        self.open_register(self.cashier)

        invoiced = client.post(
            reverse("job-invoice", args=[data["id"]]),
            {"labor_total": "30.00", "sale_type": "credit", "payments": []},
            format="json",
        )

        self.assertEqual(invoiced.status_code, status.HTTP_200_OK, invoiced.data)
        job = Job.objects.get(pk=data["id"])
        self.assertEqual(job.order.balance_due, Decimal("150.00"))
        self.assertEqual(job.settlement_state, "credit_open")
        self.assertEqual(job.order.doc_status, DocumentStatus.SUBMITTED)

    def issue_credit_invoice(self, method="cash"):
        """A 150.00 repair on آجل with 50.00 down, issued by the cashier."""
        client = authenticated_client(self.cashier)
        data = self.create_repair_job(client=client)
        self.bill_something(data["id"])
        self.open_register(self.cashier)
        invoiced = client.post(
            reverse("job-invoice", args=[data["id"]]),
            {
                "labor_total": "30.00",
                "sale_type": "credit",
                "payments": [{"method": method, "amount": "50.00"}],
            },
            format="json",
        )
        self.assertEqual(invoiced.status_code, status.HTTP_200_OK, invoiced.data)
        return client, Job.objects.get(pk=data["id"])

    def test_credit_invoice_is_issued_at_once_not_when_it_is_paid(self):
        # It used to stay a draft until paid in full, and a draft's payments are
        # refused as though its invoice had been voided.
        _, job = self.issue_credit_invoice()

        order = job.order
        self.assertEqual(order.doc_status, DocumentStatus.SUBMITTED)
        self.assertEqual(order.status, Order.Status.OPEN)
        self.assertEqual(order.submitted_by, self.cashier)
        self.assertTrue(
            trail.history(order)
            .filter(action=DocumentEvent.Action.SUBMITTED, actor=self.cashier)
            .exists()
        )

    def test_credit_invoice_down_payment_can_be_cancelled_and_is_owed_again(self):
        # A transfer, as in the business simulation that found this. Giving one
        # back needs no drawer, so the manager needs no register of their own.
        _, job = self.issue_credit_invoice(method="transfer")

        cancelled = authenticated_client(self.manager).post(
            reverse("payment-cancel", args=[job.order.payments.get().pk]),
            {"reason": "الحوالة لم تصل"},
            format="json",
        )

        self.assertEqual(cancelled.status_code, status.HTTP_200_OK, cancelled.data)
        job = Job.objects.get(pk=job.pk)
        self.assertEqual(job.order.amount_paid, Decimal("0.00"))
        self.assertEqual(job.order.balance_due, Decimal("150.00"))
        self.assertEqual(job.order.status, Order.Status.OPEN)
        self.assertEqual(job.settlement_state, "credit_open")

    def test_a_draft_an_older_backend_left_is_issued_on_upgrade(self):
        client, job = self.issue_credit_invoice()
        order = job.order
        # What the older code left behind: the same invoice, never submitted,
        # issued in a month the shop has since closed.
        issued_at = timezone.now() - timedelta(days=60)
        Order.objects.filter(pk=order.pk).update(
            doc_status=DocumentStatus.DRAFT, submitted_at=None, submitted_by=None
        )
        Order.objects.filter(pk=order.pk).update(created_at=issued_at)
        settings_row = ShopSettings.load()
        settings_row.books_locked_through = timezone.localdate() - timedelta(days=30)
        settings_row.save(update_fields=["books_locked_through"])

        def collect_the_rest():
            return client.post(
                reverse("order-record-payment", args=[order.pk]),
                {"method": "cash", "amount": "100.00"},
                format="json",
            )

        # Its last collection has to submit it, dated to that closed month —
        # which a cashier cannot override.
        self.assertEqual(collect_the_rest().status_code, status.HTTP_403_FORBIDDEN)

        reconcile_lifecycles()

        order.refresh_from_db()
        self.assertEqual(order.doc_status, DocumentStatus.SUBMITTED)
        self.assertEqual(order.submitted_at, issued_at)
        self.assertEqual(reconcile_lifecycles(), 0)
        collected = collect_the_rest()
        self.assertEqual(collected.status_code, status.HTTP_201_CREATED, collected.data)
        order.refresh_from_db()
        self.assertEqual(order.status, Order.Status.PAID)

    def test_standard_invoice_still_demands_the_full_amount(self):
        client = authenticated_client(self.cashier)
        data = self.create_repair_job(client=client)
        self.bill_something(data["id"])
        self.open_register(self.cashier)

        response = client.post(
            reverse("job-invoice", args=[data["id"]]),
            {
                "labor_total": "30.00",
                "payments": [{"method": "cash", "amount": "50.00"}],
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIsNone(Job.objects.get(pk=data["id"]).order)

    def test_billing_above_the_approved_price_needs_acknowledgement(self):
        client = authenticated_client(self.cashier)
        data = self.create_repair_job(client=client)
        self.bill_something(data["id"])
        manager_client = authenticated_client(self.manager)
        manager_client.patch(
            reverse("job-detail", args=[data["id"]]),
            {"approved_price": "100.00"},
            format="json",
        )
        self.open_register(self.cashier)

        blocked = client.post(
            reverse("job-invoice", args=[data["id"]]),
            {
                "labor_total": "30.00",
                "payments": [{"method": "cash", "amount": "150.00"}],
            },
            format="json",
        )
        self.assertEqual(blocked.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(blocked.data.get("code"), "over_approved_price")

        allowed = client.post(
            reverse("job-invoice", args=[data["id"]]),
            {
                "labor_total": "30.00",
                "acknowledge_over_quote": True,
                "payments": [{"method": "cash", "amount": "150.00"}],
            },
            format="json",
        )
        self.assertEqual(allowed.status_code, status.HTTP_200_OK, allowed.data)

    def test_reopening_a_delivered_job_takes_custody_back(self):
        manager_client = authenticated_client(self.manager)
        data = self.create_repair_job(client=manager_client)
        self.park_at_ready(data["id"])
        manager_client.post(
            reverse("job-transition", args=[data["id"]]),
            {"to_stage": stage(repair_template(), "delivered").pk},
            format="json",
        )
        self.assertIsNotNone(Job.objects.get(pk=data["id"]).handed_over_at)

        reopened = manager_client.post(
            reverse("job-reopen", args=[data["id"]]),
            {"note": "رجع الزبون بنفس المشكلة"},
            format="json",
        )

        self.assertEqual(reopened.status_code, status.HTTP_200_OK, reopened.data)
        job = Job.objects.get(pk=data["id"])
        self.assertIsNone(job.handed_over_at)
        self.assertEqual(job.custody_state, "with_shop")


class JobServiceLineTests(OperationsTestCase):
    def setUp(self):
        super().setUp()
        self.diagnosis = create_product_with_default_variant(
            sku="SVC-DIAG",
            name="كشف وتشخيص",
            unit_price=Decimal("25.00"),
        )
        self.diagnosis.is_service = True
        self.diagnosis.save(update_fields=["is_service"])
        self.diagnosis_variant = self.diagnosis.default_variant

    def open_register(self, user):
        return RegisterSession.objects.create(
            owner=user,
            owner_key=f"user:{user.pk}",
            status=RegisterSession.Status.OPEN,
        )

    def test_service_is_added_priced_and_billed_as_its_own_line(self):
        client = authenticated_client(self.technician)
        data = self.create_repair_job(client=client)

        added = client.post(
            reverse("job-add-service", args=[data["id"]]),
            {"variant": self.diagnosis_variant.pk, "note": "فحص أولي"},
            format="json",
        )

        self.assertEqual(added.status_code, status.HTTP_200_OK, added.data)
        self.assertEqual(added.data["services_total"], "25.00")
        service = added.data["services"][0]
        self.assertEqual(service["unit_price"], "25.00")
        self.assertEqual(service["note"], "فحص أولي")

        cashier_client = authenticated_client(self.cashier)
        self.open_register(self.cashier)
        invoiced = cashier_client.post(
            reverse("job-invoice", args=[data["id"]]),
            {"payments": [{"method": "cash", "amount": "25.00"}]},
            format="json",
        )
        self.assertEqual(invoiced.status_code, status.HTTP_200_OK, invoiced.data)
        order = Job.objects.get(pk=data["id"]).order
        self.assertEqual(order.total, Decimal("25.00"))
        line = order.lines.get(variant=self.diagnosis_variant)
        # A service costs the shop nothing in goods; the technician's time is
        # payroll's problem, and charging it here would double-count.
        self.assertEqual(line.unit_cost, Decimal("0.00"))

    def test_stock_products_are_refused_as_services(self):
        client = authenticated_client(self.technician)
        data = self.create_repair_job(client=client)

        response = client.post(
            reverse("job-add-service", args=[data["id"]]),
            {"variant": self.part_variant.pk},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_service_can_be_removed_before_invoicing(self):
        client = authenticated_client(self.technician)
        data = self.create_repair_job(client=client)
        added = client.post(
            reverse("job-add-service", args=[data["id"]]),
            {"variant": self.diagnosis_variant.pk},
            format="json",
        )
        service_id = added.data["services"][0]["id"]

        removed = client.delete(
            reverse("job-remove-service", args=[data["id"], service_id])
        )

        self.assertEqual(removed.status_code, status.HTTP_200_OK, removed.data)
        self.assertEqual(removed.data["services"], [])
        self.assertEqual(removed.data["services_total"], "0.00")

    def test_a_job_with_only_a_service_still_gates_on_settlement(self):
        # A diagnosis with no parts is still money owed — the commonest small
        # repair-shop ticket there is.
        client = authenticated_client(self.technician)
        data = self.create_repair_job(client=client)
        client.post(
            reverse("job-add-service", args=[data["id"]]),
            {"variant": self.diagnosis_variant.pk},
            format="json",
        )
        manager_client = authenticated_client(self.manager)
        manager_client.patch(
            reverse("job-detail", args=[data["id"]]),
            {"approved_price": "25.00"},
            format="json",
        )
        for code in ("diagnosing", "waiting_approval", "repairing", "testing", "ready"):
            manager_client.post(
                reverse("job-transition", args=[data["id"]]),
                {"to_stage": stage(repair_template(), code).pk},
                format="json",
            )

        blocked = client.post(
            reverse("job-transition", args=[data["id"]]),
            {"to_stage": stage(repair_template(), "delivered").pk},
            format="json",
        )

        self.assertEqual(blocked.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(blocked.data.get("code"), "settlement_required")


class JobHoldTests(OperationsTestCase):
    def test_hold_and_resume_accumulate_waiting_time(self):
        client = authenticated_client(self.technician)
        data = self.create_repair_job(client=client)

        held = client.post(
            reverse("job-hold", args=[data["id"]]),
            {"reason": "بانتظار وصول الشاشة"},
            format="json",
        )

        self.assertEqual(held.status_code, status.HTTP_200_OK, held.data)
        self.assertTrue(held.data["is_on_hold"])
        self.assertEqual(held.data["hold_reason"], "بانتظار وصول الشاشة")

        # Backdate the hold so the accumulated wait is measurable without
        # sleeping in the test.
        job = Job.objects.get(pk=data["id"])
        job.on_hold_since = job.on_hold_since - timedelta(minutes=90)
        job.save(update_fields=["on_hold_since"])

        resumed = client.post(reverse("job-resume", args=[data["id"]]), format="json")

        self.assertEqual(resumed.status_code, status.HTTP_200_OK, resumed.data)
        self.assertFalse(resumed.data["is_on_hold"])
        self.assertEqual(resumed.data["hold_reason"], "")
        job.refresh_from_db()
        self.assertGreaterEqual(job.held_seconds, 90 * 60)

    def test_hold_needs_a_reason_and_cannot_be_doubled(self):
        client = authenticated_client(self.technician)
        data = self.create_repair_job(client=client)

        no_reason = client.post(
            reverse("job-hold", args=[data["id"]]), {"reason": ""}, format="json"
        )
        self.assertEqual(no_reason.status_code, status.HTTP_400_BAD_REQUEST)

        client.post(
            reverse("job-hold", args=[data["id"]]),
            {"reason": "قطعة غيار"},
            format="json",
        )
        again = client.post(
            reverse("job-hold", args=[data["id"]]),
            {"reason": "قطعة غيار"},
            format="json",
        )
        self.assertEqual(again.status_code, status.HTTP_400_BAD_REQUEST)

    def test_moving_a_job_forward_ends_its_hold(self):
        """Advancing *is* resuming: the part arrived.

        Leaving the hold set would keep the card badged "waiting for a screen"
        three stages later, and keep counting the wait as blocked time.
        """
        client = authenticated_client(self.manager)
        data = self.create_repair_job(client=client)
        client.post(
            reverse("job-hold", args=[data["id"]]),
            {"reason": "بانتظار قطعة"},
            format="json",
        )
        job = Job.objects.get(pk=data["id"])
        job.on_hold_since = job.on_hold_since - timedelta(minutes=30)
        job.save(update_fields=["on_hold_since"])

        response = client.post(
            reverse("job-transition", args=[data["id"]]),
            {"to_stage": stage(repair_template(), "diagnosing").pk},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        job.refresh_from_db()
        self.assertIsNone(job.on_hold_since)
        self.assertEqual(job.hold_reason, "")
        # The wait it did spend blocked is still counted.
        self.assertGreaterEqual(job.held_seconds, 30 * 60)

    def test_moving_a_job_backwards_leaves_its_hold_alone(self):
        # A manager correcting a mis-click has not made the part arrive.
        client = authenticated_client(self.manager)
        data = self.create_repair_job(client=client)
        client.post(
            reverse("job-transition", args=[data["id"]]),
            {"to_stage": stage(repair_template(), "diagnosing").pk},
            format="json",
        )
        client.post(
            reverse("job-hold", args=[data["id"]]),
            {"reason": "بانتظار قطعة"},
            format="json",
        )

        client.post(
            reverse("job-transition", args=[data["id"]]),
            {"to_stage": stage(repair_template(), "received").pk, "note": "تصحيح"},
            format="json",
        )

        job = Job.objects.get(pk=data["id"])
        self.assertIsNotNone(job.on_hold_since)
        self.assertEqual(job.hold_reason, "بانتظار قطعة")


class AssetRegistryTests(OperationsTestCase):
    """Looking an item up by its number, and following it between owners."""

    def setUp(self):
        super().setUp()
        self.owner = Customer.objects.create(full_name="سالم", phone="0921")
        self.car = Asset.objects.create(
            customer=self.owner,
            asset_type=asset_type("vehicle"),
            brand="Toyota",
            model_name="Corolla",
            vin="JTDBR32E520012345",
            plate_number="12-3456",
            model_year=2018,
            odometer=143000,
        )

    def test_every_asset_is_born_with_an_ownership_row(self):
        ownership = self.car.ownerships.get()
        self.assertEqual(ownership.customer, self.owner)
        self.assertTrue(ownership.is_current)
        # The seeded phone from the base fixture too — the signal is not
        # special-cased to vehicles.
        self.assertEqual(self.asset.ownerships.count(), 1)

    def test_lookup_by_chassis_plate_and_imei(self):
        client = authenticated_client(self.cashier)
        for query, expected in (
            ("JTDBR32E520012345", self.car.pk),
            ("12-3456", self.car.pk),
            ("356789", self.asset.pk),
        ):
            response = client.get(reverse("asset-list"), {"search": query})
            self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
            results = response.data["results"]
            self.assertEqual(
                [row["id"] for row in results],
                [expected],
                f"searching {query!r}",
            )

    def test_identity_label_prefers_the_number_people_quote(self):
        self.assertEqual(self.car.identity_label, "12-3456")
        self.assertEqual(self.asset.identity_label, "356789")

    def test_in_shop_filter_finds_items_with_open_work(self):
        client = authenticated_client(self.technician)
        self.create_repair_job(client=client)

        in_shop = client.get(reverse("asset-list"), {"in_shop": "true"})

        self.assertEqual(in_shop.status_code, status.HTTP_200_OK, in_shop.data)
        rows = in_shop.data["results"]
        self.assertEqual([row["id"] for row in rows], [self.asset.pk])
        self.assertEqual(rows[0]["open_job_count"], 1)

    def test_detail_carries_ownership_chain_and_job_history(self):
        tech_client = authenticated_client(self.technician)
        self.create_repair_job(client=tech_client)

        response = tech_client.get(reverse("asset-detail", args=[self.asset.pk]))

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(len(response.data["ownerships"]), 1)
        history = response.data["jobs"]
        self.assertEqual(len(history), 1)
        self.assertEqual(history[0]["symptoms"], "شاشة مكسورة")
        self.assertEqual(response.data["total_spent"], "0.00")

    def test_transfer_moves_the_owner_but_keeps_the_history(self):
        client = authenticated_client(self.cashier)
        tech_client = authenticated_client(self.technician)
        self.create_repair_job(client=tech_client)
        buyer = Customer.objects.create(full_name="مشتري", phone="0933")

        response = client.post(
            reverse("asset-transfer", args=[self.asset.pk]),
            {"customer": buyer.pk, "note": "باعه لصاحبه"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.asset.refresh_from_db()
        self.assertEqual(self.asset.customer, buyer)
        chain = list(self.asset.ownerships.order_by("acquired_at"))
        self.assertEqual(len(chain), 2)
        self.assertEqual(chain[0].customer, self.customer)
        self.assertIsNotNone(chain[0].released_at)
        self.assertEqual(chain[1].customer, buyer)
        self.assertIsNone(chain[1].released_at)
        # The new owner can see what the previous one had done — the point of
        # keeping history on the item rather than on the person.
        detail = client.get(reverse("asset-detail", args=[self.asset.pk]))
        self.assertEqual(len(detail.data["jobs"]), 1)

    def test_transferring_to_the_current_owner_changes_nothing(self):
        client = authenticated_client(self.cashier)

        response = client.post(
            reverse("asset-transfer", args=[self.car.pk]),
            {"customer": self.owner.pk},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(self.car.ownerships.count(), 1)


class ShopSetupKitchenModeTests(OperationsTestCase):
    """The café's choice, made in plain language at setup.

    Chit-only finishes the job at the sale, so nothing ever reaches a board.
    That is right for a kitchen where cooks read a printed slip and wrong for a
    counter where the customer pays, waits, and is called when it is ready —
    which is the flow this asks about.
    """

    def setUp(self):
        super().setUp()
        ShopSettings.load()

    def test_setup_can_choose_the_staged_kitchen_lane(self):
        client = authenticated_client(self.manager)

        response = client.post(
            reverse("shop-setup"),
            {"shop_type": "restaurant", "kitchen_auto_complete": False},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        settings = ShopSettings.load()
        self.assertTrue(settings.enable_kitchen_operations)
        self.assertFalse(settings.kitchen_auto_complete)

    def test_setup_keeps_the_chit_only_default_when_not_asked(self):
        client = authenticated_client(self.manager)

        response = client.post(
            reverse("shop-setup"),
            {"shop_type": "restaurant"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertTrue(ShopSettings.load().kitchen_auto_complete)

    def test_car_workshop_preset_turns_on_repairs_only(self):
        client = authenticated_client(self.manager)

        response = client.post(
            reverse("shop-setup"),
            {"shop_type": "car_workshop"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        settings = ShopSettings.load()
        self.assertTrue(settings.enable_repair_operations)
        self.assertTrue(settings.enable_job_tracking)
        self.assertFalse(settings.enable_kitchen_operations)
        self.assertFalse(settings.enable_production_operations)


class JobMaterialCostBasisTests(OperationsTestCase):
    """A part fitted on a repair costs what the same part costs over the counter.

    Job materials used to snapshot ``latest_sale_unit_cost`` — the pre-ledger
    "whatever it last cost to buy" rule — while every sale line snapshots the
    valuation ledger. Two purchases at different prices are enough to tell the
    two apart, and with them apart every margin on repair revenue was computed
    on a basis nothing else in the shop used.
    """

    def setUp(self):
        super().setUp()
        self.supplier = Supplier.objects.create(name="مورد")
        self.variant = self.part_variant
        StockItem.objects.filter(variant=self.variant).update(quantity_on_hand=0)

    def _receive(self, quantity, unit_cost):
        order = PurchaseOrder.objects.create(supplier=self.supplier)
        PurchaseLine.objects.create(
            purchase_order=order,
            variant=self.variant,
            quantity=quantity,
            unit_cost=Decimal(unit_cost),
        )
        submit_purchase_order(order)
        receive_purchase_order(
            order,
            lines_data=[
                {
                    "line": line,
                    "accepted_quantity": line.quantity,
                    "damaged_quantity": 0,
                    "cancelled_quantity": 0,
                }
                for line in order.lines.all()
            ],
        )

    def test_material_cost_is_the_valuation_rate_not_the_last_purchase(self):
        # Moving average of 10@1.00 and 10@3.00 is 2.00; the last purchase is
        # 3.00. Anything that reads 3.00 here is on the old basis.
        self._receive(10, "1.00")
        self._receive(10, "3.00")

        client = authenticated_client(self.technician)
        data = self.create_repair_job(client=client)
        response = client.post(
            reverse("job-add-material", args=[data["id"]]),
            {"variant": self.variant.pk, "quantity": 1},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        material = Job.objects.get(pk=data["id"]).materials.get()
        self.assertEqual(material.unit_cost, Decimal("2.00"))

    def test_the_invoiced_order_line_carries_that_same_cost(self):
        # The cost only matters because it reaches the order line every margin
        # is computed from.
        self._receive(10, "1.00")
        self._receive(10, "3.00")
        tech = authenticated_client(self.technician)
        data = self.create_repair_job(client=tech)
        tech.post(
            reverse("job-add-material", args=[data["id"]]),
            {"variant": self.variant.pk, "quantity": 2},
            format="json",
        )
        cashier = authenticated_client(self.cashier)
        RegisterSession.objects.create(
            owner=self.cashier,
            owner_key=f"user:{self.cashier.pk}",
            status=RegisterSession.Status.OPEN,
        )

        invoiced = cashier.post(
            reverse("job-invoice", args=[data["id"]]),
            {"payments": [{"method": "cash", "amount": "240.00"}]},
            format="json",
        )

        self.assertEqual(invoiced.status_code, status.HTTP_200_OK, invoiced.data)
        line = Job.objects.get(pk=data["id"]).order.lines.get(variant=self.variant)
        self.assertEqual(line.unit_cost, Decimal("2.00"))
        # …and so the order's profit is computed against the goods' real value.
        self.assertEqual(line.line_cost, Decimal("4.00"))


class AssetTypeFlexibilityTests(OperationsTestCase):
    """A shop that repairs something we never thought of can still write it down.

    The type used to be a seven-value enum, which quietly decided Pointy served
    phone shops and car workshops and nobody else.
    """

    def test_builtin_types_are_seeded_with_their_identity_fields(self):
        phone = AssetType.objects.get(slug="phone")
        vehicle = AssetType.objects.get(slug="vehicle")

        # A phone has an IMEI and no number plate; a car is the other way round.
        self.assertTrue(phone.tracks_imei)
        self.assertFalse(phone.tracks_plate_number)
        self.assertTrue(vehicle.tracks_plate_number)
        self.assertTrue(vehicle.tracks_vin)
        self.assertFalse(vehicle.tracks_imei)
        self.assertTrue(vehicle.tracks_odometer)

    def test_a_shop_can_add_its_own_kind_of_item(self):
        client = authenticated_client(self.manager)

        response = client.post(
            reverse("asset-type-list"),
            {
                "name": "تلفاز",
                "slug": "television",
                "icon_key": "device",
                "tracks_serial_number": True,
                "custom_identifier_label": "رقم اللوحة الأم",
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        created = AssetType.objects.get(slug="television")
        self.assertFalse(created.is_system)
        self.assertEqual(created.custom_identifier_label, "رقم اللوحة الأم")

    def test_an_item_of_a_shop_defined_type_is_found_by_its_own_number(self):
        # The whole point: one search box over whatever this trade calls its
        # number, without a column per trade.
        generator = AssetType.objects.create(
            name="مولد كهرباء",
            slug="generator",
            custom_identifier_label="رقم العداد",
        )
        asset = Asset.objects.create(
            customer=self.customer,
            asset_type=generator,
            brand="Perkins",
            custom_identifier="MTR-99881",
        )
        client = authenticated_client(self.cashier)

        response = client.get(reverse("asset-list"), {"search": "MTR-99881"})

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        rows = response.data["results"]
        self.assertEqual([row["id"] for row in rows], [asset.pk])
        self.assertEqual(rows[0]["asset_type_name"], "مولد كهرباء")
        # The label travels with the asset so the UI can name the field.
        self.assertEqual(rows[0]["custom_identifier_label"], "رقم العداد")
        self.assertEqual(rows[0]["identity_label"], "MTR-99881")

    def test_a_builtin_type_can_be_deactivated_but_not_deleted(self):
        client = authenticated_client(self.manager)
        console = AssetType.objects.get(slug="console")

        deleted = client.delete(reverse("asset-type-detail", args=[console.pk]))
        self.assertEqual(deleted.status_code, status.HTTP_400_BAD_REQUEST)

        deactivated = client.patch(
            reverse("asset-type-detail", args=[console.pk]),
            {"is_active": False},
            format="json",
        )
        self.assertEqual(deactivated.status_code, status.HTTP_200_OK)
        console.refresh_from_db()
        self.assertFalse(console.is_active)

    def test_a_type_with_items_registered_to_it_cannot_be_deleted(self):
        client = authenticated_client(self.manager)
        drone = AssetType.objects.create(name="درون", slug="drone")
        Asset.objects.create(customer=self.customer, asset_type=drone)

        response = client.delete(reverse("asset-type-detail", args=[drone.pk]))

        self.assertEqual(response.status_code, status.HTTP_409_CONFLICT)
        self.assertTrue(AssetType.objects.filter(pk=drone.pk).exists())

    def test_an_unused_shop_type_can_be_deleted(self):
        client = authenticated_client(self.manager)
        typo = AssetType.objects.create(name="خطأ", slug="typo")

        response = client.delete(reverse("asset-type-detail", args=[typo.pk]))

        self.assertEqual(response.status_code, status.HTTP_204_NO_CONTENT)
        self.assertFalse(AssetType.objects.filter(pk=typo.pk).exists())

    def test_the_intake_list_is_readable_by_front_desk(self):
        # The intake form needs the types and their flags to know which fields
        # to show, so a cashier must be able to read them.
        response = authenticated_client(self.cashier).get(reverse("asset-type-list"))

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertGreaterEqual(len(response.data["results"]), 7)


class JobWarrantyTests(OperationsTestCase):
    """"Is this still under your warranty?" — the first question at the counter.

    We stored ``warranty_days`` and never answered it. Derived from the handover
    rather than stored, so a corrected warranty or a reopened job cannot leave a
    stale date behind. Same comparison ERPNext's Serial No makes for "Under
    Warranty" vs "Out of Warranty", applied to the repair rather than the item —
    the cover a shop gives is on the work it did.
    """

    def _delivered_job(self, warranty_days, handed_over_days_ago):
        client = authenticated_client(self.manager)
        data = self.create_repair_job(client=client, warranty_days=warranty_days)
        job = Job.objects.get(pk=data["id"])
        job.handed_over_at = timezone.now() - timedelta(days=handed_over_days_ago)
        job.status = Job.Status.COMPLETED
        job.save(update_fields=["handed_over_at", "status"])
        return job

    def test_a_recent_repair_is_still_covered(self):
        job = self._delivered_job(warranty_days=90, handed_over_days_ago=10)

        self.assertTrue(job.is_under_warranty)
        self.assertEqual(
            job.warranty_expires_on,
            timezone.localtime(job.handed_over_at).date() + timedelta(days=90),
        )

    def test_cover_that_has_run_out_reads_as_expired(self):
        job = self._delivered_job(warranty_days=30, handed_over_days_ago=45)

        self.assertFalse(job.is_under_warranty)

    def test_the_last_day_of_cover_still_counts(self):
        # Expiry on today is covered, not expired — the boundary a customer
        # turning up on the final day depends on.
        job = self._delivered_job(warranty_days=30, handed_over_days_ago=30)

        self.assertEqual(job.warranty_expires_on, timezone.localdate())
        self.assertTrue(job.is_under_warranty)

    def test_a_job_with_no_warranty_or_no_handover_has_no_expiry(self):
        no_cover = self._delivered_job(warranty_days=0, handed_over_days_ago=1)
        self.assertIsNone(no_cover.warranty_expires_on)
        self.assertFalse(no_cover.is_under_warranty)

        # Still on the bench: cover starts when the customer gets it back.
        client = authenticated_client(self.manager)
        data = self.create_repair_job(client=client, warranty_days=90)
        self.assertIsNone(Job.objects.get(pk=data["id"]).warranty_expires_on)

    def test_the_asset_reports_the_longest_cover_any_repair_gave(self):
        # A later repair with no warranty must not shorten the cover an earlier
        # one gave: the answer is the latest expiry across every visit.
        self._delivered_job(warranty_days=180, handed_over_days_ago=5)
        self._delivered_job(warranty_days=0, handed_over_days_ago=1)

        response = authenticated_client(self.cashier).get(
            reverse("asset-detail", args=[self.asset.pk])
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        expected = (timezone.localdate() - timedelta(days=5)) + timedelta(days=180)
        self.assertEqual(response.data["warranty_expires_on"], expected.isoformat())
        covered = [job for job in response.data["jobs"] if job["is_under_warranty"]]
        self.assertEqual(len(covered), 1)
