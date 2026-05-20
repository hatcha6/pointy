from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.models import Product
from apps.core.models import ShopSettings
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.discounts.models import DiscountRule
from apps.inventory.models import StockItem
from apps.payments.models import Payment
from apps.sales.models import Order
from .models import PrintAgent, PrintJob, PrintJobEvent, PrintTemplate, PrintTemplateVersion
from .services import enqueue_receipt_print_job, publish_template_version


class PrintingTestMixin:
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.cashier = User.objects.create_user(username="printing-cashier", password="pass")
        self.manager = User.objects.create_user(username="printing-manager", password="pass")
        self.unassigned = User.objects.create_user(username="printing-unassigned", password="pass")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))

        self.cashier_client = APIClient()
        self.cashier_client.force_authenticate(user=self.cashier)
        self.manager_client = APIClient()
        self.manager_client.force_authenticate(user=self.manager)
        self.unassigned_client = APIClient()
        self.unassigned_client.force_authenticate(user=self.unassigned)

    def create_published_template_version(self):
        template = PrintTemplate.objects.create(slug="receipt-test", name="Receipt test")
        version = PrintTemplateVersion.objects.create(
            template=template,
            version_number=1,
            content="{{ receipt }}",
            schema={"kind": "receipt"},
        )
        return publish_template_version(version)

    def create_job(self):
        return PrintJob.objects.create(
            job_type=PrintJob.Type.RECEIPT,
            template_version=self.create_published_template_version(),
            payload={"order": {"receipt_number": "R-TEST"}},
            idempotency_key="manual:test",
        )


class ReceiptAutoPrintTests(PrintingTestMixin, TestCase):
    def setUp(self):
        super().setUp()
        ShopSettings.load()
        ShopSettings.objects.filter(pk=1).update(
            shop_name="متجر الاختبار",
            receipt_header="أهلا",
            receipt_footer="شكرا",
            auto_print_receipts=True,
        )
        self.product = Product.objects.create(
            sku="AUTO-PRINT",
            name="قهوة مختصة",
            unit_price=Decimal("4.25"),
        )
        StockItem.objects.create(product=self.product, quantity_on_hand=10)
        self.cashier_client.post(
            reverse("register-session-start"),
            {"opening_cash": "0.00"},
            format="json",
        )

    def checkout(self, extra=None):
        payload = {
            "lines": [{"product": self.product.pk, "quantity": 2}],
            "payment_method": Payment.Method.CASH,
            "amount_received": "8.50",
        }
        if extra:
            payload.update(extra)
        with self.captureOnCommitCallbacks(execute=True):
            response = self.cashier_client.post(
                reverse("order-checkout"),
                payload,
                format="json",
            )
        return response

    def print_invoice_payload(self):
        return {
            "print_invoice": {
                "agent_id": "pointy-local-agent",
                "printer_endpoint": {
                    "kind": "serial",
                    "name": "Counter printer",
                    "address": "/dev/tty.usbserial",
                    "baud_rate": 9600,
                },
            }
        }

    def test_auto_print_job_created_after_successful_checkout_payment(self):
        response = self.checkout()

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        job = PrintJob.objects.get()
        self.assertEqual(job.status, PrintJob.Status.QUEUED)
        self.assertEqual(job.order_id, response.data["id"])
        self.assertEqual(job.job_type, PrintJob.Type.RECEIPT)
        self.assertEqual(job.idempotency_key, f"receipt:{response.data['id']}")
        self.assertEqual(job.events.get().event_type, PrintJobEvent.Type.CREATED)

    def test_auto_print_job_not_created_when_shop_setting_is_disabled(self):
        ShopSettings.objects.filter(pk=1).update(auto_print_receipts=False)

        response = self.checkout()

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(PrintJob.objects.count(), 0)

    def test_receipt_job_is_idempotent_for_same_order(self):
        response = self.checkout()
        order = Order.objects.get(pk=response.data["id"])

        first = PrintJob.objects.get()
        second = enqueue_receipt_print_job(order.pk)

        self.assertEqual(second.pk, first.pk)
        self.assertEqual(PrintJob.objects.count(), 1)
        self.assertEqual(PrintJobEvent.objects.count(), 1)

    def test_receipt_job_payload_is_a_snapshot(self):
        response = self.checkout()
        job = PrintJob.objects.get(order_id=response.data["id"])

        self.product.name = "اسم جديد"
        self.product.unit_price = Decimal("99.00")
        self.product.save(update_fields=["name", "unit_price", "updated_at"])
        ShopSettings.objects.filter(pk=1).update(shop_name="متجر جديد")

        self.assertEqual(job.payload["shop"]["name"], "متجر الاختبار")
        self.assertEqual(job.payload["order"]["receipt_number"], response.data["receipt_number"])
        self.assertEqual(job.payload["order"]["total"], "8.50")
        self.assertEqual(job.payload["order"]["lines"][0]["name"], "قهوة مختصة")
        self.assertEqual(job.payload["order"]["lines"][0]["unit_price"], "4.25")

    def test_receipt_job_payload_includes_discount_values(self):
        DiscountRule.objects.create(
            name="Receipt discount",
            channel=DiscountRule.Channel.SALES,
            value_type=DiscountRule.ValueType.PERCENTAGE,
            value=Decimal("10.00"),
        )

        response = self.checkout({"amount_received": "7.65"})

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        job = PrintJob.objects.get(order_id=response.data["id"])
        self.assertEqual(job.payload["order"]["subtotal"], "8.50")
        self.assertEqual(job.payload["order"]["discount_total"], "0.85")
        self.assertEqual(job.payload["order"]["total"], "7.65")
        self.assertEqual(
            job.payload["order"]["applied_discounts"][0]["rule_name"],
            "Receipt discount",
        )
        self.assertEqual(job.payload["order"]["lines"][0]["line_subtotal"], "8.50")
        self.assertEqual(job.payload["order"]["lines"][0]["discount_total"], "0.85")
        self.assertEqual(job.payload["order"]["lines"][0]["line_total"], "7.65")

    def test_checkout_can_return_claimed_auto_print_job(self):
        response = self.checkout(self.print_invoice_payload())

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertIn("print_job", response.data)
        self.assertEqual(response.data["print_job"]["status"], PrintJob.Status.CLAIMED)
        self.assertEqual(response.data["print_job"]["order"], response.data["id"])
        self.assertEqual(PrintJob.objects.get().attempts, 1)
        self.assertTrue(
            PrintAgent.objects.filter(identifier="pointy-local-agent").exists()
        )

    def test_checkout_can_return_claimed_manual_print_job_when_auto_print_is_disabled(self):
        ShopSettings.objects.filter(pk=1).update(auto_print_receipts=False)

        response = self.checkout(self.print_invoice_payload())

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertIn("print_job", response.data)
        self.assertEqual(response.data["print_job"]["status"], PrintJob.Status.CLAIMED)
        self.assertEqual(response.data["print_job"]["order"], response.data["id"])
        self.assertTrue(
            response.data["print_job"]["idempotency_key"].startswith("receipt-reprint:")
        )


