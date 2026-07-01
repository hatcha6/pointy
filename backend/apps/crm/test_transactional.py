from __future__ import annotations

from datetime import timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase, override_settings
from django.utils import timezone
from rest_framework.test import APIClient

from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.core.timeutils import business_local_date
from apps.customers.models import Customer
from apps.messaging.models import MessagingGateway, OutboundMessage
from apps.messaging.transports import fake
from apps.sales.models import Order

from .tasks import debt_reminder_sweep_task
from .transactional import NoRecipientPhone, send_debt_reminder, send_invoice_sms

_TRANSACTIONAL = OutboundMessage.ConsentClass.TRANSACTIONAL


def make_gateway():
    return MessagingGateway.objects.create(
        name="phone", provider=MessagingGateway.Provider.FAKE, is_default=True
    )


def make_credit_order(customer, total="100", valid_until=None):
    order = Order.objects.create(
        customer=customer,
        sale_type=Order.SaleType.CREDIT,
        status=Order.Status.OPEN,
        valid_until=valid_until,
    )
    # Pin the total directly so Order.save() can't recompute it from (absent) lines.
    Order.objects.filter(pk=order.pk).update(total=Decimal(total))
    order.refresh_from_db()
    return order


class InvoiceSmsTests(TestCase):
    def setUp(self):
        fake.reset()
        self.gateway = make_gateway()
        self.customer = Customer.objects.create(full_name="علي", phone="+218912345678")
        self.order = make_credit_order(self.customer)

    def test_queues_transactional_invoice(self):
        message = send_invoice_sms(self.order)
        self.assertEqual(message.consent_class, _TRANSACTIONAL)
        self.assertEqual(message.source_type, "invoice")
        self.assertEqual(message.dedup_key, f"invoice:{self.order.id}")
        self.assertIn(self.order.receipt_number, message.body)

    def test_idempotent_per_order(self):
        first = send_invoice_sms(self.order)
        second = send_invoice_sms(self.order)
        self.assertEqual(first.pk, second.pk)
        self.assertEqual(OutboundMessage.objects.count(), 1)

    def test_no_phone_raises(self):
        order = make_credit_order(Customer.objects.create(full_name="بلا هاتف", phone=""))
        with self.assertRaises(NoRecipientPhone):
            send_invoice_sms(order)


class DebtReminderTests(TestCase):
    def setUp(self):
        fake.reset()
        self.gateway = make_gateway()

    def test_reminder_queued_for_outstanding_credit(self):
        customer = Customer.objects.create(full_name="علي", phone="+218912345678")
        message = send_debt_reminder(make_credit_order(customer, total="250"))
        self.assertIsNotNone(message)
        self.assertEqual(message.consent_class, _TRANSACTIONAL)
        self.assertEqual(message.source_type, "debt_reminder")

    def test_no_reminder_when_nothing_owed(self):
        customer = Customer.objects.create(full_name="علي", phone="+218912345678")
        self.assertIsNone(send_debt_reminder(make_credit_order(customer, total="0")))

    def test_opted_out_customer_still_gets_transactional_reminder(self):
        customer = Customer.objects.create(
            full_name="علي",
            phone="+218912345678",
            marketing_opted_out_at=timezone.now(),
        )
        self.assertIsNotNone(send_debt_reminder(make_credit_order(customer)))

    def test_reminder_includes_due_date_when_set(self):
        due = business_local_date()
        customer = Customer.objects.create(full_name="علي", phone="+218912345678")
        message = send_debt_reminder(
            make_credit_order(customer, valid_until=due)
        )
        self.assertIn(due.strftime("%Y-%m-%d"), message.body)
        self.assertIn("تاريخ الاستحقاق", message.body)

    def test_reminder_omits_due_date_when_unset(self):
        customer = Customer.objects.create(full_name="علي", phone="+218912345678")
        message = send_debt_reminder(make_credit_order(customer))
        self.assertNotIn("تاريخ الاستحقاق", message.body)


class DebtSweepTests(TestCase):
    def setUp(self):
        fake.reset()
        self.gateway = make_gateway()

    def test_disabled_by_default(self):
        self.assertEqual(debt_reminder_sweep_task(), {"skipped": "disabled"})

    @override_settings(POINTY_SMS_DEBT_REMINDERS_ENABLED=True)
    def test_sweep_sends_and_excludes_do_not_contact_and_no_phone(self):
        payable = Customer.objects.create(full_name="A", phone="+218912345670")
        do_not_contact = Customer.objects.create(
            full_name="B", phone="+218912345671", do_not_contact=True
        )
        no_phone = Customer.objects.create(full_name="C", phone="")
        for customer in (payable, do_not_contact, no_phone):
            make_credit_order(customer)

        result = debt_reminder_sweep_task()
        self.assertEqual(result["sent"], 1)
        self.assertEqual(
            OutboundMessage.objects.filter(source_type="debt_reminder").count(), 1
        )

    @override_settings(POINTY_SMS_DEBT_REMINDERS_ENABLED=True)
    def test_sweep_reminds_due_and_undated_but_holds_future(self):
        today = business_local_date()
        due = Customer.objects.create(full_name="Due", phone="+218912345670")
        overdue = Customer.objects.create(full_name="Overdue", phone="+218912345671")
        future = Customer.objects.create(full_name="Future", phone="+218912345672")
        undated = Customer.objects.create(full_name="Undated", phone="+218912345673")
        make_credit_order(due, valid_until=today)
        make_credit_order(overdue, valid_until=today - timedelta(days=3))
        make_credit_order(future, valid_until=today + timedelta(days=3))
        make_credit_order(undated)  # no due date → due now

        result = debt_reminder_sweep_task()
        # Due-today + overdue + undated all remind; the future one is held back.
        self.assertEqual(result["sent"], 3)
        self.assertEqual(
            OutboundMessage.objects.filter(source_type="debt_reminder").count(), 3
        )

    @override_settings(POINTY_SMS_DEBT_REMINDERS_ENABLED=True)
    def test_sweep_is_idempotent_per_day(self):
        customer = Customer.objects.create(full_name="A", phone="+218912345670")
        make_credit_order(customer)
        debt_reminder_sweep_task()
        debt_reminder_sweep_task()
        self.assertEqual(
            OutboundMessage.objects.filter(source_type="debt_reminder").count(), 1
        )


class SendInvoiceApiTests(TestCase):
    def setUp(self):
        fake.reset()
        self.gateway = make_gateway()
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="mgr", password="x")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.cashier = User.objects.create_user(username="csh", password="x")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.outsider = User.objects.create_user(username="out", password="x")
        self.customer = Customer.objects.create(full_name="علي", phone="+218912345678")
        self.order = make_credit_order(self.customer)
        self.client = APIClient()

    def _url(self, order=None):
        return f"/api/crm/orders/{(order or self.order).id}/send-invoice-sms/"

    def test_cashier_can_send_invoice(self):
        self.client.force_authenticate(self.cashier)
        resp = self.client.post(self._url())
        self.assertEqual(resp.status_code, 201, resp.content)
        self.assertEqual(resp.data["source_type"], "invoice")

    def test_no_phone_is_400(self):
        order = make_credit_order(Customer.objects.create(full_name="B", phone=""))
        self.client.force_authenticate(self.manager)
        self.assertEqual(self.client.post(self._url(order)).status_code, 400)

    def test_outsider_forbidden(self):
        self.client.force_authenticate(self.outsider)
        self.assertEqual(self.client.post(self._url()).status_code, 403)
