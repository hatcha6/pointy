"""A print job's payload must not carry its own audit trail.

``PrintJobSerializer`` used to embed ``events``, which cost one query for the
trail plus one each for every event's ``agent`` and ``user`` label. That is a
cost per *prior attempt*: a printer that keeps failing made each new failure
report slower than the last, exactly when the till is already waiting. No
client reads the field — the Flutter ``PrintJob`` model parses none of it —
and the trail has its own endpoint, ``/print-jobs/<pk>/events/``.

The scaling test measures one report endpoint at N and 2N pre-existing events:
a flat count proves the trail is gone, a growing one proves it is back.
"""

from django.db import connection
from django.test import TestCase
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from rest_framework import status

from .models import PrintAgent, PrintJob, PrintJobEvent
from .tests import PrintingTestMixin

BASE_EVENTS = 4


class PrintJobPayloadTests(PrintingTestMixin, TestCase):
    def setUp(self):
        super().setUp()
        self.template_version = self.create_published_template_version()
        self.agent = PrintAgent.objects.create(identifier="payload-agent", is_active=True)

    def _claimed_job(self, key, event_count):
        """A job mid-flight with ``event_count`` attempts already behind it."""
        job = PrintJob.objects.create(
            job_type=PrintJob.Type.RECEIPT,
            template_version=self.template_version,
            payload={"order": {"receipt_number": key}},
            idempotency_key=key,
            status=PrintJob.Status.CLAIMED,
            claimed_by=self.agent,
        )
        for index in range(event_count):
            PrintJobEvent.objects.create(
                job=job,
                event_type=PrintJobEvent.Type.FAILED,
                user=self.manager,
                agent=self.agent,
                message=f"attempt {index}",
            )
        return job

    def _report_failed(self, job):
        return self.manager_client.post(
            reverse("printjob-failed", args=[job.pk]),
            {"agent": self.agent.pk, "error_message": "الطابعة غير متصلة"},
            format="json",
        )

    def test_job_payload_omits_the_audit_trail(self):
        job = self._claimed_job("payload-omits", BASE_EVENTS)

        response = self.manager_client.get(reverse("printjob-detail", args=[job.pk]))

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertNotIn("events", response.data)
        # The fields the agent and the till actually read are untouched.
        for field in ("id", "job_type", "status", "payload", "error_message"):
            self.assertIn(field, response.data)

    def test_the_trail_is_still_served_by_its_own_endpoint(self):
        job = self._claimed_job("payload-trail", BASE_EVENTS)

        response = self.manager_client.get(reverse("printjob-events", args=[job.pk]))

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        results = response.data["results"]
        self.assertEqual(len(results), BASE_EVENTS)
        self.assertEqual(results[0]["agent_identifier"], self.agent.identifier)
        self.assertEqual(results[0]["username"], self.manager.username)

    def test_reporting_a_failure_does_not_scale_with_prior_attempts(self):
        # An untimed request first: permissions and content types would
        # otherwise land on whichever measurement runs first.
        self._report_failed(self._claimed_job("warm-up", 1))

        counts = {}
        for event_count in (BASE_EVENTS, BASE_EVENTS * 2):
            job = self._claimed_job(f"scaling-{event_count}", event_count)
            with CaptureQueriesContext(connection) as captured:
                response = self._report_failed(job)
            self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
            counts[event_count] = len(captured)

        self.assertEqual(
            counts[BASE_EVENTS],
            counts[BASE_EVENTS * 2],
            "reporting a print failure must cost the same however many times "
            f"the job was already tried, got {counts}",
        )
