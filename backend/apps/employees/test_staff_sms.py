"""Paying the wages texts each employee with a phone their net pay — when the
shop has that text switched on, and once per payslip."""

from datetime import date, timedelta
from decimal import Decimal

from django.test import TestCase

from apps.core.models import ShopSettings
from apps.messaging.models import MessagingGateway, OutboundMessage

from .models import CompensationPlan, Employee, PayrollLine, PayrollRun
from .staff_sms import notify_payroll_paid


class PayrollPaidTextTests(TestCase):
    def setUp(self):
        settings = ShopSettings.load()
        settings.shop_name = "محل النور"
        settings.save()
        self.gateway = MessagingGateway.objects.create(
            name="phone", provider=MessagingGateway.Provider.FAKE, is_default=True,
            auto_messages={"payroll_paid": True},
        )
        self.run = PayrollRun.objects.create(
            period_start=date(2026, 9, 1), period_end=date(2026, 9, 30), status=PayrollRun.Status.PAID
        )
        for number, phone, net in (("E1", "0912345678", "1450.00"), ("E2", "", "900.00"), ("E3", "0923456789", "0.00")):
            employee = Employee.objects.create(
                employee_number=number, full_name=f"موظف {number}", job_title="بائع",
                hire_date=date(2025, 1, 1), phone=phone,
            )
            plan = CompensationPlan.objects.create(
                employee=employee, pay_type=CompensationPlan.PayType.MONTHLY_SALARY,
                amount=Decimal("1500.00"), effective_from=date(2026, 9, 1) - timedelta(days=30), is_active=True,
            )
            PayrollLine.objects.create(
                payroll_run=self.run, employee=employee, compensation_plan=plan,
                gross_amount=Decimal("1500.00"), net_amount=Decimal(net),
            )

    def test_each_employee_with_a_phone_hears_their_net_pay_once(self):
        with self.captureOnCommitCallbacks(execute=True):
            notify_payroll_paid(self.run)
            notify_payroll_paid(self.run)
        [text] = OutboundMessage.objects.filter(template_kind="payroll_paid")
        self.assertEqual(text.body, "محل النور: صُرف راتبكم عن 2026/09، والصافي 1450.00 د.ل.")

    def test_off_by_default(self):
        self.gateway.auto_messages = {}
        self.gateway.save(update_fields=["auto_messages"])
        with self.captureOnCommitCallbacks(execute=True):
            notify_payroll_paid(self.run)
        self.assertFalse(OutboundMessage.objects.exists())
