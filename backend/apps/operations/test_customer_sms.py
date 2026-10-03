"""What the customer of a repair hears by SMS: the job is in, a price awaits
their yes, it is ready (with what is still owed), it went back unrepaired, it
waits uncollected, it was handed over under warranty — each when the shop has
that text switched on, never for a kitchen ticket, never to someone who asked
not to be contacted, and the same move never twice."""

from datetime import timedelta
from unittest import mock

from django.urls import reverse
from django.utils import timezone
from rest_framework import status

from apps.core.models import ShopSettings
from apps.messaging.models import MessagingGateway, OutboundMessage
from apps.sales.models import RegisterSession

from .customer_sms import send_pickup_reminders
from .models import Job, JobStageEvent
from .tests import OperationsTestCase, authenticated_client, repair_template, stage


class JobCustomerSmsTests(OperationsTestCase):
    def setUp(self):
        super().setUp()
        self.customer.phone = "0912345678"
        self.customer.save(update_fields=["phone"])
        settings = ShopSettings.load()
        settings.shop_name = "محل النور"
        settings.save()
        self.gateway = MessagingGateway.objects.create(
            name="phone", provider=MessagingGateway.Provider.FAKE, is_default=True
        )
        self.client_ = authenticated_client(self.manager)

    def switch(self, **kinds):
        self.gateway.auto_messages = {**self.gateway.auto_messages, **kinds}
        self.gateway.save(update_fields=["auto_messages"])

    def texts(self, kind):
        return list(OutboundMessage.objects.filter(template_kind=kind).order_by("pk"))

    def create(self, **overrides):
        with self.captureOnCommitCallbacks(execute=True):
            return self.create_repair_job(client=self.client_, **overrides)

    def move(self, job_id, code, **payload):
        with self.captureOnCommitCallbacks(execute=True):
            response = self.client_.post(
                reverse("job-transition", args=[job_id]),
                {"to_stage": stage(repair_template(), code).pk, **payload},
                format="json",
            )
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        return response.data

    def settle(self, job_id, amount="50.00"):
        """Invoice and pay the job in full, so it may be handed back."""
        if not RegisterSession.objects.filter(owner=self.manager, status=RegisterSession.Status.OPEN).exists():
            RegisterSession.objects.create(
                owner=self.manager, owner_key=f"user:{self.manager.pk}", status=RegisterSession.Status.OPEN
            )
        response = self.client_.post(
            reverse("job-invoice", args=[job_id]),
            {"labor_total": amount, "payments": [{"method": "cash", "amount": amount}]},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)

    def approve(self, job_id, price="50.00"):
        response = self.client_.patch(reverse("job-detail", args=[job_id]), {"approved_price": price}, format="json")
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)

    def walk_to_ready(self, job_id):
        self.approve(job_id)
        for code in ("diagnosing", "repairing", "testing", "ready"):
            self.move(job_id, code)

    def test_the_seeded_ready_stage_is_where_the_customer_may_come(self):
        template = repair_template()
        self.assertTrue(stage(template, "ready").ready_for_pickup)
        self.assertFalse(stage(template, "testing").ready_for_pickup)

    def test_ready_texts_the_customer_once_per_arrival(self):
        data = self.create()
        self.walk_to_ready(data["id"])
        [text] = self.texts("job_ready")
        self.assertEqual(text.to_phone, "+218912345678")
        self.assertEqual(text.body, "محل النور: طلبكم (Apple iPhone 15 Pro) جاهز للاستلام.")
        self.assertEqual(text.segments, 1)
        # Out of ready and back: a new arrival is told again.
        self.move(data["id"], "testing")
        self.move(data["id"], "ready")
        self.assertEqual(len(self.texts("job_ready")), 2)

    def test_ready_names_what_is_still_owed_on_an_invoiced_job(self):
        data = self.create()
        RegisterSession.objects.create(
            owner=self.manager, owner_key=f"user:{self.manager.pk}", status=RegisterSession.Status.OPEN
        )
        response = self.client_.post(
            reverse("job-invoice", args=[data["id"]]),
            {"labor_total": "100.00", "sale_type": "credit", "payments": [{"method": "cash", "amount": "40.00"}]},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.walk_to_ready(data["id"])
        [text] = self.texts("job_ready_due")
        self.assertEqual(text.body, "محل النور: طلبكم (Apple iPhone 15 Pro) جاهز للاستلام، المتبقي 60.00 د.ل.")
        self.assertEqual(self.texts("job_ready"), [])

    def test_while_the_amount_wording_waits_for_approval_ready_still_goes(self):
        data = self.create()
        RegisterSession.objects.create(
            owner=self.manager, owner_key=f"user:{self.manager.pk}", status=RegisterSession.Status.OPEN
        )
        self.client_.post(
            reverse("job-invoice", args=[data["id"]]),
            {"labor_total": "100.00", "sale_type": "credit", "payments": [{"method": "cash", "amount": "40.00"}]},
            format="json",
        )
        with mock.patch(
            "apps.operations.customer_sms.kind_unapproved", side_effect=lambda kind: kind == "job_ready_due"
        ):
            self.walk_to_ready(data["id"])
        self.assertEqual(self.texts("job_ready_due"), [])
        [text] = self.texts("job_ready")
        self.assertEqual(text.body, "محل النور: طلبكم (Apple iPhone 15 Pro) جاهز للاستلام.")

    def test_the_switch_decides(self):
        self.switch(job_ready=False)
        data = self.create()
        self.walk_to_ready(data["id"])
        self.assertEqual(self.texts("job_ready"), [])

    def test_a_price_to_approve_is_texted(self):
        data = self.create(quoted_price="85.00")
        self.move(data["id"], "diagnosing")
        self.move(data["id"], "waiting_approval")
        [text] = self.texts("job_estimate")
        self.assertEqual(text.body, "محل النور: تكلفة طلبكم (Apple iPhone 15 Pro) 85.00 د.ل، ننتظر موافقتكم.")

    def test_no_price_no_estimate_text(self):
        data = self.create()
        self.move(data["id"], "diagnosing")
        self.move(data["id"], "waiting_approval")
        self.assertEqual(self.texts("job_estimate"), [])

    def test_a_declined_job_is_ready_to_collect(self):
        data = self.create()
        self.move(data["id"], "diagnosing")
        self.move(data["id"], "waiting_approval")
        with self.captureOnCommitCallbacks(execute=True):
            response = self.client_.post(reverse("job-decline", args=[data["id"]]), {"reason": "price"}, format="json")
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        [text] = self.texts("job_returned")
        self.assertEqual(text.body, "محل النور: طلبكم (Apple iPhone 15 Pro) جاهز للاستلام دون إصلاح.")

    def test_the_intake_text_waits_for_its_switch(self):
        self.create()
        self.assertEqual(self.texts("job_received"), [])
        self.switch(job_received=True)
        data = self.create()
        [text] = self.texts("job_received")
        self.assertIn(data["job_number"], text.body)
        self.assertTrue(text.body.startswith("محل النور: استلمنا Apple iPhone 15 Pro، رقم طلبكم "))

    def test_a_handover_under_warranty_says_until_when(self):
        self.switch(job_delivered=True)
        data = self.create(warranty_days=90)
        self.walk_to_ready(data["id"])
        self.settle(data["id"])
        self.move(data["id"], "delivered")
        [text] = self.texts("job_delivered")
        job = Job.objects.get(pk=data["id"])
        self.assertIn(f"{job.warranty_expires_on:%Y/%m/%d}", text.body)

    def test_nobody_who_asked_not_to_be_contacted_and_no_kitchen_ticket(self):
        self.customer.do_not_contact = True
        self.customer.save(update_fields=["do_not_contact"])
        data = self.create()
        self.walk_to_ready(data["id"])
        self.assertEqual(self.texts("job_ready"), [])

    def test_pickup_reminders_on_the_third_tenth_and_thirtieth_day(self):
        data = self.create()
        self.walk_to_ready(data["id"])
        ready_event = JobStageEvent.objects.filter(job_id=data["id"], to_stage__code="ready").latest("created_at")
        now = timezone.now()
        JobStageEvent.objects.filter(pk=ready_event.pk).update(created_at=now - timedelta(days=4))
        with self.captureOnCommitCallbacks(execute=True):
            self.assertEqual(send_pickup_reminders(now=now), 1)
        [text] = self.texts("job_pickup_reminder")
        self.assertEqual(text.body, "محل النور: طلبكم (Apple iPhone 15 Pro) بانتظار استلامكم منذ 4 أيام.")
        # The same day again: nothing new.
        with self.captureOnCommitCallbacks(execute=True):
            send_pickup_reminders(now=now)
        self.assertEqual(len(self.texts("job_pickup_reminder")), 1)
        # Eleven days in: the tenth-day reminder.
        JobStageEvent.objects.filter(pk=ready_event.pk).update(created_at=now - timedelta(days=11))
        with self.captureOnCommitCallbacks(execute=True):
            send_pickup_reminders(now=now)
        reminders = self.texts("job_pickup_reminder")
        self.assertEqual(len(reminders), 2)
        self.assertIn("11 يومًا", reminders[-1].body)
        # Switched off: no reminders at all.
        self.switch(job_pickup_reminder=False)
        JobStageEvent.objects.filter(pk=ready_event.pk).update(created_at=now - timedelta(days=31))
        with self.captureOnCommitCallbacks(execute=True):
            self.assertEqual(send_pickup_reminders(now=now), 0)

    def test_a_collected_job_is_not_reminded(self):
        data = self.create()
        self.walk_to_ready(data["id"])
        self.settle(data["id"])
        self.move(data["id"], "delivered")
        JobStageEvent.objects.filter(job_id=data["id"]).update(created_at=timezone.now() - timedelta(days=5))
        with self.captureOnCommitCallbacks(execute=True):
            self.assertEqual(send_pickup_reminders(), 0)

    def test_the_ready_text_by_hand(self):
        self.switch(job_ready=False)
        data = self.create()
        url = reverse("job-notify-ready", args=[data["id"]])
        response = self.client_.post(url)
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["code"], "not_ready")
        self.walk_to_ready(data["id"])
        response = self.client_.post(url)
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        self.assertEqual(response.data["body"], "محل النور: طلبكم (Apple iPhone 15 Pro) جاهز للاستلام.")
        # A customer without a phone has nobody to text.
        self.customer.phone = ""
        self.customer.save(update_fields=["phone"])
        response = self.client_.post(url)
        self.assertEqual(response.data["code"], "no_phone")

    def test_a_job_from_an_old_stage_still_moves_when_sms_is_off(self):
        self.gateway.is_active = False
        self.gateway.save(update_fields=["is_active"])
        data = self.create()
        self.walk_to_ready(data["id"])
        self.assertEqual(Job.objects.get(pk=data["id"]).current_stage.code, "ready")
        self.assertEqual(self.texts("job_ready"), [])

    def test_the_stage_flag_round_trips_through_the_workflow_api(self):
        template = repair_template()
        response = self.client_.get(reverse("workflow-template-detail", args=[template.pk]))
        ready = next(item for item in response.data["stages"] if item["code"] == "ready")
        self.assertTrue(ready["ready_for_pickup"])
