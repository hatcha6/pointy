from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.inventory.models import StockItem
from apps.payments.models import Payment
from apps.sales.models import Order, OrderLine, RegisterCashMovement, RegisterSession

from .models import ReportRun
from .services import DEFAULT_DETAIL_ROW_LIMIT


class ReportRunApiTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(
            username="reports-manager", password="pass"
        )
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.cashier = User.objects.create_user(
            username="reports-cashier", password="pass"
        )
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.unassigned = User.objects.create_user(
            username="reports-none", password="pass"
        )

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

    def _section(self, payload, key):
        return next(section for section in payload["sections"] if section["key"] == key)

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

    def test_user_without_source_permission_cannot_run_report_but_failure_is_audited(
        self,
    ):
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

    def test_register_closure_report_uses_computed_cash_variance(self):
        product = create_product_with_default_variant(
            sku="REGISTER-CLOSE",
            name="قهوة إغلاق الدرج",
            unit_price=Decimal("7.00"),
        )
        session = RegisterSession.objects.create(
            owner=self.cashier,
            owner_key=f"user:{self.cashier.pk}",
            status=RegisterSession.Status.CLOSED,
            opening_cash=Decimal("10.00"),
            closing_cash=Decimal("18.00"),
            closed_at=timezone.now(),
        )
        order = Order.objects.create(
            register_session=session,
            status=Order.Status.PAID,
            subtotal=Decimal("7.00"),
            total=Decimal("7.00"),
        )
        OrderLine.objects.create(
            order=order,
            variant=product.default_variant,
            quantity=1,
            unit_price=Decimal("7.00"),
            unit_cost=Decimal("2.00"),
        )
        Payment.objects.create(
            order=order,
            method=Payment.Method.CASH,
            amount=Decimal("7.00"),
        )
        RegisterCashMovement.objects.create(
            register_session=session,
            movement_type=RegisterCashMovement.MovementType.PAY_IN,
            amount=Decimal("5.00"),
            reason="Opening correction",
            created_by=self.cashier,
        )
        RegisterCashMovement.objects.create(
            register_session=session,
            movement_type=RegisterCashMovement.MovementType.PAY_OUT,
            amount=Decimal("2.00"),
            reason="Petty cash",
            created_by=self.cashier,
        )
        client = APIClient()
        client.force_authenticate(user=self.manager)

        response = client.post(
            reverse("report-list"),
            {
                "report_type": ReportRun.ReportType.REGISTER_CLOSURE,
                "output_format": ReportRun.OutputFormat.PDF,
                "params": {},
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        payload = response.data["payload"]
        self.assertEqual(payload["summary"]["variance_total"], "-2.00")

        register_section = self._section(payload, "register_sessions")
        register_row = next(
            row
            for row in register_section["rows"]
            if row["session_number"] == session.session_number
        )
        self.assertEqual(register_row["expected_cash"], "20.00")
        self.assertEqual(register_row["cash_variance"], "-2.00")
        self.assertEqual(register_row["pay_in_total"], "5.00")
        self.assertEqual(register_row["pay_out_total"], "2.00")

    def test_inventory_report_bounds_long_detail_rows_with_audit_metadata(self):
        created_count = DEFAULT_DETAIL_ROW_LIMIT + 7
        for index in range(created_count):
            product = create_product_with_default_variant(
                sku=f"BOUND-{index:03d}",
                name=f"منتج أرشفة {index:03d}",
                unit_price=Decimal("2.00"),
            )
            StockItem.objects.create(
                variant=product.default_variant,
                quantity_on_hand=index + 1,
            )

        client = APIClient()
        client.force_authenticate(user=self.manager)

        response = client.post(
            reverse("report-list"),
            {
                "report_type": ReportRun.ReportType.INVENTORY_STATUS,
                "output_format": ReportRun.OutputFormat.PDF,
                "params": {},
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        payload = response.data["payload"]
        inventory_section = self._section(payload, "inventory_items")
        self.assertEqual(len(inventory_section["rows"]), DEFAULT_DETAIL_ROW_LIMIT)
        self.assertEqual(
            inventory_section["metadata"],
            {
                "returned_count": DEFAULT_DETAIL_ROW_LIMIT,
                "total_count": created_count,
                "omitted_count": 7,
                "truncated": True,
                "limit": DEFAULT_DETAIL_ROW_LIMIT,
            },
        )

        inventory_audit = next(
            section
            for section in payload["audit"]["sections"]
            if section["key"] == "inventory_items"
        )
        self.assertEqual(
            inventory_audit,
            inventory_section["metadata"] | {"key": "inventory_items"},
        )
        self.assertTrue(payload["audit"]["truncated"])

    def test_report_run_row_count_tracks_returned_payload_rows(self):
        created_count = DEFAULT_DETAIL_ROW_LIMIT + 3
        for index in range(created_count):
            product = create_product_with_default_variant(
                sku=f"COUNT-{index:03d}",
                name=f"منتج عد {index:03d}",
                unit_price=Decimal("3.00"),
            )
            StockItem.objects.create(
                variant=product.default_variant,
                quantity_on_hand=index + 1,
            )

        client = APIClient()
        client.force_authenticate(user=self.manager)

        response = client.post(
            reverse("report-list"),
            {
                "report_type": ReportRun.ReportType.INVENTORY_STATUS,
                "output_format": ReportRun.OutputFormat.PDF,
                "params": {},
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        payload = response.data["payload"]
        returned_row_count = sum(
            len(section["rows"]) for section in payload["sections"]
        )
        run = ReportRun.objects.get(pk=response.data["id"])

        inventory_section = self._section(payload, "inventory_items")

        self.assertEqual(response.data["row_count"], returned_row_count)
        self.assertEqual(payload["audit"]["row_count"], returned_row_count)
        self.assertEqual(run.row_count, returned_row_count)
        self.assertGreater(
            inventory_section["metadata"]["total_count"],
            inventory_section["metadata"]["returned_count"],
        )
