"""What the counter of a phone-repair shop has to be able to do on its own.

Found in a field export (2026-09-25): the cashier who takes phones in could not
move a job past a stage it had already passed in real life without clicking
through every stage in between, could not charge for labour unless somebody had
first put that exact job in the catalog as a service product, could not put a
part on a job without a manager, and could not assign the job to a technician
because the picker read the HR register.

These tests hold the counter to doing all of that — and hold the gates a jump
passes to still being gates.
"""

from decimal import Decimal

from django.urls import reverse
from rest_framework import status

from apps.analytics.models import AnalyticsEvent
from apps.catalog.testing import create_product_with_default_variant
from apps.employees.models import Employee
from apps.inventory.models import StockItem
from apps.sales.models import RegisterSession
from .models import Job, JobMaterial, WorkflowTemplate
from .services import LABOR_PRODUCT_SKU, add_job_material, create_job
from .tests import (
    OperationsTestCase,
    authenticated_client,
    repair_template,
    stage,
)


def move(client, job_id, code, template=None, **payload):
    return client.post(
        reverse("job-transition", args=[job_id]),
        {"to_stage": stage(template or repair_template(), code).pk, **payload},
        format="json",
    )


class StageJumpTests(OperationsTestCase):
    def setUp(self):
        super().setUp()
        self.client = authenticated_client(self.cashier)

    def test_the_counter_can_jump_ahead_once_the_price_is_agreed(self):
        data = self.create_repair_job(client=self.client)
        self.client.patch(
            reverse("job-detail", args=[data["id"]]),
            {"approved_price": "150.00"},
            format="json",
        )

        # Audit events are written on commit.
        with self.captureOnCommitCallbacks(execute=True):
            response = move(self.client, data["id"], "repairing")

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        job = Job.objects.get(pk=data["id"])
        self.assertEqual(job.current_stage.code, "repairing")
        event = AnalyticsEvent.objects.filter(
            name="operations.job.stage_changed", entity_id=str(job.pk)
        ).latest("occurred_at")
        # Diagnosing and waiting-for-approval were stepped over, on the record.
        self.assertEqual(event.attributes["skipped_stages"], 2)

    def test_a_jump_cannot_step_over_the_customers_approval(self):
        # The approval gate guards leaving its stage; a jump that goes round it
        # without a price would make the gate one click wide.
        data = self.create_repair_job(client=self.client)

        response = move(self.client, data["id"], "repairing")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data.get("code"), "approval_required")
        job = Job.objects.get(pk=data["id"])
        self.assertEqual(job.current_stage.code, "received")

    def test_a_manager_jumping_over_approval_needs_the_price_too(self):
        manager = authenticated_client(self.manager)
        data = self.create_repair_job(client=manager)

        response = move(manager, data["id"], "testing")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data.get("code"), "approval_required")

    def test_stages_before_the_approval_gate_are_free_to_skip(self):
        data = self.create_repair_job(client=self.client)

        response = move(self.client, data["id"], "waiting_approval")

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)

    def test_the_counter_can_move_a_job_back(self):
        # The test failed: back to the bench, without fetching a manager.
        data = self.create_repair_job(client=self.client)
        self.client.patch(
            reverse("job-detail", args=[data["id"]]),
            {"approved_price": "80.00"},
            format="json",
        )
        move(self.client, data["id"], "testing")

        response = move(self.client, data["id"], "repairing", note="فشل الاختبار")

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(
            Job.objects.get(pk=data["id"]).current_stage.code, "repairing"
        )

    def test_jumping_to_the_handover_still_needs_the_money(self):
        data = self.create_repair_job(client=self.client)
        self.client.patch(
            reverse("job-detail", args=[data["id"]]),
            {"approved_price": "120.00"},
            format="json",
        )
        added = self.client.post(
            reverse("job-add-material", args=[data["id"]]),
            {"variant": self.part_variant.pk, "quantity": 1},
            format="json",
        )
        self.assertEqual(added.status_code, status.HTTP_200_OK, added.data)

        response = move(self.client, data["id"], "delivered")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data.get("code"), "settlement_required")
        job = Job.objects.get(pk=data["id"])
        self.assertEqual(job.status, Job.Status.OPEN)
        self.assertIsNone(job.handed_over_at)

    def test_a_free_repair_jumps_straight_to_the_handover(self):
        # A warranty fix agreed at no charge: nothing to settle, so the jump to
        # "delivered" hands the phone back and finishes the job in one move.
        data = self.create_repair_job(client=self.client)
        self.client.patch(
            reverse("job-detail", args=[data["id"]]),
            {"approved_price": "0.00"},
            format="json",
        )

        response = move(
            self.client, data["id"], "delivered", handed_over_to="صاحب الجهاز"
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        job = Job.objects.get(pk=data["id"])
        self.assertEqual(job.status, Job.Status.COMPLETED)
        self.assertIsNotNone(job.handed_over_at)
        self.assertEqual(job.handed_over_to, "صاحب الجهاز")

    def test_a_jump_owes_the_materials_a_skipped_stage_would_have_used(self):
        # Kitchen: received → preparing (uses the ingredients) → ready. Jumping
        # from received to ready must not leave the ingredients unused.
        template = WorkflowTemplate.objects.get(job_type="kitchen", is_system=True)
        job = create_job(workflow_template=template)
        material = add_job_material(
            job=job,
            variant=self.part_variant,
            quantity=Decimal("1"),
            consume_now=False,
        )
        self.assertIsNone(material.consumed_at)

        response = move(self.client, job.pk, "ready", template=template)

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        material.refresh_from_db()
        self.assertIsNotNone(material.consumed_at)
        self.assertEqual(
            StockItem.objects.get(variant=self.part_variant).quantity_on_hand,
            Decimal("9"),
        )


class CounterLabourTests(OperationsTestCase):
    def setUp(self):
        super().setUp()
        self.client = authenticated_client(self.cashier)

    def open_register(self, user):
        return RegisterSession.objects.create(
            owner=user,
            owner_key=f"user:{user.pk}",
            status=RegisterSession.Status.OPEN,
        )

    def add_labour(self, job_id, **payload):
        return self.client.post(
            reverse("job-add-service", args=[job_id]),
            payload,
            format="json",
        )

    def test_the_counter_charges_labour_without_a_catalog_service(self):
        data = self.create_repair_job(client=self.client)

        response = self.add_labour(data["id"], note="تبديل شاشة", unit_price="50.00")

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        line = response.data["services"][0]
        self.assertTrue(line["is_labor"])
        self.assertEqual(line["note"], "تبديل شاشة")
        self.assertEqual(line["unit_price"], "50.00")
        self.assertEqual(response.data["services_total"], "50.00")
        service = Job.objects.get(pk=data["id"]).services.get()
        self.assertEqual(service.variant.sku, LABOR_PRODUCT_SKU)

    def test_labour_says_what_it_was_for_and_what_it_costs(self):
        data = self.create_repair_job(client=self.client)

        no_words = self.add_labour(data["id"], unit_price="50.00")
        no_price = self.add_labour(data["id"], note="تنظيف")
        free = self.add_labour(data["id"], note="تنظيف", unit_price="0.00")

        for response in (no_words, no_price, free):
            self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertFalse(Job.objects.get(pk=data["id"]).services.exists())

    def test_a_catalog_service_takes_the_price_agreed_for_this_job(self):
        diagnosis = create_product_with_default_variant(
            sku="SVC-CHECK", name="فحص", unit_price=Decimal("25.00")
        )
        diagnosis.is_service = True
        diagnosis.save(update_fields=["is_service"])
        data = self.create_repair_job(client=self.client)

        response = self.add_labour(
            data["id"], variant=diagnosis.default_variant.pk, unit_price="15.00"
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        line = response.data["services"][0]
        self.assertFalse(line["is_labor"])
        self.assertEqual(line["unit_price"], "15.00")

    def test_labour_is_billed_with_its_description(self):
        data = self.create_repair_job(client=self.client)
        self.add_labour(data["id"], note="تبديل منفذ الشحن", unit_price="40.00")
        self.open_register(self.cashier)

        invoiced = self.client.post(
            reverse("job-invoice", args=[data["id"]]),
            {"payments": [{"method": "cash", "amount": "40.00"}]},
            format="json",
        )

        self.assertEqual(invoiced.status_code, status.HTTP_200_OK, invoiced.data)
        order = Job.objects.get(pk=data["id"]).order
        self.assertEqual(order.total, Decimal("40.00"))
        line = order.lines.get()
        self.assertEqual(line.variant.sku, LABOR_PRODUCT_SKU)
        self.assertEqual(line.notes, "تبديل منفذ الشحن")

    def test_an_invoiced_job_takes_no_new_charges(self):
        # The phone stays on the shelf after it is paid for, but its bill is
        # closed: labour or a part added now would never be charged.
        data = self.create_repair_job(client=self.client)
        self.add_labour(data["id"], note="تبديل شاشة", unit_price="50.00")
        self.open_register(self.cashier)
        self.client.post(
            reverse("job-invoice", args=[data["id"]]),
            {"payments": [{"method": "cash", "amount": "50.00"}]},
            format="json",
        )

        labour = self.add_labour(data["id"], note="إضافي", unit_price="10.00")
        part = self.client.post(
            reverse("job-add-material", args=[data["id"]]),
            {"variant": self.part_variant.pk, "quantity": 1},
            format="json",
        )

        self.assertEqual(labour.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(part.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(
            StockItem.objects.get(variant=self.part_variant).quantity_on_hand,
            Decimal("10"),
        )


class CounterPartsAndCustomersTests(OperationsTestCase):
    def grant(self, user, code):
        from django.contrib.auth import get_user_model
        from django.contrib.auth.models import Permission

        app_label, codename = code.split(".")
        user.user_permissions.add(
            Permission.objects.get(
                content_type__app_label=app_label, codename=codename
            )
        )
        # A fresh instance, so has_perm() does not read a stale cache.
        return get_user_model().objects.get(pk=user.pk)

    def test_the_counter_puts_a_part_on_a_job_and_takes_it_back(self):
        client = authenticated_client(self.cashier)
        data = self.create_repair_job(client=client)

        added = client.post(
            reverse("job-add-material", args=[data["id"]]),
            {"variant": self.part_variant.pk, "quantity": 1},
            format="json",
        )
        self.assertEqual(added.status_code, status.HTTP_200_OK, added.data)
        material = JobMaterial.objects.get(job_id=data["id"])

        reversed_ = client.post(
            reverse("job-reverse-material", args=[data["id"], material.pk])
        )

        self.assertEqual(reversed_.status_code, status.HTTP_200_OK, reversed_.data)
        material.refresh_from_db()
        self.assertIsNotNone(material.reversed_at)

    def test_a_counter_granted_add_customers_registers_a_walk_in(self):
        # A per-user grant, as the shop owner gives it: the role itself leaves
        # it out while the compat/win8 till still reads it as a dashboard.
        client = authenticated_client(self.grant(self.cashier, "customers.add_customer"))

        response = client.post(
            reverse("customer-list"),
            {"full_name": "زبون جديد", "phone": "0925555555"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)

    def test_registering_customers_is_not_editing_them(self):
        client = authenticated_client(self.grant(self.cashier, "customers.add_customer"))

        response = client.patch(
            reverse("customer-detail", args=[self.customer.pk]),
            {"full_name": "اسم آخر"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)


class JobAssigneeTests(OperationsTestCase):
    def setUp(self):
        super().setUp()
        self.fixer = Employee.objects.create(
            full_name="سالم الفني",
            job_title="فني صيانة",
            employee_number="E-1",
        )
        Employee.objects.create(
            full_name="موظف سابق",
            employee_number="E-2",
            status=Employee.Status.TERMINATED,
        )

    def test_whoever_assigns_work_can_list_who_to_give_it_to(self):
        response = authenticated_client(self.cashier).get(reverse("job-assignees"))

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(
            response.data,
            [
                {
                    "id": self.fixer.pk,
                    "full_name": "سالم الفني",
                    "job_title": "فني صيانة",
                    "status": "active",
                }
            ],
        )

    def test_the_list_needs_the_right_to_assign(self):
        response = authenticated_client(self.technician).get(reverse("job-assignees"))

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)


class JobDetailStagesTests(OperationsTestCase):
    def test_one_job_carries_its_whole_workflow_and_the_board_does_not(self):
        client = authenticated_client(self.cashier)
        data = self.create_repair_job(client=client)

        detail = client.get(reverse("job-detail", args=[data["id"]]))
        board = client.get(reverse("job-list"))

        self.assertEqual(
            [item["code"] for item in detail.data["workflow_stages"]],
            [
                "received",
                "diagnosing",
                "waiting_approval",
                "repairing",
                "testing",
                "ready",
                "delivered",
            ],
        )
        self.assertNotIn("workflow_stages", board.data["results"][0])
        # A move answers with the same document, so the screen keeps its list.
        moved = move(client, data["id"], "diagnosing")
        self.assertIn("workflow_stages", moved.data)
