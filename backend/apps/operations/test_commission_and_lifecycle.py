"""Operations commission + job-lifecycle hardening tests.

Covers the recently-fixed regressions around commission eligibility
(internal kitchen/production jobs must earn nothing, cancelled jobs are
excluded, labor base clamps at zero) plus the kitchen duplicate-job guard,
``reopen_job`` permission gating + double-counting, and the
``receive_finished_goods`` idempotency guard.

The commission scenarios drive ``draft_monthly_payroll_run`` exactly like
``apps/employees/tests.py:OperationsCommissionPayrollTests`` so the assertions
exercise the real payroll path, not just ``_commissionable_jobs_total`` in
isolation.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.models import BillOfMaterials, BomLine, Product
from apps.catalog.testing import create_product_with_default_variant
from apps.core.models import ShopSettings
from apps.core.roles import (
    MANAGER_GROUP,
    TECHNICIAN_GROUP,
    ensure_role_groups,
)
from apps.employees.models import CompensationPlan, Employee, PayrollAdjustment
from apps.employees.services import draft_monthly_payroll_run
from apps.inventory.models import StockItem
from apps.sales.models import RegisterSession
from apps.sales.services import checkout_order

from .models import Job, JobMaterial, WorkflowTemplate
from .services import create_kitchen_job_for_order, receive_finished_goods, reopen_job


def repair_template():
    return WorkflowTemplate.objects.get(job_type="repair", is_system=True)


def production_template():
    return WorkflowTemplate.objects.get(job_type="production", is_system=True)


def kitchen_template():
    return WorkflowTemplate.objects.get(job_type="kitchen", is_system=True)


def terminal_stage(template):
    return template.stages.filter(is_terminal=True).order_by("display_order").first()


def initial_stage(template):
    return template.initial_stage()


class _CommissionBase(TestCase):
    """Shared fixture for the operations-commission payroll scenarios."""

    def setUp(self):
        ensure_role_groups()
        self.employee = Employee.objects.create(full_name="فني العمولة")
        # Operations-commission-only plan at 10%, default base = approved_price.
        self.plan = CompensationPlan.objects.create(
            employee=self.employee,
            pay_type=CompensationPlan.PayType.COMMISSION,
            salary_type=CompensationPlan.SalaryType.OPERATIONS_COMMISSION_ONLY,
            amount=Decimal("0.00"),
            commission_percent=Decimal("10.00"),
        )
        self.today = timezone.localdate()
        self.period_start = self.today.replace(day=1)

    def _make_job(
        self,
        *,
        job_type,
        template,
        approved_price,
        status_value=Job.Status.COMPLETED,
        completed_at="in_period",
        employee="self",
    ):
        if completed_at == "in_period":
            completed_at = timezone.now()
        if employee == "self":
            employee = self.employee
        job = Job.objects.create(
            job_type=job_type,
            workflow_template=template,
            current_stage=terminal_stage(template) or initial_stage(template),
            status=status_value,
            assigned_employee=employee,
            approved_price=approved_price,
        )
        if completed_at is not None:
            Job.objects.filter(pk=job.pk).update(completed_at=completed_at)
        return job

    def _draft(self):
        payroll, created = draft_monthly_payroll_run(
            period_start=self.period_start,
            period_end=self.today,
        )
        self.assertTrue(created, "expected a fresh payroll draft to be created")
        return payroll

    def _commission_addition(self, payroll):
        line = payroll.lines.get(employee=self.employee)
        return line.additions_amount


class InternalJobTypeCommissionTests(_CommissionBase):
    """REGRESSION: kitchen/production jobs never earn operations commission."""

    def test_completed_kitchen_job_contributes_zero_commission(self):
        # A kitchen job, completed in-period, assigned and priced exactly like a
        # commissionable repair — but it is internal work and must pay nothing.
        self._make_job(
            job_type=WorkflowTemplate.JobType.KITCHEN,
            template=kitchen_template(),
            approved_price=Decimal("200.00"),
        )

        payroll = self._draft()

        line = payroll.lines.get(employee=self.employee)
        self.assertEqual(self._commission_addition(payroll), Decimal("0.00"))
        self.assertEqual(line.net_amount, Decimal("0.00"))
        # No commission adjustment row should be attached at all.
        self.assertFalse(
            line.adjustments.filter(
                adjustment_type=PayrollAdjustment.AdjustmentType.COMMISSION
            ).exists()
        )

    def test_completed_production_job_contributes_zero_commission(self):
        self._make_job(
            job_type=WorkflowTemplate.JobType.PRODUCTION,
            template=production_template(),
            approved_price=Decimal("350.00"),
        )

        payroll = self._draft()

        self.assertEqual(self._commission_addition(payroll), Decimal("0.00"))

    def test_repair_pays_but_kitchen_and_production_alongside_do_not(self):
        # Same employee earns commission only on the repair; the kitchen and
        # production jobs sitting next to it are ignored.
        self._make_job(
            job_type=WorkflowTemplate.JobType.REPAIR,
            template=repair_template(),
            approved_price=Decimal("120.00"),
        )
        self._make_job(
            job_type=WorkflowTemplate.JobType.KITCHEN,
            template=kitchen_template(),
            approved_price=Decimal("500.00"),
        )
        self._make_job(
            job_type=WorkflowTemplate.JobType.PRODUCTION,
            template=production_template(),
            approved_price=Decimal("500.00"),
        )

        payroll = self._draft()

        # Only the 120.00 repair counts: 120 * 10% = 12.00.
        self.assertEqual(self._commission_addition(payroll), Decimal("12.00"))


class CancelledJobCommissionTests(_CommissionBase):
    def test_cancelled_priced_repair_is_excluded(self):
        # A cancelled repair, fully priced and assigned, with a completed_at
        # stamp inside the period — it must still earn nothing because only
        # COMPLETED jobs are commissionable.
        self._make_job(
            job_type=WorkflowTemplate.JobType.REPAIR,
            template=repair_template(),
            approved_price=Decimal("400.00"),
            status_value=Job.Status.CANCELLED,
        )

        payroll = self._draft()

        self.assertEqual(self._commission_addition(payroll), Decimal("0.00"))

    def test_cancelled_repair_alongside_completed_one_only_counts_completed(self):
        self._make_job(
            job_type=WorkflowTemplate.JobType.REPAIR,
            template=repair_template(),
            approved_price=Decimal("100.00"),
            status_value=Job.Status.COMPLETED,
        )
        self._make_job(
            job_type=WorkflowTemplate.JobType.REPAIR,
            template=repair_template(),
            approved_price=Decimal("900.00"),
            status_value=Job.Status.CANCELLED,
        )

        payroll = self._draft()

        # Only the completed 100.00 repair: 100 * 10% = 10.00.
        self.assertEqual(self._commission_addition(payroll), Decimal("10.00"))


class LaborBaseClampTests(_CommissionBase):
    """The labor base is approved_price minus consumed parts, clamped at >= 0."""

    def setUp(self):
        super().setUp()
        self.plan.operations_commission_base = (
            CompensationPlan.OperationsCommissionBase.LABOR
        )
        self.plan.save(update_fields=["operations_commission_base"])
        self.part = create_product_with_default_variant(
            sku="PART-CLAMP",
            name="قطعة باهظة",
            unit_price=Decimal("250.00"),
        ).default_variant

    def _add_consumed_part(self, job, *, quantity, unit_price):
        return JobMaterial.objects.create(
            job=job,
            variant=self.part,
            quantity=Decimal(quantity),
            unit_price=Decimal(unit_price),
            unit_cost=Decimal("0.00"),
            consumed_at=timezone.now(),
        )

    def test_negative_labor_clamps_to_zero_not_subtracted(self):
        # Parts (250) exceed approved price (200): labor is -50, which must NOT
        # be subtracted from the total. The job simply contributes zero.
        job = self._make_job(
            job_type=WorkflowTemplate.JobType.REPAIR,
            template=repair_template(),
            approved_price=Decimal("200.00"),
        )
        self._add_consumed_part(job, quantity="1.000", unit_price="250.00")

        payroll = self._draft()

        self.assertEqual(self._commission_addition(payroll), Decimal("0.00"))

    def test_underwater_job_does_not_drag_down_a_profitable_one(self):
        # One profitable repair (labor 150) and one underwater repair (labor -50).
        # The clamp means the underwater job adds 0 rather than cancelling 50 of
        # the profitable job's labor.
        good = self._make_job(
            job_type=WorkflowTemplate.JobType.REPAIR,
            template=repair_template(),
            approved_price=Decimal("200.00"),
        )
        self._add_consumed_part(good, quantity="1.000", unit_price="50.00")
        bad = self._make_job(
            job_type=WorkflowTemplate.JobType.REPAIR,
            template=repair_template(),
            approved_price=Decimal("200.00"),
        )
        self._add_consumed_part(bad, quantity="1.000", unit_price="250.00")

        payroll = self._draft()

        # Only the good job's 150 labor counts: 150 * 10% = 15.00.
        self.assertEqual(self._commission_addition(payroll), Decimal("15.00"))


class KitchenDuplicateGuardTests(TestCase):
    """REGRESSION: a replayed checkout must not open a second kitchen job or
    consume the recipe ingredients twice."""

    def setUp(self):
        ensure_role_groups()
        self.cashier = get_user_model().objects.create_user(
            username="kit-cashier", password="pass"
        )
        ShopSettings.load()
        ShopSettings.objects.filter(pk=1).update(enable_kitchen_operations=True)
        # A weighed ingredient with stock and a made-to-order dish recipe.
        self.meat = create_product_with_default_variant(
            sku="MEAT-DUP",
            name="لحم",
            unit_price=Decimal("30.00"),
        )
        self.meat.unit = Product.Unit.KILOGRAM
        self.meat.save(update_fields=["unit"])
        StockItem.objects.create(
            variant=self.meat.default_variant,
            quantity_on_hand=Decimal("5.000"),
        )
        self.burger = create_product_with_default_variant(
            sku="BURGER-DUP",
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
        self.session = RegisterSession.objects.create(
            owner=self.cashier,
            owner_key=f"user:{self.cashier.pk}",
        )

    def _checkout_two_burgers(self):
        return checkout_order(
            register_session=self.session,
            lines_data=[
                {"variant": self.burger.default_variant, "quantity": Decimal("2")}
            ],
            payments_data=[{"method": "cash", "amount": Decimal("24.00")}],
        )

    def test_second_call_does_not_create_a_second_job_or_double_consume(self):
        order = self._checkout_two_burgers()

        # Checkout already opened (and, by default, auto-completed) one kitchen
        # job and consumed the recipe once: 5.000 - (2 * 0.150) = 4.700.
        self.assertEqual(Job.objects.filter(order=order).count(), 1)
        self.assertEqual(
            StockItem.objects.get(variant=self.meat.default_variant).quantity_on_hand,
            Decimal("4.700"),
        )

        # A replay (retried request, duplicate task) must be a no-op.
        result = create_kitchen_job_for_order(order=order)

        self.assertIsNone(result)
        self.assertEqual(Job.objects.filter(order=order).count(), 1)
        # Stock did NOT move a second time.
        self.assertEqual(
            StockItem.objects.get(variant=self.meat.default_variant).quantity_on_hand,
            Decimal("4.700"),
        )

    def test_repeated_replays_stay_idempotent(self):
        order = self._checkout_two_burgers()
        for _ in range(3):
            self.assertIsNone(create_kitchen_job_for_order(order=order))
        self.assertEqual(Job.objects.filter(order=order).count(), 1)
        self.assertEqual(
            StockItem.objects.get(variant=self.meat.default_variant).quantity_on_hand,
            Decimal("4.700"),
        )


class ReopenJobTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.manager = get_user_model().objects.create_user(
            username="reopen-mgr", password="pass"
        )
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.technician = get_user_model().objects.create_user(
            username="reopen-tech", password="pass"
        )
        self.technician.groups.add(Group.objects.get(name=TECHNICIAN_GROUP))

    def _client(self, user):
        client = APIClient()
        client.force_authenticate(user=user)
        return client

    def _completed_repair(self):
        template = repair_template()
        job = Job.objects.create(
            job_type="repair",
            workflow_template=template,
            current_stage=terminal_stage(template),
            status=Job.Status.COMPLETED,
        )
        Job.objects.filter(pk=job.pk).update(completed_at=timezone.now())
        job.refresh_from_db()
        return job

    def test_reopen_clears_completion_and_reopens(self):
        job = self._completed_repair()
        self.assertIsNotNone(job.completed_at)

        reopen_job(job=job)

        job.refresh_from_db()
        self.assertEqual(job.status, Job.Status.OPEN)
        self.assertIsNone(job.completed_at)
        self.assertFalse(job.is_locked)

    def test_reopen_rejects_an_already_open_job(self):
        template = repair_template()
        job = Job.objects.create(
            job_type="repair",
            workflow_template=template,
            current_stage=initial_stage(template),
            status=Job.Status.OPEN,
        )
        from rest_framework import serializers as drf_serializers

        with self.assertRaises(drf_serializers.ValidationError):
            reopen_job(job=job)

    def test_reopen_api_requires_reopen_permission(self):
        # The technician role does not carry operations.reopen_job.
        job = self._completed_repair()
        response = self._client(self.technician).post(
            reverse("job-reopen", args=[job.pk])
        )
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        job.refresh_from_db()
        self.assertEqual(job.status, Job.Status.COMPLETED)

    def test_reopen_api_allows_manager(self):
        job = self._completed_repair()
        response = self._client(self.manager).post(
            reverse("job-reopen", args=[job.pk])
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        job.refresh_from_db()
        self.assertEqual(job.status, Job.Status.OPEN)
        self.assertIsNone(job.completed_at)

    def test_reopen_then_recomplete_is_not_double_counted_in_one_period(self):
        # A repair completed inside the period earns commission once. If it is
        # reopened and re-completed (still in the same period), the payroll draft
        # must still value it exactly once — it is a single job row, not two.
        employee = Employee.objects.create(full_name="فني إعادة فتح")
        CompensationPlan.objects.create(
            employee=employee,
            pay_type=CompensationPlan.PayType.COMMISSION,
            salary_type=CompensationPlan.SalaryType.OPERATIONS_COMMISSION_ONLY,
            amount=Decimal("0.00"),
            commission_percent=Decimal("10.00"),
        )
        template = repair_template()
        job = Job.objects.create(
            job_type="repair",
            workflow_template=template,
            current_stage=terminal_stage(template),
            status=Job.Status.COMPLETED,
            assigned_employee=employee,
            approved_price=Decimal("100.00"),
        )
        Job.objects.filter(pk=job.pk).update(completed_at=timezone.now())

        reopen_job(job=job)
        # Re-complete it (still in the current period).
        job.refresh_from_db()
        job.status = Job.Status.COMPLETED
        job.completed_at = timezone.now()
        job.save(update_fields=["status", "completed_at"])

        today = timezone.localdate()
        payroll, created = draft_monthly_payroll_run(
            period_start=today.replace(day=1),
            period_end=today,
        )

        self.assertTrue(created)
        line = payroll.lines.get(employee=employee)
        # 100 * 10% = 10.00, counted once.
        self.assertEqual(line.additions_amount, Decimal("10.00"))


class ReceiveFinishedGoodsIdempotencyTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.flour = create_product_with_default_variant(
            sku="FLOUR-IDEM",
            name="دقيق",
            unit_price=Decimal("2.00"),
        )
        StockItem.objects.create(
            variant=self.flour.default_variant,
            quantity_on_hand=Decimal("100"),
        )
        self.bread = create_product_with_default_variant(
            sku="BREAD-IDEM",
            name="خبز",
            unit_price=Decimal("1.00"),
        )

    def _production_job(self):
        template = production_template()
        job = Job.objects.create(
            job_type="production",
            workflow_template=template,
            current_stage=template.stages.filter(produces_output=True).first(),
            output_variant=self.bread.default_variant,
            output_quantity=20,
        )
        # A consumed ingredient so the produced unit cost is non-trivial.
        JobMaterial.objects.create(
            job=job,
            variant=self.flour.default_variant,
            quantity=Decimal("10.000"),
            unit_price=Decimal("2.00"),
            unit_cost=Decimal("2.00"),
            consumed_at=timezone.now(),
        )
        return job

    def test_re_entering_producing_stage_does_not_receive_output_twice(self):
        job = self._production_job()

        receive_finished_goods(job, request=None)
        job.save(update_fields=["output_unit_cost", "output_received_at"])
        job.refresh_from_db()

        first_received_at = job.output_received_at
        self.assertIsNotNone(first_received_at)
        self.assertEqual(
            StockItem.objects.get(variant=self.bread.default_variant).quantity_on_hand,
            Decimal("20"),
        )
        # consumed cost 20.00 / 20 units = 1.00 unit cost.
        self.assertEqual(job.output_unit_cost, Decimal("1.00"))

        # Re-entering the producing stage (replay) must be a guarded no-op.
        receive_finished_goods(job, request=None)
        job.save(update_fields=["output_unit_cost", "output_received_at"])
        job.refresh_from_db()

        self.assertEqual(
            StockItem.objects.get(variant=self.bread.default_variant).quantity_on_hand,
            Decimal("20"),
        )
        self.assertEqual(job.output_received_at, first_received_at)

    def test_receive_without_output_configured_is_rejected(self):
        template = production_template()
        job = Job.objects.create(
            job_type="production",
            workflow_template=template,
            current_stage=template.stages.filter(produces_output=True).first(),
        )
        from rest_framework import serializers as drf_serializers

        with self.assertRaises(drf_serializers.ValidationError):
            receive_finished_goods(job, request=None)
        # Nothing produced, nothing stamped.
        job.refresh_from_db()
        self.assertIsNone(job.output_received_at)
