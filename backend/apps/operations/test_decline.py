"""Declining a repair: the work stops, the phone does not disappear.

A customer leaves a phone for diagnosis, hears the price, and says no. A plain
cancel used to stop the job and then lose the phone with it: off the board, off
"in the shop now", with nowhere to record the customer collecting it, the
reason thrown away, and no way to charge for the diagnosis. These tests hold
the decline to the promise a repair's handover already makes — the item stays
the shop's responsibility until it is handed back, and a fee owed is settled
before it leaves.
"""

from decimal import Decimal

from django.urls import reverse
from rest_framework import status

from apps.analytics.models import AnalyticsEvent
from apps.inventory.models import StockItem
from apps.sales.models import Order, RegisterSession
from .models import Job, JobMaterial, WorkflowTemplate
from .services import DIAGNOSIS_FEE_PRODUCT_SKU, create_job
from .tests import (
    OperationsTestCase,
    authenticated_client,
    repair_template,
    stage,
)


class JobDeclineTests(OperationsTestCase):
    def setUp(self):
        super().setUp()
        self.cashier_client = authenticated_client(self.cashier)
        self.manager_client = authenticated_client(self.manager)

    def open_register(self, user):
        return RegisterSession.objects.create(
            owner=user,
            owner_key=f"user:{user.pk}",
            status=RegisterSession.Status.OPEN,
        )

    def park_at_approval(self, job_id):
        """Walk the job to "بانتظار موافقة الزبون" — where the no is heard."""
        template = repair_template()
        for code in ("diagnosing", "waiting_approval"):
            response = self.manager_client.post(
                reverse("job-transition", args=[job_id]),
                {"to_stage": stage(template, code).pk},
                format="json",
            )
            self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)

    def decline(self, job_id, client=None, **payload):
        body = {"reason": "price", **payload}
        return (client or self.cashier_client).post(
            reverse("job-decline", args=[job_id]),
            body,
            format="json",
        )

    def hand_back(self, job_id, client=None, **payload):
        return (client or self.cashier_client).post(
            reverse("job-hand-back", args=[job_id]),
            payload,
            format="json",
        )

    def declined_job(self, **payload):
        data = self.create_repair_job(client=self.cashier_client)
        self.park_at_approval(data["id"])
        response = self.decline(data["id"], **payload)
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        return response.data

    def add_part(self, job_id, *, consume_now=True):
        response = authenticated_client(self.technician).post(
            reverse("job-add-material", args=[job_id]),
            {
                "variant": self.part_variant.pk,
                "quantity": 1,
                "consume_now": consume_now,
            },
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)

    def stock_on_hand(self):
        return StockItem.objects.get(variant=self.part_variant).quantity_on_hand

    # -- declining -------------------------------------------------------------

    def test_decline_keeps_the_reason_the_fee_and_who_decided(self):
        # Audit events are written on commit.
        with self.captureOnCommitCallbacks(execute=True):
            data = self.declined_job(reason="price", note="السعر مرتفع", fee="10.00")

        job = Job.objects.get(pk=data["id"])
        self.assertEqual(job.status, Job.Status.CANCELLED)
        self.assertEqual(job.cancel_reason, Job.CancelReason.PRICE)
        self.assertEqual(job.cancel_note, "السعر مرتفع")
        self.assertEqual(job.decline_fee, Decimal("10.00"))
        self.assertEqual(job.cancelled_by, self.cashier)
        self.assertIsNotNone(job.cancelled_at)
        self.assertTrue(job.is_declined)
        self.assertTrue(job.awaiting_hand_back)
        self.assertEqual(job.custody_state, "with_shop")
        self.assertEqual(data["cancel_reason"], "price")
        self.assertEqual(data["cancelled_by_name"], self.cashier.username)
        self.assertEqual(data["decline_fee"], "10.00")
        self.assertTrue(data["is_declined"])
        self.assertTrue(data["awaiting_hand_back"])
        self.assertTrue(
            AnalyticsEvent.objects.filter(
                name="operations.job.declined",
                entity_id=str(job.pk),
            ).exists()
        )

    def test_a_zero_fee_means_nothing_is_owed(self):
        data = self.declined_job(fee="0")

        self.assertIsNone(Job.objects.get(pk=data["id"]).decline_fee)
        self.assertEqual(data["settlement_state"], "not_invoiced")

    def test_declined_item_waits_on_its_own_shelf_and_is_still_in_the_shop(self):
        data = self.declined_job()

        waiting = self.cashier_client.get(
            reverse("job-list"), {"awaiting_hand_back": "true"}
        )
        board = self.cashier_client.get(reverse("job-list"), {"status": "open"})
        in_shop = self.cashier_client.get(reverse("asset-list"), {"in_shop": "true"})

        self.assertEqual(
            [row["id"] for row in waiting.data["results"]], [data["id"]]
        )
        self.assertNotIn(data["id"], [row["id"] for row in board.data["results"]])
        self.assertEqual(
            [row["id"] for row in in_shop.data["results"]], [self.asset.pk]
        )

    def test_decline_puts_fitted_parts_back_and_closes_reserved_ones(self):
        data = self.create_repair_job(client=self.cashier_client)
        self.add_part(data["id"], consume_now=True)
        self.add_part(data["id"], consume_now=False)
        self.assertEqual(self.stock_on_hand(), 9)

        response = self.decline(data["id"], client=self.manager_client)

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(self.stock_on_hand(), 10)
        materials = JobMaterial.objects.filter(job_id=data["id"])
        self.assertTrue(all(material.reversed_at for material in materials))
        reserved = materials.get(consumed_at__isnull=True)
        self.assertIsNone(reserved.reversal_movement_id)

    def test_only_a_manager_declines_a_job_that_used_parts(self):
        data = self.create_repair_job(client=self.cashier_client)
        self.add_part(data["id"])

        response = self.decline(data["id"])

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(Job.objects.get(pk=data["id"]).status, Job.Status.OPEN)
        self.assertEqual(self.stock_on_hand(), 9)

    def test_decline_refuses_invoiced_and_finished_jobs(self):
        invoiced = self.create_repair_job(client=self.cashier_client)
        self.add_part(invoiced["id"])
        self.open_register(self.cashier)
        self.cashier_client.post(
            reverse("job-invoice", args=[invoiced["id"]]),
            {"payments": [{"method": "cash", "amount": "120.00"}]},
            format="json",
        )
        cancelled = self.create_repair_job(client=self.cashier_client)
        self.cashier_client.post(reverse("job-cancel", args=[cancelled["id"]]))

        self.assertEqual(
            self.decline(invoiced["id"], client=self.manager_client).status_code,
            status.HTTP_400_BAD_REQUEST,
        )
        self.assertEqual(
            self.decline(cancelled["id"]).status_code,
            status.HTTP_400_BAD_REQUEST,
        )

    def test_a_job_holding_nothing_of_a_customers_cannot_be_declined(self):
        # A kitchen order holds nothing of the customer's to hand back.
        job = create_job(
            workflow_template=WorkflowTemplate.objects.get(
                job_type="kitchen", is_system=True
            )
        )

        response = self.decline(job.pk, client=self.manager_client)

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_decline_needs_a_reason_it_knows(self):
        data = self.create_repair_job(client=self.cashier_client)

        response = self.decline(data["id"], reason="bored")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("reason", response.data)

    def test_declining_ends_a_hold(self):
        data = self.create_repair_job(client=self.cashier_client)
        self.cashier_client.post(
            reverse("job-hold", args=[data["id"]]),
            {"reason": "بانتظار شاشة"},
            format="json",
        )

        self.decline(data["id"])

        job = Job.objects.get(pk=data["id"])
        self.assertIsNone(job.on_hold_since)
        self.assertEqual(job.hold_reason, "")

    # -- handing back ----------------------------------------------------------

    def test_hand_back_without_a_fee_goes_straight_home(self):
        data = self.declined_job(reason="cannot_repair")

        response = self.hand_back(data["id"], handed_over_to="أخوه محمد")

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        job = Job.objects.get(pk=data["id"])
        self.assertIsNotNone(job.handed_over_at)
        self.assertEqual(job.handed_over_to, "أخوه محمد")
        self.assertFalse(job.awaiting_hand_back)
        self.assertEqual(job.custody_state, "released")
        self.assertEqual(job.status, Job.Status.CANCELLED)
        waiting = self.cashier_client.get(
            reverse("job-list"), {"awaiting_hand_back": "true"}
        )
        in_shop = self.cashier_client.get(reverse("asset-list"), {"in_shop": "true"})
        self.assertEqual(waiting.data["results"], [])
        self.assertEqual(in_shop.data["results"], [])

    def test_hand_back_waits_for_the_fee(self):
        data = self.declined_job(fee="10.00")

        response = self.hand_back(data["id"], handed_over_to="أحمد")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data.get("code"), "settlement_required")
        self.assertIsNone(Job.objects.get(pk=data["id"]).handed_over_at)

    def test_paying_the_fee_bills_one_diagnosis_line_and_lets_the_phone_go(self):
        data = self.declined_job(fee="10.00")
        self.open_register(self.cashier)

        invoiced = self.cashier_client.post(
            reverse("job-invoice", args=[data["id"]]),
            {"payments": [{"method": "cash", "amount": "10.00"}]},
            format="json",
        )

        self.assertEqual(invoiced.status_code, status.HTTP_200_OK, invoiced.data)
        job = Job.objects.get(pk=data["id"])
        order = job.order
        self.assertEqual(order.status, Order.Status.PAID)
        self.assertEqual(order.total, Decimal("10.00"))
        lines = list(order.lines.select_related("variant"))
        self.assertEqual(len(lines), 1)
        self.assertEqual(lines[0].variant.sku, DIAGNOSIS_FEE_PRODUCT_SKU)
        self.assertEqual(lines[0].unit_cost, Decimal("0.00"))
        # The fee is money, not a finished repair.
        self.assertEqual(job.status, Job.Status.CANCELLED)
        self.assertEqual(invoiced.data["settlement_state"], "settled")

        handed = self.hand_back(data["id"], handed_over_to="أحمد")

        self.assertEqual(handed.status_code, status.HTTP_200_OK, handed.data)

    def test_a_fee_booked_to_a_named_customer_counts_as_settled(self):
        data = self.declined_job(fee="15.00")
        self.open_register(self.cashier)

        invoiced = self.cashier_client.post(
            reverse("job-invoice", args=[data["id"]]),
            {"sale_type": "credit", "payments": []},
            format="json",
        )

        self.assertEqual(invoiced.status_code, status.HTTP_200_OK, invoiced.data)
        self.assertEqual(
            self.hand_back(data["id"]).status_code, status.HTTP_200_OK
        )

    def test_a_declined_job_bills_its_fee_and_nothing_else(self):
        owes = self.declined_job(fee="10.00")
        free = self.declined_job()
        self.open_register(self.cashier)

        with_labour = self.cashier_client.post(
            reverse("job-invoice", args=[owes["id"]]),
            {
                "labor_total": "30.00",
                "payments": [{"method": "cash", "amount": "40.00"}],
            },
            format="json",
        )
        nothing_owed = self.cashier_client.post(
            reverse("job-invoice", args=[free["id"]]),
            {"payments": [{"method": "cash", "amount": "5.00"}]},
            format="json",
        )

        self.assertEqual(with_labour.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(nothing_owed.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertFalse(Order.objects.exists())

    def test_a_manager_can_let_an_unpaid_fee_go_on_the_record(self):
        data = self.declined_job(fee="10.00")

        by_cashier = self.hand_back(data["id"], force_release=True, note="زبون دائم")
        without_reason = self.hand_back(
            data["id"], client=self.manager_client, force_release=True
        )
        with self.captureOnCommitCallbacks(execute=True):
            by_manager = self.hand_back(
                data["id"],
                client=self.manager_client,
                force_release=True,
                note="زبون دائم",
            )

        self.assertEqual(by_cashier.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(without_reason.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(by_manager.status_code, status.HTTP_200_OK, by_manager.data)
        self.assertTrue(
            AnalyticsEvent.objects.filter(
                name="operations.job.released_unsettled",
                entity_id=str(data["id"]),
            ).exists()
        )

    def test_hand_back_is_only_for_a_declined_item_still_here(self):
        open_job = self.create_repair_job(client=self.cashier_client)
        cancelled = self.create_repair_job(client=self.cashier_client)
        self.cashier_client.post(reverse("job-cancel", args=[cancelled["id"]]))
        declined = self.declined_job()
        self.hand_back(declined["id"])

        for job_id in (open_job["id"], cancelled["id"], declined["id"]):
            self.assertEqual(
                self.hand_back(job_id).status_code,
                status.HTTP_400_BAD_REQUEST,
            )

    # -- plain cancel and reopen -----------------------------------------------

    def test_a_plain_cancel_keeps_its_note_and_holds_nothing(self):
        data = self.create_repair_job(client=self.cashier_client)

        response = self.cashier_client.post(
            reverse("job-cancel", args=[data["id"]]),
            {"reason": "أُدخلت مرتين"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        job = Job.objects.get(pk=data["id"])
        self.assertEqual(job.cancel_note, "أُدخلت مرتين")
        self.assertEqual(job.cancelled_by, self.cashier)
        self.assertEqual(job.cancel_reason, "")
        self.assertFalse(job.is_declined)
        self.assertFalse(response.data["awaiting_hand_back"])

    def test_reopening_a_decline_forgets_it(self):
        data = self.declined_job(note="غالي", fee="10.00")

        response = self.manager_client.post(reverse("job-reopen", args=[data["id"]]))

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        job = Job.objects.get(pk=data["id"])
        self.assertEqual(job.status, Job.Status.OPEN)
        self.assertEqual(job.cancel_reason, "")
        self.assertEqual(job.cancel_note, "")
        self.assertIsNone(job.decline_fee)
        self.assertIsNone(job.cancelled_by)

    def test_a_decline_whose_fee_is_invoiced_cannot_be_reopened(self):
        data = self.declined_job(fee="10.00")
        self.open_register(self.cashier)
        self.cashier_client.post(
            reverse("job-invoice", args=[data["id"]]),
            {"payments": [{"method": "cash", "amount": "10.00"}]},
            format="json",
        )

        response = self.manager_client.post(reverse("job-reopen", args=[data["id"]]))

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(Job.objects.get(pk=data["id"]).status, Job.Status.CANCELLED)
