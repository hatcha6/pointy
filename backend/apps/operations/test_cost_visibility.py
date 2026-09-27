"""What a fitted part and a production run cost is the owner's figure.

A repair job carries each part's ``unit_cost`` and a production job its
``output_unit_cost``, and until 2026-09-26 anyone who could open the job board
read both: the cashier at the counter and the technician at the bench as much
as the owner. They now go to the reporting roles only — managers, supervisors,
accountants and auditors (``user_has_full_visibility``) — like a sale's cost and
profit. Everyone else still sees what a part sells for.

The keys are removed, not blanked, and the AI's generic resource tools read the
same payload, so they lose them too.
"""

from decimal import Decimal

from django.urls import reverse
from rest_framework import status

from apps.ai.tools import get_resource, query_resource
from apps.core.roles import AUDITOR_GROUP, SUPERVISOR_GROUP
from .models import Job, JobMaterial
from .tests import OperationsTestCase, authenticated_client, create_user_with_role


class JobCostVisibilityTests(OperationsTestCase):
    def setUp(self):
        super().setUp()
        self.supervisor = create_user_with_role("ops-supervisor", SUPERVISOR_GROUP)
        self.auditor = create_user_with_role("ops-auditor", AUDITOR_GROUP)
        data = self.create_repair_job()
        self.job = Job.objects.get(pk=data["id"])
        JobMaterial.objects.create(
            job=self.job,
            variant=self.part_variant,
            quantity=Decimal("1"),
            unit_cost=Decimal("80.00"),
            unit_price=Decimal("120.00"),
        )
        Job.objects.filter(pk=self.job.pk).update(output_unit_cost=Decimal("55.00"))

    def _detail(self, user):
        response = authenticated_client(user).get(
            reverse("job-detail", args=[self.job.pk])
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        return response.data

    def _listed(self, user):
        response = authenticated_client(user).get(reverse("job-list"))
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        rows = response.data["results"] if "results" in response.data else response.data
        return next(row for row in rows if row["id"] == self.job.pk)

    def test_the_counter_and_the_bench_see_prices_not_costs(self):
        for user in (self.cashier, self.technician):
            for job in (self._detail(user), self._listed(user)):
                with self.subTest(user=user.username):
                    self.assertNotIn("output_unit_cost", job)
                    material = job["materials"][0]
                    self.assertNotIn("unit_cost", material)
                    # What the part sells for is theirs to see and to charge.
                    self.assertEqual(material["unit_price"], "120.00")
                    self.assertEqual(material["line_total"], "120.00")

    def test_the_reporting_roles_keep_what_the_parts_cost(self):
        for user in (self.manager, self.supervisor, self.auditor):
            for job in (self._detail(user), self._listed(user)):
                with self.subTest(user=user.username):
                    self.assertEqual(job["output_unit_cost"], "55.00")
                    self.assertEqual(job["materials"][0]["unit_cost"], "80.00")

    def test_the_response_to_fitting_a_part_does_not_carry_its_cost(self):
        response = authenticated_client(self.cashier).post(
            reverse("job-add-material", args=[self.job.pk]),
            {"variant": self.part_variant.pk, "quantity": 1},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertTrue(response.data["materials"])
        for material in response.data["materials"]:
            self.assertNotIn("unit_cost", material)

    def test_the_assistant_reads_the_same_masked_job(self):
        listed = query_resource(user=self.cashier, resource="jobs")
        fetched = get_resource(user=self.cashier, resource="jobs", id=self.job.pk)

        self.assertTrue(listed["ok"], listed)
        self.assertTrue(fetched["ok"], fetched)
        for job in (listed["data"]["results"][0], fetched["data"]):
            self.assertNotIn("output_unit_cost", job)
            self.assertNotIn("unit_cost", job["materials"][0])

        owner = get_resource(user=self.manager, resource="jobs", id=self.job.pk)
        self.assertEqual(owner["data"]["materials"][0]["unit_cost"], "80.00")
