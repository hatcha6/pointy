"""The spreadsheet, the run history, and the question a checksum is for.

Three defects meet here. ``csv`` was declared in the model, accepted by the API
and mirrored in the client's enum, and nothing ever wrote one. The run archive
was stored, indexed and unreachable — the app could only create runs, never list
or reopen them. And the checksum could not answer the one question it existed
for, because ``generated_at`` was inside the bytes it hashed: two runs of the
same closed period were *guaranteed* to differ.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import ACCOUNTANT_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.payments.models import Payment
from apps.sales.models import Order, OrderLine, RegisterSession

from .models import ReportRun
from .services import generate_report_payload, report_figures_checksum


class ReportFixture(TestCase):
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="exp-mgr", password="p")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.accountant = User.objects.create_user(username="exp-acc", password="p")
        self.accountant.groups.add(Group.objects.get(name=ACCOUNTANT_GROUP))

        self.product = create_product_with_default_variant(
            sku="EXP-1", name="قهوة", unit_price=Decimal("4.00")
        )
        self.session = RegisterSession.objects.create(
            owner=self.manager,
            owner_key=f"user:{self.manager.pk}",
            opening_cash=Decimal("0.00"),
        )
        self._sell(2)

    def _sell(self, quantity):
        order = Order.objects.create(
            register_session=self.session,
            status=Order.Status.PAID,
            subtotal=Decimal("4.00") * quantity,
            total=Decimal("4.00") * quantity,
        )
        OrderLine.objects.create(
            order=order,
            variant=self.product.default_variant,
            quantity=quantity,
            unit_price=Decimal("4.00"),
            unit_cost=Decimal("1.50"),
        )
        Payment.objects.create(
            order=order,
            method=Payment.Method.CASH,
            amount=Decimal("4.00") * quantity,
        )
        return order

    def _client(self, user=None):
        client = APIClient()
        client.force_authenticate(user=user or self.manager)
        return client


class FiguresChecksumTests(ReportFixture):
    def _payload(self, **params):
        return generate_report_payload(
            report_type=ReportRun.ReportType.SALES_SUMMARY,
            params=params or {"preset": "month"},
            user=self.manager,
        )

    def test_two_runs_of_one_unchanged_period_agree(self):
        """What the old checksum could never do.

        Both payloads carry a different ``generated_at``, so the run checksum
        differs by construction; the figures checksum is the one an accountant
        can compare.
        """
        first, second = self._payload(), self._payload()
        self.assertNotEqual(first["generated_at"], second["generated_at"])
        self.assertEqual(
            report_figures_checksum(first), report_figures_checksum(second)
        )

    def test_a_new_sale_changes_it(self):
        before = report_figures_checksum(self._payload())
        self._sell(3)
        self.assertNotEqual(before, report_figures_checksum(self._payload()))


class VerifyEndpointTests(ReportFixture):
    def _run(self):
        response = self._client().post(
            reverse("report-list"),
            {
                "report_type": ReportRun.ReportType.SALES_SUMMARY,
                "params": {"preset": "month"},
            },
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        return response.data["id"]

    def test_an_untouched_period_still_verifies(self):
        run_id = self._run()
        response = self._client().post(reverse("report-verify", args=[run_id]))
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertTrue(response.data["matches"])
        self.assertEqual(response.data["changed_figures"], [])

    def test_a_period_that_moved_is_reported_with_the_figures_that_moved(self):
        run_id = self._run()
        self._sell(5)
        response = self._client().post(reverse("report-verify", args=[run_id]))
        self.assertFalse(response.data["matches"])
        self.assertIn("net_sales", response.data["changed_figures"])
        self.assertEqual(response.data["stored_summary"]["net_sales"], "8.00")
        self.assertEqual(response.data["current_summary"]["net_sales"], "28.00")

    def test_an_accountant_can_verify_a_managers_run(self):
        """A reporting role checks the shop's own figures, not its own till."""
        run_id = self._run()
        response = self._client(self.accountant).post(
            reverse("report-verify", args=[run_id])
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertTrue(response.data["matches"])


class RunHistoryTests(ReportFixture):
    def test_the_history_lists_runs_without_shipping_their_rows(self):
        client = self._client()
        client.post(
            reverse("report-list"),
            {
                "report_type": ReportRun.ReportType.SALES_SUMMARY,
                "params": {"preset": "month"},
            },
            format="json",
        )
        response = client.get(reverse("report-list"))
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        row = response.data["results"][0] if "results" in response.data else response.data[0]
        self.assertIn("period_start", row)
        self.assertIn("figures_checksum", row)
        # The list is a table of dates; sending every run's rows to draw it
        # would put megabytes on the wire.
        self.assertNotIn("payload", row)


class CsvExportTests(ReportFixture):
    def _export(self, report_type=ReportRun.ReportType.SALES_SUMMARY, user=None):
        response = self._client(user).post(
            reverse("report-export"),
            {"report_type": report_type, "params": {"preset": "month"}},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        return b"".join(response.streaming_content).decode("utf-8")

    def test_the_export_carries_the_rows_and_the_headers(self):
        body = self._export()
        self.assertIn("sales_summary", body)
        self.assertIn("top_products", body)
        self.assertIn("قهوة", body)

    def test_it_opens_as_utf8_in_a_spreadsheet(self):
        """Excel reads a UTF-8 file as Windows-1252 without a byte-order mark,
        which turns every Arabic product name into mojibake."""
        self.assertTrue(self._export().startswith("﻿"))

    def test_totals_are_written_so_a_reader_can_check_the_column(self):
        self.assertIn("TOTAL (shown)", self._export())

    def test_it_is_offered_as_a_download_with_the_period_in_its_name(self):
        response = self._client().post(
            reverse("report-export"),
            {"report_type": ReportRun.ReportType.SALES_SUMMARY, "params": {"preset": "month"}},
            format="json",
        )
        disposition = response["Content-Disposition"]
        self.assertIn("attachment", disposition)
        self.assertIn("sales_summary", disposition)

    def test_exporting_stores_nothing(self):
        """An export runs at row caps far above what belongs in a stored JSON
        payload; writing one on every click would grow the table by the size of
        the shop's history."""
        before = ReportRun.objects.count()
        self._export()
        self.assertEqual(ReportRun.objects.count(), before)

    def test_a_stored_run_can_be_exported_as_it_was_recorded(self):
        client = self._client()
        created = client.post(
            reverse("report-list"),
            {
                "report_type": ReportRun.ReportType.SALES_SUMMARY,
                "params": {"preset": "month"},
            },
            format="json",
        )
        response = client.get(reverse("report-stored-csv", args=[created.data["id"]]))
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertIn("sales_summary", b"".join(response.streaming_content).decode())

    def test_a_user_without_permission_is_refused(self):
        User = get_user_model()
        outsider = User.objects.create_user(username="exp-nobody", password="p")
        response = self._client(outsider).post(
            reverse("report-export"),
            {"report_type": ReportRun.ReportType.SALES_SUMMARY, "params": {}},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)


class CatalogTests(ReportFixture):
    def test_the_catalog_ships_the_vocabulary_for_asking(self):
        """A client with its own list of periods will eventually offer one the
        server cannot resolve."""
        response = self._client(self.accountant).get(reverse("report-catalog"))
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertIn("last_month", response.data["presets"])
        self.assertIn("previous_year", response.data["comparisons"])
        self.assertEqual(response.data["fiscal_year_start_month"], 1)
        self.assertTrue(response.data["can_manage_period_lock"])

    def test_each_report_declares_what_it_leads_with(self):
        response = self._client().get(reverse("report-catalog"))
        sales = next(
            item for item in response.data["reports"] if item["key"] == "sales_summary"
        )
        self.assertEqual(sales["headline"][0], "net_sales")

    def test_a_statement_declares_the_parameter_it_cannot_be_built_without(self):
        response = self._client().get(reverse("report-catalog"))
        statement = next(
            item
            for item in response.data["reports"]
            if item["key"] == "customer_statement"
        )
        self.assertEqual(list(statement["required_params"]), ["customer_id"])


class ValidationMessageTests(ReportFixture):
    """The server's reason has to reach the person who caused it.

    The backend has always returned precise refusals — "start date must be
    before end date", "period cannot be longer than 366 days" — and the client
    mapped every failure to one generic "could not generate the report".
    """

    def test_a_reversed_range_is_a_400_that_says_why(self):
        response = self._client().post(
            reverse("report-list"),
            {
                "report_type": ReportRun.ReportType.SALES_SUMMARY,
                "params": {"start_date": "2026-09-10", "end_date": "2026-09-01"},
            },
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("before", str(response.data["detail"]))

    def test_too_long_a_range_says_the_limit(self):
        response = self._client().post(
            reverse("report-list"),
            {
                "report_type": ReportRun.ReportType.SALES_SUMMARY,
                "params": {"start_date": "2024-01-01", "end_date": "2026-01-01"},
            },
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("366", str(response.data["detail"]))

    def test_a_missing_statement_party_says_what_is_missing(self):
        response = self._client().post(
            reverse("report-list"),
            {
                "report_type": ReportRun.ReportType.CUSTOMER_STATEMENT,
                "params": {"preset": "month"},
            },
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("customer_id", str(response.data["detail"]))
