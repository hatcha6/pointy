"""The texts that go out when money moves for a customer — a credit sale, a
payment, a return, a new due date — and the ones a cashier sends by hand: a
quotation (worded as an offer, never as a "thank you for shopping"), and the
balance on the account. Each automatic text follows its switch on the SMS
settings page."""

from __future__ import annotations

from decimal import Decimal
from unittest import mock

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase, override_settings
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.testing import create_product_with_default_variant
from apps.core.models import ShopSettings
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.customers.models import Customer
from apps.inventory.models import StockItem
from apps.messaging.automation import auto_sms_enabled
from apps.messaging.models import MessagingGateway, OutboundMessage
from apps.sales.models import Order

from .tasks import debt_reminder_sweep_task
from .transactional import NothingOwed, send_account_balance_sms, send_invoice_sms

_PUBLIC_URL = "apps.crm.transactional.public_invoice_url_for_order"


class MoneyTextTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        settings = ShopSettings.load()
        settings.shop_name = "محل النور"
        settings.save()
        self.gateway = MessagingGateway.objects.create(
            name="phone", provider=MessagingGateway.Provider.FAKE, is_default=True
        )
        self.client = APIClient()
        user = get_user_model().objects.create_user(username="money-manager", password="pass")
        user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=user)
        product = create_product_with_default_variant(
            sku="GADGET", barcode="", name="Gadget", unit_price=Decimal("50.00")
        )
        self.variant = product.default_variant
        StockItem.objects.create(variant=self.variant, quantity_on_hand=20)
        self.customer = Customer.objects.create(full_name="علي", phone="0912345678")
        self.client.post(reverse("register-session-start"), {"opening_cash": "0.00"}, format="json")

    def switch(self, **kinds):
        self.gateway.auto_messages = {**self.gateway.auto_messages, **kinds}
        self.gateway.save(update_fields=["auto_messages"])

    def texts(self, kind):
        return list(OutboundMessage.objects.filter(template_kind=kind).order_by("pk"))

    def checkout(self, **overrides):
        payload = {"lines": [{"variant": self.variant.pk, "quantity": 2}], "customer": self.customer.pk}
        payload.update(overrides)
        with self.captureOnCommitCallbacks(execute=True):
            response = self.client.post(reverse("order-checkout"), payload, format="json")
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        return Order.objects.get(pk=response.data["id"])

    def test_a_credit_sale_tells_the_customer_what_they_owe(self):
        order = self.checkout(sale_type="credit", amount_received="30.00", due_date="2026-10-15")
        [text] = self.texts("credit_invoice")
        self.assertEqual(
            text.body,
            f"محل النور: عليكم 70.00 د.ل من الفاتورة {order.receipt_number}، تستحق في 2026/10/15.",
        )
        # A real receipt number is fifteen characters: two SMS, as the
        # settings page's example says.
        self.assertEqual(text.segments, 2)

    def test_a_credit_sale_says_when_it_falls_due_or_that_it_does_not(self):
        order = self.checkout(sale_type="credit")
        [text] = self.texts("credit_invoice")
        if order.due_date is None:
            self.assertTrue(text.body.endswith("دون موعد استحقاق."))
        else:
            self.assertTrue(text.body.endswith(f"تستحق في {order.due_date:%Y/%m/%d}."))

    def test_a_cash_sale_sends_nothing_and_a_switched_off_credit_sale_neither(self):
        self.checkout(payment_method="cash", amount_received="100.00")
        self.switch(credit_invoice=False)
        self.checkout(sale_type="credit")
        self.assertEqual(self.texts("credit_invoice"), [])

    def test_a_payment_on_an_invoice_is_receipted_with_the_account_balance(self):
        first = self.checkout(sale_type="credit")
        self.checkout(sale_type="credit")
        with self.captureOnCommitCallbacks(execute=True):
            response = self.client.post(
                reverse("order-record-payment", args=[first.pk]),
                {"method": "cash", "amount": "40.00"},
                format="json",
            )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        [text] = self.texts("payment_received")
        # 200 owed on two invoices, 40 paid: 160 left on the account.
        self.assertEqual(text.body, "محل النور: استلمنا منكم 40.00 د.ل، والمتبقي على حسابكم 160.00 د.ل.")

    def test_an_account_collection_is_one_receipt_however_many_invoices_it_settles(self):
        self.checkout(sale_type="credit")
        self.checkout(sale_type="credit")
        with self.captureOnCommitCallbacks(execute=True):
            response = self.client.post(
                reverse("customer-record-payment", args=[self.customer.pk]),
                {"method": "cash", "amount": "150.00"},
                format="json",
            )
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        [text] = self.texts("payment_received")
        self.assertEqual(text.body, "محل النور: استلمنا منكم 150.00 د.ل، والمتبقي على حسابكم 50.00 د.ل.")

    def test_a_new_due_date_and_a_return_follow_their_switches(self):
        order = self.checkout(sale_type="credit")
        with self.captureOnCommitCallbacks(execute=True):
            self.client.post(reverse("order-due-date", args=[order.pk]), {"due_date": "2026-11-01"}, format="json")
        self.assertEqual(self.texts("due_date_changed"), [])
        self.switch(due_date_changed=True, refund_issued=True)
        with self.captureOnCommitCallbacks(execute=True):
            response = self.client.post(
                reverse("order-due-date", args=[order.pk]), {"due_date": "2026-11-15"}, format="json"
            )
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        [moved] = self.texts("due_date_changed")
        self.assertEqual(
            moved.body, f"محل النور: استحقاق فاتورتكم {order.receipt_number} أصبح 2026/11/15، المتبقي 100.00 د.ل."
        )
        # A return on a paid sale reaches the customer's phone too.
        paid = self.checkout(payment_method="cash", amount_received="100.00")
        line = paid.lines.get()
        with self.captureOnCommitCallbacks(execute=True):
            response = self.client.post(
                reverse("order-return-items", args=[paid.pk]),
                {"lines": [{"line": line.pk, "quantity": 1}], "reason": "عيب"},
                format="json",
            )
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        [returned] = self.texts("refund_issued")
        self.assertEqual(
            returned.body, f"محل النور: سُجّل مرتجع بقيمة 50.00 د.ل على فاتورتكم رقم {paid.receipt_number}."
        )

    def test_a_quotation_goes_out_as_an_offer(self):
        quote = self.checkout(sale_type="quotation", valid_until="2026-10-20")
        message = send_invoice_sms(quote)
        self.assertEqual(message.template_kind, "quotation")
        self.assertEqual(
            message.body, f"محل النور: عرض السعر {quote.receipt_number} بقيمة 100.00 د.ل، ساري حتى 2026/10/20."
        )
        with mock.patch(_PUBLIC_URL, return_value="https://relay.example/invoices/x/y"):
            OutboundMessage.objects.all().delete()
            linked = send_invoice_sms(quote)
        self.assertEqual(linked.template_kind, "quotation_link")
        self.assertTrue(linked.body.endswith("لعرضه: https://relay.example/invoices/x/y"))

    def test_the_balance_by_hand(self):
        self.checkout(sale_type="credit")
        response = self.client.post(reverse("crm-send-balance-sms", args=[self.customer.pk]))
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        self.assertIn("المستحق على حسابكم حتى", response.data["body"])
        self.assertIn("100.00 د.ل", response.data["body"])
        # Nothing owed: nothing to text.
        stranger = Customer.objects.create(full_name="سالم", phone="0923456789")
        with self.assertRaises(NothingOwed):
            send_account_balance_sms(stranger)
        response = self.client.post(reverse("crm-send-balance-sms", args=[stranger.pk]))
        self.assertEqual(response.data["code"], "nothing_owed")

    def test_the_debt_sweep_follows_its_switch(self):
        self.assertFalse(auto_sms_enabled("debt_reminder"))
        self.assertEqual(debt_reminder_sweep_task(), {"skipped": "disabled"})
        self.switch(debt_reminder=True)
        self.assertNotEqual(debt_reminder_sweep_task(), {"skipped": "disabled"})

    @override_settings(POINTY_SMS_DEBT_REMINDERS_ENABLED=True)
    def test_the_old_server_setting_is_only_where_the_switch_starts(self):
        self.assertTrue(auto_sms_enabled("debt_reminder"))
        self.switch(debt_reminder=False)
        self.assertFalse(auto_sms_enabled("debt_reminder"))
