from datetime import timedelta
from decimal import Decimal
from unittest import mock

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.contrib.contenttypes.models import ContentType
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient

from apps.attachments.models import Attachment, StorageVolume
from apps.catalog.models import ProductCategory, ProductVariant
from apps.catalog.testing import create_product_with_default_variant
from apps.core.models import RelayInstallation, ShopSettings
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.discounts.models import DiscountRule
from apps.inventory.models import StockItem
from apps.payments.models import Payment
from apps.purchasing.models import PurchaseOrder, Supplier
from apps.sales.models import Order, OrderLine
from .models import (
    PrepStation,
    PrinterProfile,
    PrintAgent,
    PrintAuditEvent,
    PrintJob,
    PrintJobEvent,
    PrintTemplate,
    PrintTemplateVersion,
)
from .services import (
    build_kitchen_ticket_payload,
    claim_next_print_job,
    enqueue_kitchen_print_jobs,
    enqueue_manual_receipt_reprint,
    enqueue_receipt_print_job,
    kitchen_prepared_lines,
    publish_template_version,
    resolve_prep_stations_for_order,
)


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

    def create_paid_sale_order(self):
        ShopSettings.load()
        product = create_product_with_default_variant(
            sku=f"PRINT-{ProductVariant.objects.count() + 1}",
            name="قهوة",
            unit_price=Decimal("3.00"),
        )
        variant = product.default_variant
        StockItem.objects.create(variant=variant, quantity_on_hand=5)
        self.cashier_client.post(
            reverse("register-session-start"),
            {"opening_cash": "0.00"},
            format="json",
        )
        response = self.cashier_client.post(
            reverse("order-checkout"),
            {"lines": [{"variant": variant.pk, "quantity": 1}]},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        return Order.objects.get(pk=response.data["id"])


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
        self.product = create_product_with_default_variant(
            sku="AUTO-PRINT",
            name="قهوة مختصة",
            unit_price=Decimal("4.25"),
        )
        self.variant = self.product.default_variant
        StockItem.objects.create(variant=self.variant, quantity_on_hand=10)
        # The queue only accepts work when something is reading it — see
        # apps.sales.services.create_receipt_print_job. These tests are about
        # what the job contains, so they establish that precondition explicitly
        # rather than relying on it. A shop with no agent creating no rows is
        # covered by apps.printing.test_queue_lifecycle.
        PrintAgent.objects.update_or_create(
            identifier="auto-print-agent",
            defaults={
                "name": "auto-print-agent",
                "is_active": True,
                "last_seen_at": timezone.now(),
            },
        )
        self.cashier_client.post(
            reverse("register-session-start"),
            {"opening_cash": "0.00"},
            format="json",
        )

    def checkout(self, extra=None):
        payload = {
            "lines": [{"variant": self.variant.pk, "quantity": 2}],
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

    def test_auto_print_job_persisted_in_sale_transaction_not_post_commit(self):
        # No captureOnCommitCallbacks wrapper: the job must already exist once
        # the checkout response returns, proving it is written inside the sale
        # transaction and does not depend on a post-commit hook (or Redis).
        payload = {
            "lines": [{"variant": self.variant.pk, "quantity": 2}],
            "payment_method": Payment.Method.CASH,
            "amount_received": "8.50",
        }
        response = self.cashier_client.post(
            reverse("order-checkout"),
            payload,
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        job = PrintJob.objects.get()
        self.assertEqual(job.order_id, response.data["id"])
        self.assertEqual(job.status, PrintJob.Status.QUEUED)

    def test_sale_still_completes_when_receipt_job_creation_fails(self):
        # A printing misconfiguration must never roll back a paid sale.
        with mock.patch(
            "apps.printing.services.enqueue_receipt_print_job",
            side_effect=RuntimeError("template exploded"),
        ):
            response = self.checkout()

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        order = Order.objects.get(pk=response.data["id"])
        self.assertEqual(order.status, Order.Status.PAID)
        self.assertEqual(order.payments.count(), 1)
        # The sale committed even though the receipt job could not be created.
        self.assertEqual(PrintJob.objects.count(), 0)

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
        self.product.save(update_fields=["name", "updated_at"])
        self.variant.unit_price = Decimal("99.00")
        self.variant.save(update_fields=["unit_price", "updated_at"])
        ShopSettings.objects.filter(pk=1).update(shop_name="متجر جديد")

        self.assertEqual(job.payload["shop"]["name"], "متجر الاختبار")
        self.assertEqual(job.payload["order"]["receipt_number"], response.data["receipt_number"])
        self.assertEqual(job.payload["order"]["total"], "8.50")
        self.assertEqual(job.payload["order"]["lines"][0]["name"], "قهوة مختصة")
        self.assertEqual(job.payload["order"]["lines"][0]["unit_price"], "4.25")

    def test_receipt_job_payload_includes_shop_logo_reference(self):
        settings = ShopSettings.load()
        volume = StorageVolume.objects.create(name="test-logo-volume", path="/tmp")
        logo = Attachment.objects.create(
            owner_content_type=ContentType.objects.get_for_model(
                settings,
                for_concrete_model=False,
            ),
            owner_object_id=settings.pk,
            role=Attachment.Role.SHOP_LOGO,
            storage_volume=volume,
            relative_path="logos/logo.png",
            original_filename="logo.png",
            content_type="image/png",
            original_size=12,
            stored_size=12,
            checksum_sha256="a" * 64,
            is_primary=True,
        )

        response = self.checkout()

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        job = PrintJob.objects.get(order_id=response.data["id"])
        self.assertEqual(job.payload["shop"]["logo"]["id"], logo.pk)
        self.assertEqual(job.payload["shop"]["logo"]["content_type"], "image/png")
        self.assertIn(
            reverse("attachment-content", kwargs={"pk": logo.pk}),
            job.payload["shop"]["logo"]["content_url"],
        )
        self.assertIn("token=", job.payload["shop"]["logo"]["content_url"])

    def test_receipt_job_payload_inlines_logo_bytes_when_file_exists(self):
        import base64
        import tempfile
        from pathlib import Path

        settings = ShopSettings.load()
        logo_content = b"\x89PNG-fake-logo-bytes"
        temp_dir = tempfile.mkdtemp()
        Path(temp_dir, "logos").mkdir()
        Path(temp_dir, "logos", "logo.png").write_bytes(logo_content)
        volume = StorageVolume.objects.create(
            name="test-logo-bytes-volume",
            path=temp_dir,
        )
        Attachment.objects.create(
            owner_content_type=ContentType.objects.get_for_model(
                settings,
                for_concrete_model=False,
            ),
            owner_object_id=settings.pk,
            role=Attachment.Role.SHOP_LOGO,
            storage_volume=volume,
            relative_path="logos/logo.png",
            original_filename="logo.png",
            content_type="image/png",
            original_size=len(logo_content),
            stored_size=len(logo_content),
            checksum_sha256="b" * 64,
            is_primary=True,
        )

        response = self.checkout()

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        job = PrintJob.objects.get(order_id=response.data["id"])
        self.assertEqual(
            job.payload["shop"]["logo_bytes"],
            base64.b64encode(logo_content).decode("ascii"),
        )

    def test_receipt_job_payload_includes_variant_line_fields(self):
        variant = ProductVariant.objects.create(
            product=self.product,
            name="كبير",
            sku="AUTO-PRINT-L",
            barcode="998877",
            unit_price=Decimal("5.25"),
        )
        StockItem.objects.create(variant=variant, quantity_on_hand=10)

        response = self.checkout(
            {
                "lines": [{"variant": variant.pk, "quantity": 1}],
                "amount_received": "5.25",
            }
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        job = PrintJob.objects.get(order_id=response.data["id"])
        line = job.payload["order"]["lines"][0]
        self.assertEqual(line["product_id"], self.product.pk)
        self.assertEqual(line["variant_id"], variant.pk)
        self.assertEqual(line["product_name"], "قهوة مختصة - كبير")
        self.assertEqual(line["parent_product_name"], "قهوة مختصة")
        self.assertEqual(line["variant_name"], "كبير")
        self.assertEqual(line["sku"], "AUTO-PRINT-L")
        self.assertEqual(line["barcode"], "998877")
        self.assertEqual(line["unit_price"], "5.25")

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

    def test_receipt_job_payload_includes_public_invoice_url_when_enabled(self):
        ShopSettings.objects.filter(pk=1).update(enable_online_invoices=True)
        RelayInstallation.objects.create(
            installation_id="installation-1",
            shop_name="متجر الاختبار",
            relay_public_api_url="https://relay.example",
            relay_connector_address="relay.example:443",
            connector_token="connector-token",
            access_token="access-token",
            relay_enabled=True,
            subscription_active=True,
        )

        response = self.checkout()

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        order = Order.objects.get(pk=response.data["id"])
        job = PrintJob.objects.get(order_id=order.pk)
        self.assertEqual(
            job.payload["order"]["public_invoice_url"],
            f"https://relay.example/invoices/installation-1/{order.public_token}",
        )

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
        self.assertIsNotNone(claim_response.data["lease_expires_at"])
        self.assertEqual(printed_response.status_code, status.HTTP_200_OK)
        self.assertEqual(printed_response.data["status"], PrintJob.Status.PRINTED)
        self.assertIsNone(printed_response.data["lease_expires_at"])
        self.assertEqual(events_response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            [event["event_type"] for event in events_response.data["results"]],
            [PrintJobEvent.Type.CLAIMED, PrintJobEvent.Type.PRINTED],
        )

        job.refresh_from_db()
        self.assertEqual(job.claimed_by_id, agent.pk)
        self.assertIsNone(job.lease_expires_at)
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
        self.assertIsNone(failed_response.data["lease_expires_at"])
        self.assertEqual(failed_response.data["error_message"], "Paper empty")
        self.assertEqual(requeue_response.status_code, status.HTTP_200_OK)
        self.assertEqual(requeue_response.data["status"], PrintJob.Status.QUEUED)
        self.assertIsNone(requeue_response.data["lease_expires_at"])
        self.assertEqual(
            list(PrintJobEvent.objects.filter(job=job).values_list("event_type", flat=True)),
            [
                PrintJobEvent.Type.CLAIMED,
                PrintJobEvent.Type.FAILED,
                PrintJobEvent.Type.REQUEUED,
            ],
        )

    def test_claim_next_recovers_expired_claim_before_claiming(self):
        job = self.create_job()
        first_agent = PrintAgent.objects.create(
            name="First agent",
            identifier="first-agent",
        )
        second_agent = PrintAgent.objects.create(
            name="Second agent",
            identifier="second-agent",
        )
        claim_response = self.cashier_client.post(
            reverse("printjob-claim-next"),
            {"agent": first_agent.pk},
            format="json",
        )
        self.assertEqual(claim_response.status_code, status.HTTP_200_OK)

        expired_at = timezone.now() - timedelta(minutes=1)
        PrintJob.objects.filter(pk=job.pk).update(lease_expires_at=expired_at)
        recovered_response = self.cashier_client.post(
            reverse("printjob-claim-next"),
            {"agent": second_agent.pk},
            format="json",
        )

        self.assertEqual(recovered_response.status_code, status.HTTP_200_OK)
        self.assertEqual(recovered_response.data["id"], job.pk)
        self.assertEqual(recovered_response.data["status"], PrintJob.Status.CLAIMED)
        self.assertEqual(recovered_response.data["claimed_by"], second_agent.pk)
        self.assertEqual(recovered_response.data["attempts"], 2)
        self.assertIsNotNone(recovered_response.data["lease_expires_at"])
        self.assertEqual(
            list(PrintJobEvent.objects.filter(job=job).values_list("event_type", flat=True)),
            [
                PrintJobEvent.Type.CLAIMED,
                PrintJobEvent.Type.REQUEUED,
                PrintJobEvent.Type.CLAIMED,
            ],
        )
        job.refresh_from_db()
        self.assertEqual(job.claimed_by_id, second_agent.pk)
        self.assertGreater(job.lease_expires_at, timezone.now())

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

    def test_print_job_report_creates_document_audit_event(self):
        order = self.create_paid_sale_order()
        job = PrintJob.objects.create(
            job_type=PrintJob.Type.RECEIPT,
            template_version=self.create_published_template_version(),
            payload={"order": {"receipt_number": order.receipt_number}},
            idempotency_key="manual:audited-sale",
            order=order,
        )

        self.cashier_client.post(
            reverse("printjob-claim-next"),
            {
                "agent_id": "front-counter",
                "printer_endpoint": {
                    "kind": "serial",
                    "name": "Counter printer",
                    "address": "/dev/tty.usbserial",
                },
            },
            format="json",
        )
        report_response = self.cashier_client.post(
            reverse("printjob-report", args=[job.pk]),
            {
                "agent_id": "front-counter",
                "status": "completed",
                "printer_endpoint": {
                    "kind": "serial",
                    "name": "Counter printer",
                    "address": "/dev/tty.usbserial",
                },
            },
            format="json",
        )

        self.assertEqual(report_response.status_code, status.HTTP_200_OK)
        audit_event = PrintAuditEvent.objects.get(print_job=job)
        self.assertEqual(audit_event.document_type, PrintAuditEvent.DocumentType.SALE_ORDER)
        self.assertEqual(audit_event.action, PrintAuditEvent.Action.PRINT)
        self.assertEqual(audit_event.status, PrintAuditEvent.Status.COMPLETED)
        self.assertEqual(audit_event.sale_order, order)
        self.assertEqual(audit_event.document_number, order.receipt_number)
        self.assertEqual(audit_event.user, self.cashier)
        self.assertEqual(audit_event.agent_identifier, "front-counter")
        self.assertEqual(audit_event.printer_name, "Counter printer")

    def test_sale_document_share_can_be_recorded_and_reported(self):
        order = self.create_paid_sale_order()

        record_response = self.cashier_client.post(
            reverse("printauditevent-record"),
            {
                "document_type": PrintAuditEvent.DocumentType.SALE_ORDER,
                "document_id": order.pk,
                "action": PrintAuditEvent.Action.SHARE,
                "agent_id": "cashier-device",
                "printer_endpoint": {
                    "kind": "system",
                    "name": "PDF share",
                    "output_mode": "pdfA4",
                },
                "metadata": {"delivery_channel": "native_share_sheet"},
            },
            format="json",
        )
        report_response = self.cashier_client.post(
            reverse("printauditevent-report", args=[record_response.data["id"]]),
            {
                "status": PrintAuditEvent.Status.COMPLETED,
                "message": "PDF shared.",
            },
            format="json",
        )
        list_response = self.cashier_client.get(
            reverse("printauditevent-list"),
            {
                "document_type": PrintAuditEvent.DocumentType.SALE_ORDER,
                "sale_order": order.pk,
            },
        )

        self.assertEqual(record_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(record_response.data["status"], PrintAuditEvent.Status.REQUESTED)
        self.assertEqual(report_response.status_code, status.HTTP_200_OK)
        self.assertEqual(report_response.data["status"], PrintAuditEvent.Status.COMPLETED)
        self.assertEqual(list_response.status_code, status.HTTP_200_OK)
        self.assertEqual(list_response.data["results"][0]["id"], record_response.data["id"])
        self.assertEqual(PrintAuditEvent.objects.get().user, self.cashier)

    def test_purchase_document_audit_requires_purchase_visibility(self):
        supplier = Supplier.objects.create(name="مورد")
        purchase_order = PurchaseOrder.objects.create(
            supplier=supplier,
            status=PurchaseOrder.Status.RECEIVED,
            total=Decimal("12.00"),
        )

        cashier_response = self.cashier_client.post(
            reverse("printauditevent-record"),
            {
                "document_type": PrintAuditEvent.DocumentType.PURCHASE_ORDER,
                "document_id": purchase_order.pk,
                "action": PrintAuditEvent.Action.PRINT,
                "status": PrintAuditEvent.Status.COMPLETED,
            },
            format="json",
        )
        manager_response = self.manager_client.post(
            reverse("printauditevent-record"),
            {
                "document_type": PrintAuditEvent.DocumentType.PURCHASE_ORDER,
                "document_id": purchase_order.pk,
                "action": PrintAuditEvent.Action.PRINT,
                "status": PrintAuditEvent.Status.COMPLETED,
                "agent_id": "office-device",
            },
            format="json",
        )

        self.assertEqual(cashier_response.status_code, status.HTTP_403_FORBIDDEN)
        self.assertEqual(manager_response.status_code, status.HTTP_201_CREATED)
        audit_event = PrintAuditEvent.objects.get()
        self.assertEqual(
            audit_event.document_type,
            PrintAuditEvent.DocumentType.PURCHASE_ORDER,
        )
        self.assertEqual(audit_event.purchase_order, purchase_order)
        self.assertEqual(audit_event.document_number, purchase_order.order_number)

    def test_order_reprint_endpoint_queues_manual_receipt_job(self):
        ShopSettings.load()
        product = create_product_with_default_variant(
            sku="REPRINT",
            name="قهوة",
            unit_price=Decimal("3.00"),
        )
        variant = product.default_variant
        StockItem.objects.create(variant=variant, quantity_on_hand=5)
        self.cashier_client.post(
            reverse("register-session-start"),
            {"opening_cash": "0.00"},
            format="json",
        )
        checkout_response = self.cashier_client.post(
            reverse("order-checkout"),
            {"lines": [{"variant": variant.pk, "quantity": 1}]},
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


class PrintJobVisibilityTests(PrintingTestMixin, TestCase):
    """A queued print job carries the whole rendered receipt — line items,
    totals, applied discounts, the public-invoice link and the owning session.
    Reading it must therefore be no wider than reading the sale itself, which
    ``OrderViewSet.get_queryset`` limits to the cashier's own register session
    unless they hold shop-wide visibility."""

    def setUp(self):
        super().setUp()
        User = get_user_model()
        self.other_cashier = User.objects.create_user(
            username="printing-other-cashier",
            password="pass",
        )
        self.other_cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.other_cashier_client = APIClient()
        self.other_cashier_client.force_authenticate(user=self.other_cashier)

    def _job_for_another_cashiers_sale(self):
        order = self.create_paid_sale_order()
        return order, enqueue_manual_receipt_reprint(order, user=self.cashier)

    def test_another_cashiers_receipt_job_is_not_listed(self):
        _, job = self._job_for_another_cashiers_sale()

        response = self.other_cashier_client.get(reverse("printjob-list"))

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertNotIn(job.pk, [row["id"] for row in response.data["results"]])

    def test_another_cashiers_receipt_job_cannot_be_retrieved(self):
        _, job = self._job_for_another_cashiers_sale()

        response = self.other_cashier_client.get(
            reverse("printjob-detail", args=[job.pk])
        )

        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)

    def test_another_cashiers_receipt_job_events_are_not_readable(self):
        _, job = self._job_for_another_cashiers_sale()

        response = self.other_cashier_client.get(
            reverse("printjob-events", args=[job.pk])
        )

        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)

    def test_owning_cashier_still_reads_their_own_receipt_job(self):
        _, job = self._job_for_another_cashiers_sale()

        response = self.cashier_client.get(reverse("printjob-detail", args=[job.pk]))

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["payload"]["order"]["id"], job.order_id)

    def test_shop_wide_visibility_still_reads_every_receipt_job(self):
        _, job = self._job_for_another_cashiers_sale()

        response = self.manager_client.get(reverse("printjob-detail", args=[job.pk]))

        self.assertEqual(response.status_code, status.HTTP_200_OK)

    def test_order_less_jobs_stay_visible_to_any_print_operator(self):
        job = self.create_job()

        response = self.other_cashier_client.get(
            reverse("printjob-detail", args=[job.pk])
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)

    def test_agent_lifecycle_still_spans_the_whole_shop_queue(self):
        """A shared receipt printer is driven by one agent, whichever till rang
        the sale — claiming and requeueing stay shop-wide on purpose."""
        _, job = self._job_for_another_cashiers_sale()
        agent = PrintAgent.objects.create(name="Shared", identifier="shared-agent")

        response = self.other_cashier_client.post(
            reverse("printjob-claim", args=[job.pk]),
            {"agent": agent.pk},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)


class KitchenTicketServiceTests(TestCase):
    def setUp(self):
        ShopSettings.load()
        ShopSettings.objects.filter(pk=1).update(auto_print_kitchen_tickets=True)

    def _category(self, name):
        return ProductCategory.objects.create(name=name)

    def _profile(self, name, printer_type=PrinterProfile.Type.ESCPOS):
        return PrinterProfile.objects.create(name=name, printer_type=printer_type)

    def _prepared_variant(self, *, name, sku, categories=()):
        product = create_product_with_default_variant(
            name=name, sku=sku, unit_price=Decimal("5.00")
        )
        product.is_prepared = True
        product.save(update_fields=["is_prepared"])
        for category in categories:
            product.categories.add(category)
        return product.default_variant

    def _retail_variant(self, *, name, sku):
        product = create_product_with_default_variant(
            name=name, sku=sku, unit_price=Decimal("2.00")
        )
        return product.default_variant

    def _station(self, *, name, profile=None, categories=(), is_default=False):
        station = PrepStation.objects.create(
            name=name, printer_profile=profile, is_default=is_default
        )
        for category in categories:
            station.categories.add(category)
        return station

    def _paid_order(self, lines):
        order = Order.objects.create(status=Order.Status.PAID)
        for variant, quantity, notes in lines:
            OrderLine.objects.create(
                order=order,
                variant=variant,
                quantity=Decimal(quantity),
                unit_price=variant.unit_price,
                notes=notes,
            )
        return order

    def test_kitchen_payload_omits_money_and_carries_notes_and_station(self):
        variant = self._prepared_variant(name="برجر", sku="BRG-1")
        station = self._station(name="الشواية")
        order = self._paid_order([(variant, "2", "بدون بصل")])

        payload = build_kitchen_ticket_payload(
            order, station, kitchen_prepared_lines(order)
        )

        self.assertEqual(payload["kind"], "kitchen")
        self.assertEqual(payload["station"]["name"], "الشواية")
        order_payload = payload["order"]
        self.assertNotIn("total", order_payload)
        self.assertNotIn("subtotal", order_payload)
        line = order_payload["lines"][0]
        self.assertEqual(line["quantity"], 2.0)
        self.assertEqual(line["notes"], "بدون بصل")
        self.assertNotIn("unit_price", line)
        self.assertNotIn("line_total", line)

    def test_kitchen_payload_includes_line_modifiers(self):
        from apps.sales.models import OrderLineModifier

        variant = self._prepared_variant(name="برجر", sku="BRG-MOD")
        station = self._station(name="الشواية")
        order = self._paid_order([(variant, "1", "")])
        OrderLineModifier.objects.create(
            order_line=order.lines.get(),
            group_name="إضافات",
            option_name="جبن إضافي",
            unit_price_delta=Decimal("1.00"),
            quantity=2,
        )

        payload = build_kitchen_ticket_payload(
            order, station, kitchen_prepared_lines(order)
        )

        modifiers = payload["order"]["lines"][0]["modifiers"]
        self.assertEqual(len(modifiers), 1)
        self.assertEqual(modifiers[0]["name"], "جبن إضافي")
        self.assertEqual(modifiers[0]["quantity"], 2)

    def test_routing_uses_categories_with_default_catch_all(self):
        food = self._category("طعام")
        drinks = self._category("مشروبات")
        grill = self._station(
            name="الشواية", categories=[food], is_default=True
        )
        bar = self._station(name="البار", categories=[drinks])
        burger = self._prepared_variant(name="برجر", sku="BRG-2", categories=[food])
        juice = self._prepared_variant(name="عصير", sku="JCE-1", categories=[drinks])
        special = self._prepared_variant(name="طبق اليوم", sku="SPC-1")  # uncategorized
        bottle = self._retail_variant(name="ماء", sku="WTR-1")  # not prepared
        order = self._paid_order(
            [
                (burger, "1", ""),
                (juice, "1", ""),
                (special, "1", ""),
                (bottle, "3", ""),
            ]
        )

        routed, prepared = resolve_prep_stations_for_order(order)

        self.assertEqual(len(prepared), 3)  # bottle (retail) excluded
        self.assertEqual(
            {line.variant_id for line in routed[grill]},
            {burger.id, special.id},  # special falls to the default station
        )
        self.assertEqual(
            {line.variant_id for line in routed[bar]}, {juice.id}
        )

    def test_unrouted_prepared_lines_surface_when_no_default_station(self):
        food = self._category("طعام")
        drinks = self._category("مشروبات")
        self._station(name="البار", categories=[drinks])  # not default
        burger = self._prepared_variant(name="برجر", sku="BRG-3", categories=[food])
        order = self._paid_order([(burger, "1", "")])

        routed, prepared = resolve_prep_stations_for_order(order)

        self.assertEqual(len(prepared), 1)
        self.assertEqual(routed, {})  # surfaced via `prepared`, never silently dropped

    def test_enqueue_creates_one_job_per_station_tagged_with_profile(self):
        food = self._category("طعام")
        drinks = self._category("مشروبات")
        grill_profile = self._profile("Grill printer")
        bar_profile = self._profile("Bar printer")
        grill = self._station(
            name="الشواية", profile=grill_profile, categories=[food], is_default=True
        )
        bar = self._station(name="البار", profile=bar_profile, categories=[drinks])
        burger = self._prepared_variant(name="برجر", sku="BRG-4", categories=[food])
        juice = self._prepared_variant(name="عصير", sku="JCE-2", categories=[drinks])
        order = self._paid_order([(burger, "1", ""), (juice, "2", "")])

        jobs = enqueue_kitchen_print_jobs(order.pk)

        self.assertEqual(len(jobs), 2)
        by_station = {job.prep_station_id: job for job in jobs}
        self.assertEqual(by_station[grill.id].printer_profile_id, grill_profile.id)
        self.assertEqual(by_station[grill.id].job_type, PrintJob.Type.KITCHEN)
        self.assertEqual(
            by_station[grill.id].idempotency_key, f"kitchen:{order.pk}:{grill.id}"
        )
        self.assertEqual(by_station[bar.id].printer_profile_id, bar_profile.id)

        again = enqueue_kitchen_print_jobs(order.pk)  # idempotent
        self.assertEqual(len(again), 2)
        self.assertEqual(
            PrintJob.objects.filter(job_type=PrintJob.Type.KITCHEN).count(), 2
        )

    def test_enqueue_noop_when_setting_disabled(self):
        ShopSettings.objects.filter(pk=1).update(auto_print_kitchen_tickets=False)
        food = self._category("طعام")
        self._station(name="الشواية", categories=[food], is_default=True)
        burger = self._prepared_variant(name="برجر", sku="BRG-5", categories=[food])
        order = self._paid_order([(burger, "1", "")])

        self.assertEqual(enqueue_kitchen_print_jobs(order.pk), [])
        self.assertFalse(
            PrintJob.objects.filter(job_type=PrintJob.Type.KITCHEN).exists()
        )

    def test_enqueue_returns_empty_without_prepared_lines(self):
        self._station(name="الشواية", is_default=True)
        bottle = self._retail_variant(name="ماء", sku="WTR-2")
        order = self._paid_order([(bottle, "1", "")])

        self.assertEqual(enqueue_kitchen_print_jobs(order.pk), [])

    def test_claim_next_respects_station_printer_profile(self):
        food = self._category("طعام")
        grill_profile = self._profile("Grill printer")
        bar_profile = self._profile("Bar printer")
        self._station(
            name="الشواية", profile=grill_profile, categories=[food], is_default=True
        )
        burger = self._prepared_variant(name="برجر", sku="BRG-6", categories=[food])
        order = self._paid_order([(burger, "1", "")])
        enqueue_kitchen_print_jobs(order.pk)

        bar_agent = PrintAgent.objects.create(
            name="Bar device", identifier="bar-device", printer_profile=bar_profile
        )
        self.assertIsNone(claim_next_print_job(bar_agent))

        grill_agent = PrintAgent.objects.create(
            name="Grill device",
            identifier="grill-device",
            printer_profile=grill_profile,
        )
        claimed = claim_next_print_job(grill_agent)
        self.assertIsNotNone(claimed)
        self.assertEqual(claimed.printer_profile_id, grill_profile.id)


class KitchenCheckoutTests(PrintingTestMixin, TestCase):
    def setUp(self):
        super().setUp()
        ShopSettings.load()
        ShopSettings.objects.filter(pk=1).update(auto_print_kitchen_tickets=True)
        self.food = ProductCategory.objects.create(name="طعام")
        self.grill_profile = PrinterProfile.objects.create(
            name="Grill", printer_type=PrinterProfile.Type.ESCPOS
        )
        self.grill = PrepStation.objects.create(
            name="الشواية", printer_profile=self.grill_profile, is_default=True
        )
        self.grill.categories.add(self.food)

        burger = create_product_with_default_variant(
            name="برجر", sku="K-BRG", unit_price=Decimal("6.00")
        )
        burger.is_prepared = True
        burger.save(update_fields=["is_prepared"])
        burger.categories.add(self.food)
        self.burger_variant = burger.default_variant
        StockItem.objects.create(variant=self.burger_variant, quantity_on_hand=20)

        bottle = create_product_with_default_variant(
            name="ماء", sku="K-WTR", unit_price=Decimal("1.00")
        )
        self.bottle_variant = bottle.default_variant
        StockItem.objects.create(variant=self.bottle_variant, quantity_on_hand=20)

        self.cashier_client.post(
            reverse("register-session-start"), {"opening_cash": "0.00"}, format="json"
        )

    def _checkout(self, lines, amount):
        payload = {
            "lines": lines,
            "payment_method": Payment.Method.CASH,
            "amount_received": amount,
        }
        with self.captureOnCommitCallbacks(execute=True):
            return self.cashier_client.post(
                reverse("order-checkout"), payload, format="json"
            )

    def test_checkout_returns_kitchen_jobs_for_prepared_lines_only(self):
        response = self._checkout(
            [
                {"variant": self.burger_variant.pk, "quantity": 1, "notes": "بدون بصل"},
                {"variant": self.bottle_variant.pk, "quantity": 2},
            ],
            amount="8.00",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        kitchen_jobs = response.data.get("kitchen_print_jobs")
        self.assertEqual(len(kitchen_jobs), 1)
        job = kitchen_jobs[0]
        self.assertEqual(job["job_type"], PrintJob.Type.KITCHEN)
        self.assertEqual(job["status"], PrintJob.Status.QUEUED)
        order_payload = job["payload"]["order"]
        self.assertEqual(job["payload"]["kind"], "kitchen")
        self.assertEqual(len(order_payload["lines"]), 1)  # bottle excluded
        self.assertEqual(order_payload["lines"][0]["notes"], "بدون بصل")
        self.assertNotIn("total", order_payload)

    def test_checkout_persists_order_line_notes(self):
        response = self._checkout(
            [{"variant": self.burger_variant.pk, "quantity": 1, "notes": "بدون بصل"}],
            amount="6.00",
        )

        order = Order.objects.get(pk=response.data["id"])
        self.assertEqual(order.lines.get().notes, "بدون بصل")

    def test_no_kitchen_jobs_when_setting_disabled(self):
        ShopSettings.objects.filter(pk=1).update(auto_print_kitchen_tickets=False)

        response = self._checkout(
            [{"variant": self.burger_variant.pk, "quantity": 1}], amount="6.00"
        )

        self.assertNotIn("kitchen_print_jobs", response.data)
        self.assertFalse(
            PrintJob.objects.filter(job_type=PrintJob.Type.KITCHEN).exists()
        )

    def test_sale_completes_when_kitchen_enqueue_fails(self):
        # A kitchen-printing misconfiguration must never fail a paid sale.
        with mock.patch(
            "apps.printing.services.enqueue_kitchen_print_jobs",
            side_effect=RuntimeError("kitchen exploded"),
        ):
            response = self._checkout(
                [{"variant": self.burger_variant.pk, "quantity": 1}], amount="6.00"
            )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertNotIn("kitchen_print_jobs", response.data)
        self.assertEqual(
            Order.objects.get(pk=response.data["id"]).status, Order.Status.PAID
        )


class PrepStationApiTests(PrintingTestMixin, TestCase):
    def setUp(self):
        super().setUp()
        self.profile = PrinterProfile.objects.create(
            name="Grill", printer_type=PrinterProfile.Type.ESCPOS
        )
        self.pdf_profile = PrinterProfile.objects.create(
            name="Office A4", printer_type=PrinterProfile.Type.PDF
        )
        self.food = ProductCategory.objects.create(name="طعام")

    def test_manager_can_create_station(self):
        response = self.manager_client.post(
            reverse("prepstation-list"),
            {
                "name": "الشواية",
                "printer_profile": self.profile.pk,
                "categories": [self.food.pk],
                "is_default": True,
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        self.assertEqual(response.data["category_names"], ["طعام"])
        self.assertEqual(response.data["printer_profile_name"], "Grill")

    def test_category_cannot_route_to_two_stations(self):
        existing = PrepStation.objects.create(name="الشواية", printer_profile=self.profile)
        existing.categories.add(self.food)

        response = self.manager_client.post(
            reverse("prepstation-list"),
            {"name": "البار", "categories": [self.food.pk]},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("categories", response.data)

    def test_pdf_profile_is_rejected(self):
        response = self.manager_client.post(
            reverse("prepstation-list"),
            {"name": "الشواية", "printer_profile": self.pdf_profile.pk},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("printer_profile", response.data)

    def test_second_default_is_rejected(self):
        PrepStation.objects.create(name="الشواية", is_default=True)

        response = self.manager_client.post(
            reverse("prepstation-list"),
            {"name": "البار", "is_default": True},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("is_default", response.data)

    def test_cashier_cannot_manage_stations(self):
        response = self.cashier_client.post(
            reverse("prepstation-list"),
            {"name": "الشواية"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