class TemplateVersionApiTests(PrintingTestMixin, TestCase):
    def test_template_versions_are_numbered_and_publish_updates_current_version(self):
        template_response = self.manager_client.post(
            reverse("printtemplate-list"),
            {"slug": "receipt-api", "name": "Receipt API", "template_type": "receipt"},
            format="json",
        )
        first_response = self.manager_client.post(
            reverse("printtemplateversion-list"),
            {
                "template": template_response.data["id"],
                "content": "first",
                "schema": {"fields": ["total"]},
            },
            format="json",
        )
        first_publish_response = self.manager_client.post(
            reverse("printtemplateversion-publish", args=[first_response.data["id"]]),
            format="json",
        )
        second_response = self.manager_client.post(
            reverse("printtemplateversion-list"),
            {
                "template": template_response.data["id"],
                "content": "second",
                "schema": {"fields": ["total", "lines"]},
            },
            format="json",
        )
        second_publish_response = self.manager_client.post(
            reverse("printtemplateversion-publish", args=[second_response.data["id"]]),
            format="json",
        )
        patch_response = self.manager_client.patch(
            reverse("printtemplateversion-detail", args=[first_response.data["id"]]),
            {"content": "changed"},
            format="json",
        )

        self.assertEqual(template_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(first_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(first_response.data["version_number"], 1)
        self.assertEqual(
            first_publish_response.data["status"],
            PrintTemplateVersion.Status.PUBLISHED,
        )
        self.assertEqual(second_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(second_response.data["version_number"], 2)
        self.assertEqual(second_publish_response.status_code, status.HTTP_200_OK)
        self.assertEqual(patch_response.status_code, status.HTTP_405_METHOD_NOT_ALLOWED)

        template = PrintTemplate.objects.get(pk=template_response.data["id"])
        self.assertEqual(template.current_version_id, second_response.data["id"])


class PrintJobAgentApiTests(PrintingTestMixin, TestCase):
    def test_agent_can_claim_and_report_printed_with_audit_events(self):
        job = self.create_job()
        agent = PrintAgent.objects.create(name="Counter agent", identifier="counter-agent")

        claim_response = self.cashier_client.post(
            reverse("printjob-claim-next"),
            {"agent": agent.pk},
            format="json",
        )
        printed_response = self.cashier_client.post(
            reverse("printjob-printed", args=[job.pk]),
            {"agent": agent.pk},
            format="json",
        )
        events_response = self.cashier_client.get(reverse("printjob-events", args=[job.pk]))

        self.assertEqual(claim_response.status_code, status.HTTP_200_OK)
        self.assertEqual(claim_response.data["id"], job.pk)
        self.assertEqual(claim_response.data["status"], PrintJob.Status.CLAIMED)
        self.assertEqual(claim_response.data["attempts"], 1)
        self.assertEqual(printed_response.status_code, status.HTTP_200_OK)
        self.assertEqual(printed_response.data["status"], PrintJob.Status.PRINTED)
        self.assertEqual(events_response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            [event["event_type"] for event in events_response.data["results"]],
            [PrintJobEvent.Type.CLAIMED, PrintJobEvent.Type.PRINTED],
        )

        job.refresh_from_db()
        self.assertEqual(job.claimed_by_id, agent.pk)
        self.assertIsNotNone(job.printed_at)

    def test_agent_can_report_failed_and_requeue_job(self):
        job = self.create_job()
        agent = PrintAgent.objects.create(name="Back agent", identifier="back-agent")
        self.cashier_client.post(
            reverse("printjob-claim-next"),
            {"agent": agent.pk},
            format="json",
        )

        failed_response = self.cashier_client.post(
            reverse("printjob-failed", args=[job.pk]),
            {"agent": agent.pk, "error_message": "Paper empty"},
            format="json",
        )
        requeue_response = self.cashier_client.post(
            reverse("printjob-requeue", args=[job.pk]),
            format="json",
        )

        self.assertEqual(failed_response.status_code, status.HTTP_200_OK)
        self.assertEqual(failed_response.data["status"], PrintJob.Status.FAILED)
        self.assertEqual(failed_response.data["error_message"], "Paper empty")
        self.assertEqual(requeue_response.status_code, status.HTTP_200_OK)
        self.assertEqual(requeue_response.data["status"], PrintJob.Status.QUEUED)
        self.assertEqual(
            list(PrintJobEvent.objects.filter(job=job).values_list("event_type", flat=True)),
            [
                PrintJobEvent.Type.CLAIMED,
                PrintJobEvent.Type.FAILED,
                PrintJobEvent.Type.REQUEUED,
            ],
        )

    def test_frontend_agent_contract_can_claim_and_report_with_identifier(self):
        job = self.create_job()

        claim_response = self.cashier_client.post(
            reverse("printjob-claim-next"),
            {
                "agent_id": "pointy-local-agent",
                "printer_endpoint": {
                    "kind": "serial",
                    "name": "Counter printer",
                    "address": "/dev/tty.usbserial",
                    "baud_rate": 9600,
                },
            },
            format="json",
        )
        report_response = self.cashier_client.post(
            reverse("printjob-report", args=[job.pk]),
            {"agent_id": "pointy-local-agent", "status": "completed"},
            format="json",
        )

        self.assertEqual(claim_response.status_code, status.HTTP_200_OK)
        self.assertEqual(report_response.status_code, status.HTTP_200_OK)
        self.assertEqual(report_response.data["status"], PrintJob.Status.PRINTED)
        self.assertTrue(
            PrintAgent.objects.filter(identifier="pointy-local-agent").exists()
        )

    def test_order_reprint_endpoint_queues_manual_receipt_job(self):
        ShopSettings.load()
        product = Product.objects.create(
            sku="REPRINT",
            name="قهوة",
            unit_price=Decimal("3.00"),
        )
        StockItem.objects.create(product=product, quantity_on_hand=5)
        self.cashier_client.post(
            reverse("register-session-start"),
            {"opening_cash": "0.00"},
            format="json",
        )
        checkout_response = self.cashier_client.post(
            reverse("order-checkout"),
            {"lines": [{"product": product.pk, "quantity": 1}]},
            format="json",
        )

        reprint_response = self.cashier_client.post(
            reverse("order-reprint", args=[checkout_response.data["id"]]),
            format="json",
        )

        self.assertEqual(checkout_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(reprint_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(reprint_response.data["order"], checkout_response.data["id"])
        self.assertTrue(
            reprint_response.data["idempotency_key"].startswith("receipt-reprint:")
        )


class PrintingPermissionTests(PrintingTestMixin, TestCase):
    def test_cashier_can_operate_jobs_but_cannot_manage_templates(self):
        job = self.create_job()
        agent = PrintAgent.objects.create(name="Permission agent", identifier="permission-agent")

        template_response = self.cashier_client.post(
            reverse("printtemplate-list"),
            {"slug": "blocked", "name": "Blocked"},
            format="json",
        )
        claim_response = self.cashier_client.post(
            reverse("printjob-claim-next"),
            {"agent": agent.pk},
            format="json",
        )
        job_response = self.cashier_client.get(reverse("printjob-detail", args=[job.pk]))

        self.assertEqual(template_response.status_code, status.HTTP_403_FORBIDDEN)
        self.assertEqual(claim_response.status_code, status.HTTP_200_OK)
        self.assertEqual(job_response.status_code, status.HTTP_200_OK)

    def test_unassigned_user_cannot_access_printing_jobs(self):
        job = self.create_job()

        list_response = self.unassigned_client.get(reverse("printjob-list"))
        detail_response = self.unassigned_client.get(reverse("printjob-detail", args=[job.pk]))

        self.assertEqual(list_response.status_code, status.HTTP_403_FORBIDDEN)
        self.assertEqual(detail_response.status_code, status.HTTP_403_FORBIDDEN)

    def test_cashier_role_has_print_job_permissions_but_not_template_permissions(self):
        self.assertTrue(self.cashier.has_perm("printing.view_printjob"))
        self.assertTrue(self.cashier.has_perm("printing.change_printjob"))
        self.assertFalse(self.cashier.has_perm("printing.add_printtemplate"))
        self.assertTrue(self.manager.has_perm("printing.add_printtemplate"))
