"""The receipt queue only accepts work something is going to read.

From a first client's database: 24,264 receipt print jobs sat `queued`, one per
paid sale, each carrying a full receipt payload — while 25,002 receipts printed
perfectly by a different route. The shop prints through a driver/PDF printer,
which the till drives itself and which never touches the queue, so the backend
was minting an outbox row for a consumer that did not exist. Only 827 jobs were
ever printed, over four days in August when an agent happened to be running.
"""

from datetime import timedelta
from decimal import Decimal

from django.test import TestCase, override_settings
from django.utils import timezone

from apps.catalog.testing import create_product_with_default_variant
from apps.printing.models import PrintAgent, PrintJob, PrintJobEvent
from apps.printing.services import (
    expire_stale_queued_print_jobs,
    get_default_receipt_template_version,
    print_agent_is_live,
)
from apps.sales.models import Order, OrderLine
from apps.sales.services import create_receipt_print_job


class _Request:
    """Stands in for the checkout request, which is all the service reads."""

    def __init__(self, data=None):
        self.data = data or {}


class ReceiptQueueCreationTests(TestCase):
    def setUp(self):
        from apps.core.models import ShopSettings

        settings_row = ShopSettings.load()
        settings_row.auto_print_receipts = True
        settings_row.save(update_fields=["auto_print_receipts"])

        product = create_product_with_default_variant(
            name="Bread", sku="QUEUE-BREAD", unit_price="1.00"
        )
        self.order = Order.objects.create(
            receipt_number="R-QUEUE-1",
            status=Order.Status.PAID,
            subtotal=Decimal("1.00"),
            total=Decimal("1.00"),
        )
        OrderLine.objects.create(
            order=self.order,
            variant=product.default_variant,
            quantity=Decimal("1"),
            unit_price=Decimal("1.00"),
            unit_cost=Decimal("0.40"),
        )

    def _live_agent(self, last_seen=None):
        return PrintAgent.objects.create(
            identifier="pointy-local-agent",
            name="pointy-local-agent",
            is_active=True,
            last_seen_at=last_seen or timezone.now(),
        )

    def test_a_till_that_prints_it_itself_gets_no_queue_row(self):
        """The exact per-sale answer, and the one that keeps a mixed shop
        honest: an agent must not claim and re-print what this till produced."""
        self._live_agent()

        create_receipt_print_job(
            self.order.pk,
            request=_Request({"receipt_delivery": "local"}),
        )

        self.assertFalse(PrintJob.objects.exists())

    def test_a_till_using_the_agent_still_gets_one(self):
        self._live_agent()

        create_receipt_print_job(
            self.order.pk,
            request=_Request({"receipt_delivery": "agent"}),
        )

        self.assertEqual(PrintJob.objects.count(), 1)
        self.assertEqual(PrintJob.objects.get().status, PrintJob.Status.QUEUED)

    def test_no_agent_means_no_row_even_when_the_client_says_nothing(self):
        """The fallback for callers with no client to ask — a payment settled
        later, an operations job — and for clients too old to say."""
        create_receipt_print_job(self.order.pk, request=_Request())

        self.assertFalse(
            PrintJob.objects.exists(),
            "an outbox with no reader is not an outbox",
        )

    def test_a_briefly_unreachable_agent_still_queues(self):
        """The whole point of the outbox: a receipt survives an agent being
        down for a moment. Only a long absence stops the queue."""
        self._live_agent(last_seen=timezone.now() - timedelta(minutes=20))

        create_receipt_print_job(self.order.pk, request=_Request())

        self.assertEqual(PrintJob.objects.count(), 1)

    def test_a_long_gone_agent_does_not(self):
        self._live_agent(last_seen=timezone.now() - timedelta(days=9))

        create_receipt_print_job(self.order.pk, request=_Request())

        self.assertFalse(PrintJob.objects.exists())

    def test_an_inactive_agent_does_not_count_as_a_reader(self):
        agent = self._live_agent()
        agent.is_active = False
        agent.save(update_fields=["is_active"])

        create_receipt_print_job(self.order.pk, request=_Request())

        self.assertFalse(PrintJob.objects.exists())

    @override_settings(POINTY_PRINT_AGENT_LIVENESS_WINDOW_MINUTES=0)
    def test_the_liveness_check_can_be_switched_off(self):
        """An escape hatch for a deployment whose agent genuinely cannot report
        in, so the old always-create behaviour is one env var away."""
        create_receipt_print_job(self.order.pk, request=_Request())

        self.assertEqual(PrintJob.objects.count(), 1)

    def test_a_printing_fault_never_rolls_back_the_sale(self):
        """Unchanged guarantee: the sale is committed and paid by this point."""
        self._live_agent()

        with self.settings(POINTY_PRINT_AGENT_LIVENESS_WINDOW_MINUTES="not a number"):
            create_receipt_print_job(self.order.pk, request=_Request())

        self.order.refresh_from_db()
        self.assertEqual(self.order.status, Order.Status.PAID)


class ReceiptQueueRetentionTests(TestCase):
    """The backstop for rows created while an agent WAS alive and then
    abandoned — exactly what happened over 2026-07-20..22 in the field, when
    every claim failed and the rows were left behind."""

    def _queued_job(self, *, age_hours):
        job = PrintJob.objects.create(
            job_type=PrintJob.Type.RECEIPT,
            idempotency_key=f"receipt-test:{age_hours}",
            template_version=get_default_receipt_template_version(),
            payload={},
        )
        moment = timezone.now() - timedelta(hours=age_hours)
        PrintJob.objects.filter(pk=job.pk).update(created_at=moment)
        return job

    def test_a_receipt_nobody_claimed_in_time_is_retired(self):
        job = self._queued_job(age_hours=48)

        self.assertEqual(expire_stale_queued_print_jobs(), 1)

        job.refresh_from_db()
        self.assertEqual(job.status, PrintJob.Status.CANCELED)
        self.assertTrue(
            job.events.filter(event_type=PrintJobEvent.Type.CANCELED).exists(),
            "the job's own history should say why it was retired",
        )

    def test_a_fresh_job_is_left_alone(self):
        job = self._queued_job(age_hours=1)

        self.assertEqual(expire_stale_queued_print_jobs(), 0)

        job.refresh_from_db()
        self.assertEqual(job.status, PrintJob.Status.QUEUED)

    def test_an_already_printed_job_is_never_touched(self):
        job = self._queued_job(age_hours=48)
        job.status = PrintJob.Status.PRINTED
        job.save(update_fields=["status"])

        self.assertEqual(expire_stale_queued_print_jobs(), 0)

    @override_settings(POINTY_PRINT_JOB_QUEUE_RETENTION_HOURS=0)
    def test_retention_can_be_switched_off(self):
        self._queued_job(age_hours=999)

        self.assertEqual(expire_stale_queued_print_jobs(), 0)


class PrintAgentLivenessTests(TestCase):
    def test_liveness_reads_the_poll_not_the_last_print(self):
        """claim_next_print_job refreshes last_seen_at on every poll, including
        the empty ones, so an agent reading an empty queue still counts."""
        PrintAgent.objects.create(
            identifier="idle-agent",
            name="idle-agent",
            is_active=True,
            last_seen_at=timezone.now(),
        )

        self.assertTrue(print_agent_is_live())

    def test_no_agents_at_all_is_not_live(self):
        self.assertFalse(print_agent_is_live())
