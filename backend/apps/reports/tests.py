from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.payments.models import Payment
from apps.sales.models import Order, OrderLine, RegisterSession

from .models import ReportRun


class ReportRunApiTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="reports-manager", password="pass")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.cashier = User.objects.create_user(username="reports-cashier", password="pass")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.unassigned = User.objects.create_user(username="reports-none", password="pass")

        product = create_product_with_default_variant(
            sku="REPORT-COF",
            name="قهوة التقارير",
            unit_price=Decimal("4.00"),
        )
        session = RegisterSession.objects.create(
            owner=self.cashier,
            owner_key=f"user:{self.cashier.pk}",
            opening_cash=Decimal("10.00"),
        )
        order = Order.objects.create(
            register_session=session,
            status=Order.Status.PAID,
            subtotal=Decimal("8.00"),
            total=Decimal("8.00"),
        )
        OrderLine.objects.create(
            order=order,
            variant=product.default_variant,
            quantity=2,
            unit_price=Decimal("4.00"),
            unit_cost=Decimal("1.50"),
        )
        Payment.objects.create(
            order=order,
            method=Payment.Method.CASH,
            amount=Decimal("8.00"),
        )

    def test_catalog_only_contains_reports_available_to_user(self):
        client = APIClient()
        client.force_authenticate(user=self.unassigned)

        response = client.get(reverse("report-catalog"))

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["reports"], [])

    def test_cashier_can_run_sales_report_and_audit_is_recorded(self):
        client = APIClient()
        client.force_authenticate(user=self.cashier)

        response = client.post(
            reverse("report-list"),
            {
                "report_type": ReportRun.ReportType.SALES_SUMMARY,
                "output_format": ReportRun.OutputFormat.PDF,
                "params": {},
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data["status"], ReportRun.Status.SUCCESS)
        self.assertEqual(response.data["requested_by"], self.cashier.pk)
        self.assertEqual(response.data["payload"]["summary"]["net_sales"], "8.00")
        self.assertGreater(response.data["row_count"], 0)
        self.assertEqual(len(response.data["checksum"]), 64)
        self.assertEqual(ReportRun.objects.count(), 1)

    def test_user_without_source_permission_cannot_run_report_but_failure_is_audited(self):
        client = APIClient()
        client.force_authenticate(user=self.unassigned)

        response = client.post(
            reverse("report-list"),
            {
                "report_type": ReportRun.ReportType.SALES_SUMMARY,
                "params": {},
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        run = ReportRun.objects.get()
        self.assertEqual(run.status, ReportRun.Status.FAILED)
        self.assertEqual(run.requested_by, self.unassigned)
        self.assertIn("permission", run.error_message.lower())
