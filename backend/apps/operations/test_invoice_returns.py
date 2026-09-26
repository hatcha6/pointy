"""Giving back part or all of a job's invoice gives back money, not parts.

A return on a job's invoice used to restock the part like any sale line while
the job went on calling it consumed: the ledger counted a screen still fitted to
the customer's phone. A void did the same to every part, and left the job
holding a sale that no longer stood. It could not be invoiced again or
cancelled, and once a balance was read net of returns it read as settled.

Now the money comes back and the parts stay with the job; a part refunded on
the invoice is the job's to keep fitted or put back; and an invoice given back
whole lets go of its job. See ``invoice_returns``.
"""

from decimal import Decimal
from importlib import import_module
from unittest import mock

from django.apps import apps as django_apps
from django.db import connection
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from rest_framework import status

from apps.catalog.testing import create_product_with_default_variant
from apps.documents.guards import system_write
from apps.inventory.models import StockItem
from apps.sales.models import Order, RegisterSession
from apps.sales.services import checkout_order, return_order_items, void_order

from .invoice_returns import release_jobs_held_by_void_invoices
from .models import Job, WorkflowTemplate
from .services import _job_is_settled, create_job
from .tests import OperationsTestCase, authenticated_client, repair_template, stage

SCREEN = Decimal("120.00")


class JobInvoiceReturnTests(OperationsTestCase):
    def setUp(self):
        super().setUp()
        self.cashier_client = authenticated_client(self.cashier)
        self.manager_client = authenticated_client(self.manager)
        self.technician_client = authenticated_client(self.technician)
        self.session = RegisterSession.objects.create(
            owner=self.cashier,
            owner_key=f"user:{self.cashier.pk}",
            status=RegisterSession.Status.OPEN,
        )

    # -- helpers ---------------------------------------------------------

    def on_hand(self):
        return StockItem.objects.get(variant=self.part_variant).quantity_on_hand

    def invoiced_job(self, *, screens=1, labour=Decimal("0.00")):
        """A repair with ``screens`` screens fitted, invoiced and paid."""
        data = self.create_repair_job(client=self.cashier_client)
        fitted = self.technician_client.post(
            reverse("job-add-material", args=[data["id"]]),
            {"variant": self.part_variant.pk, "quantity": screens},
            format="json",
        )
        self.assertEqual(fitted.status_code, status.HTTP_200_OK, fitted.data)
        self.invoice(data["id"], SCREEN * screens + labour, labour=labour)
        return Job.objects.get(pk=data["id"])

    def invoice(self, job_id, amount, *, labour=Decimal("0.00")):
        response = self.cashier_client.post(
            reverse("job-invoice", args=[job_id]),
            {
                "labor_total": str(labour),
                "payments": [{"method": "cash", "amount": str(amount)}],
            },
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)

    def screen_line(self, job):
        return job.order.lines.get(variant=self.part_variant)

    def give_back(self, job, line, quantity=1):
        return_order_items(
            order=job.order,
            lines=[(line, Decimal(quantity))],
            reason="استرداد",
            register_session=self.session,
        )

    def void(self, job):
        void_order(
            order=job.order, reason="فاتورة خاطئة", register_session=self.session
        )
        return Job.objects.get(pk=job.pk)

    def material_payload(self, job):
        response = self.manager_client.get(reverse("job-detail", args=[job.pk]))
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        return response.data["materials"][0]

    def put_back(self, job):
        return self.technician_client.post(
            reverse("job-reverse-material", args=[job.pk, job.materials.get().pk]),
            format="json",
        )

    # -- a return on the invoice ------------------------------------------

    def test_a_refunded_part_stays_fitted_and_the_job_keeps_its_invoice(self):
        job = self.invoiced_job(labour=Decimal("30.00"))
        invoice = job.order

        self.give_back(job, self.screen_line(job))

        job.refresh_from_db()
        invoice.refresh_from_db()
        # The money came back; the screen is still in the customer's phone.
        self.assertEqual(invoice.status, Order.Status.PAID)
        self.assertEqual(invoice.amount_paid, Decimal("30.00"))
        self.assertEqual(invoice.balance_due, Decimal("0.00"))
        self.assertEqual(self.on_hand(), Decimal("9"))
        self.assertEqual(job.order_id, invoice.pk)
        self.assertTrue(job.materials.get().is_consumed)
        self.assertFalse(self.material_payload(job)["is_billed"])

    def test_a_part_refunded_on_the_invoice_can_be_put_back_through_the_job(self):
        job = self.invoiced_job(labour=Decimal("30.00"))
        self.give_back(job, self.screen_line(job))
        self.assertIsNotNone(Job.objects.get(pk=job.pk).order_id)

        response = self.put_back(job)

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(self.on_hand(), Decimal("10"))
        self.assertIsNotNone(job.materials.get().reversed_at)

    def test_a_part_the_invoice_still_charges_for_cannot_be_put_back(self):
        job = self.invoiced_job()

        response = self.put_back(job)

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertTrue(self.material_payload(job)["is_billed"])
        self.assertEqual(self.on_hand(), Decimal("9"))

    def test_refunding_part_of_a_line_keeps_the_rest_charged(self):
        job = self.invoiced_job(screens=2)

        self.give_back(job, self.screen_line(job), quantity=1)

        # Neither screen came back to the shelf, and one is still billed.
        self.assertEqual(self.on_hand(), Decimal("8"))
        self.assertTrue(self.material_payload(job)["is_billed"])
        self.assertEqual(self.put_back(job).status_code, status.HTTP_400_BAD_REQUEST)

    def test_refunding_the_labour_leaves_the_part_alone(self):
        job = self.invoiced_job(labour=Decimal("30.00"))
        labour = job.order.lines.exclude(variant=self.part_variant).get()

        self.give_back(job, labour)

        self.assertEqual(self.on_hand(), Decimal("9"))
        self.assertTrue(self.material_payload(job)["is_billed"])

    # -- the invoice given back whole ---------------------------------------

    def test_a_voided_invoice_unbills_the_job_and_the_part_stays_fitted(self):
        job = self.invoiced_job()
        invoice = job.order

        job = self.void(job)

        invoice.refresh_from_db()
        self.assertEqual(invoice.status, Order.Status.VOID)
        self.assertIsNone(job.order_id)
        self.assertEqual(job.settlement_state, "not_invoiced")
        self.assertFalse(_job_is_settled(job))
        self.assertTrue(job.materials.get().is_consumed)
        self.assertEqual(self.on_hand(), Decimal("9"))

    def test_returning_everything_unbills_it_too(self):
        job = self.invoiced_job()

        self.give_back(job, self.screen_line(job))

        job.refresh_from_db()
        # A screen-only invoice returned in full is void.
        self.assertIsNone(job.order_id)
        self.assertTrue(job.materials.get().is_consumed)
        self.assertEqual(self.on_hand(), Decimal("9"))

    def test_the_job_is_invoiced_again_and_the_part_leaves_once(self):
        job = self.void(self.invoiced_job())

        self.invoice(job.pk, SCREEN)

        job.refresh_from_db()
        self.assertEqual(job.order.total, SCREEN)
        self.assertEqual(job.order.status, Order.Status.PAID)
        self.assertEqual(job.settlement_state, "settled")
        self.assertEqual(self.on_hand(), Decimal("9"))

    def test_the_device_cannot_leave_on_a_voided_invoice(self):
        job = self.void(self.invoiced_job())
        self.manager_client.patch(
            reverse("job-detail", args=[job.pk]),
            {"approved_price": str(SCREEN)},
            format="json",
        )
        template = repair_template()
        for code in ("diagnosing", "waiting_approval", "repairing", "testing", "ready"):
            moved = self.manager_client.post(
                reverse("job-transition", args=[job.pk]),
                {"to_stage": stage(template, code).pk, "note": "تقدم"},
                format="json",
            )
            self.assertEqual(moved.status_code, status.HTTP_200_OK, moved.data)

        handover = self.cashier_client.post(
            reverse("job-transition", args=[job.pk]),
            {"to_stage": stage(template, "delivered").pk, "handed_over_to": "أحمد"},
            format="json",
        )

        self.assertEqual(handover.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(handover.data["code"], "settlement_required")

    def test_cancelling_after_the_void_puts_the_part_back_once(self):
        job = self.void(self.invoiced_job())

        cancelled = self.manager_client.post(
            reverse("job-cancel", args=[job.pk]), {"reason": "فُكّت الشاشة"}, format="json"
        )

        self.assertEqual(cancelled.status_code, status.HTTP_200_OK, cancelled.data)
        self.assertFalse(job.materials.get().is_consumed)
        self.assertEqual(self.on_hand(), Decimal("10"))

    def test_a_void_that_put_nothing_back_takes_nothing_back_out(self):
        """A draft is discarded, not reversed, so its lines come back to no
        shelf. Taking the part out after that would take it out twice."""
        from apps.documents import services as document_services
        from apps.documents.statuses import DocumentStatus

        job = self.invoiced_job()
        with system_write():
            Order.objects.filter(pk=job.order_id).update(
                doc_status=DocumentStatus.DRAFT
            )

        document_services.cancel(job.order, reason="مسودة", actor=self.manager)

        job.refresh_from_db()
        self.assertIsNone(job.order_id)
        self.assertEqual(self.on_hand(), Decimal("9"))

    # -- what older code left behind --------------------------------------

    def _the_old_way(self):
        """Returns and voids as they were: parts restocked, the job untold."""
        return mock.patch.multiple(
            "apps.operations.invoice_returns",
            keep_job_parts=lambda adjustment: None,
            unbill_jobs_of_voided_invoice=lambda order: None,
        )

    def test_a_job_still_holding_a_void_invoice_is_released(self):
        job = self.invoiced_job()
        with self._the_old_way():
            self.void(job)
        job.refresh_from_db()
        self.assertEqual(self.on_hand(), Decimal("10"))
        # Settled by nothing, even before it is released.
        self.assertEqual(job.settlement_state, "not_invoiced")
        self.assertFalse(_job_is_settled(job))

        self.assertEqual(release_jobs_held_by_void_invoices(), 1)

        job.refresh_from_db()
        self.assertIsNone(job.order_id)
        # That void put the screen on the shelf; the job agrees, and cancelling
        # it now does not put it there a second time.
        self.assertIsNotNone(job.materials.get().reversed_at)
        self.manager_client.post(
            reverse("job-cancel", args=[job.pk]), {"reason": "إلغاء"}, format="json"
        )
        self.assertEqual(self.on_hand(), Decimal("10"))
        self.assertEqual(release_jobs_held_by_void_invoices(), 0)

    def test_parts_an_older_return_restocked_are_marked_put_back(self):
        job = self.invoiced_job(labour=Decimal("30.00"))
        with self._the_old_way():
            self.give_back(job, self.screen_line(job))
        self.assertEqual(self.on_hand(), Decimal("10"))

        import_module(
            "apps.sales.migrations.0038_job_parts_already_returned_are_put_back"
        ).put_back_parts_already_returned(django_apps, None)

        self.assertIsNotNone(job.materials.get().reversed_at)
        self.assertEqual(self.put_back(job).status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(self.on_hand(), Decimal("10"))

    # -- kitchen ---------------------------------------------------------

    def test_a_kitchen_ticket_keeps_its_voided_sale(self):
        """A kitchen job's sale is the customer's own order, not a bill for
        the job's ingredients: voiding it leaves the ticket as it was."""
        dish = create_product_with_default_variant(
            sku="LATTE", name="لاتيه", unit_price=Decimal("5.00")
        )
        StockItem.objects.create(variant=dish.default_variant, quantity_on_hand=10)
        sale = checkout_order(
            register_session=self.session,
            lines_data=[{"variant": dish.default_variant, "quantity": Decimal("1")}],
            payments_data=[{"method": "cash", "amount": Decimal("5.00")}],
        )
        ticket = create_job(
            workflow_template=WorkflowTemplate.objects.get(
                job_type=WorkflowTemplate.JobType.KITCHEN, is_system=True
            )
        )
        Job.objects.filter(pk=ticket.pk).update(order=sale)

        void_order(order=sale, reason="خطأ", register_session=self.session)

        ticket.refresh_from_db()
        self.assertEqual(ticket.order_id, sale.pk)
        self.assertEqual(
            StockItem.objects.get(variant=dish.default_variant).quantity_on_hand,
            Decimal("10"),
        )

    # -- cost ------------------------------------------------------------

    def _board_queries(self):
        url = reverse("job-list")
        self.manager_client.get(url)  # warm permissions and settings
        with CaptureQueriesContext(connection) as ctx:
            response = self.manager_client.get(url)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        return len(ctx)

    def test_the_board_reads_what_each_part_is_billed_once(self):
        """``is_billed`` pairs every part with its invoice line; the board must
        not pay a query per job, or per part, to do it."""
        for _ in range(2):
            job = self.invoiced_job(screens=2, labour=Decimal("30.00"))
            self.give_back(job, self.screen_line(job), quantity=1)
        StockItem.objects.filter(variant=self.part_variant).update(quantity_on_hand=100)
        small = self._board_queries()

        for _ in range(3):
            job = self.invoiced_job(screens=2, labour=Decimal("30.00"))
            self.give_back(job, self.screen_line(job), quantity=1)
        large = self._board_queries()

        self.assertEqual(small, large)
