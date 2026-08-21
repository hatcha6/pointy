"""Report detail sections must cost a flat number of queries, not one per row.

Three inventory sections render ``variant.full_name``, and the purchasing
section renders ``order.balance_due``. Both are plain attribute reads that hide
a query — ``full_name`` falls through to ``option_values_label`` for a default
variant (empty ``name``), and ``balance_due`` sums ``supplier_payments`` twice
in Python. Sections run to ``DEFAULT_DETAIL_ROW_LIMIT`` rows, so an unprimed
read is a per-row cost on a report a manager runs over a whole month.

Each report is measured at N and 2N rows: a flat count proves the per-row read
is gone, a growing one proves it is back.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.db import connection
from django.test import TestCase
from django.test.utils import CaptureQueriesContext
from django.utils import timezone

from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.inventory.models import StockItem, StockMovement
from apps.purchasing.models import PurchaseOrder, Supplier, SupplierPayment

from .models import ReportRun
from .services import generate_report_payload

BASE_ROWS = 6

SCALING_REPORTS = (
    ReportRun.ReportType.INVENTORY_STATUS,
    ReportRun.ReportType.STOCK_MOVEMENTS,
    ReportRun.ReportType.REORDER_ITEMS,
    ReportRun.ReportType.PURCHASING_SUMMARY,
)


class ReportSectionQueryScalingTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(
            username="reports-scaling-manager",
            password="pass",
        )
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.supplier = Supplier.objects.create(name="مورد التقارير")
        self.seeded = 0

    def _seed(self, count):
        """Add ``count`` rows to every section under test.

        Stock sits below the reorder level so the row also shows up in the
        reorder report, and each purchase order is part-paid so ``balance_due``
        has payments to sum.
        """
        for index in range(self.seeded, self.seeded + count):
            product = create_product_with_default_variant(
                sku=f"SCALE-{index}",
                name=f"منتج {index}",
                unit_price=Decimal("5.00"),
            )
            stock_item = StockItem.objects.create(
                variant=product.default_variant,
                quantity_on_hand=Decimal("1.000"),
                reorder_level=Decimal("10.000"),
            )
            StockMovement.objects.create(
                variant=product.default_variant,
                stock_item=stock_item,
                movement_type=StockMovement.Type.INCREASE,
                quantity=Decimal("1.000"),
                on_hand_before=Decimal("0.000"),
                on_hand_after=Decimal("1.000"),
                committed_before=Decimal("0.000"),
                committed_after=Decimal("0.000"),
                expected_before=Decimal("0.000"),
                expected_after=Decimal("0.000"),
            )
            order = PurchaseOrder.objects.create(
                supplier=self.supplier,
                status=PurchaseOrder.Status.RECEIVED,
                subtotal=Decimal("10.00"),
                total=Decimal("10.00"),
            )
            SupplierPayment.objects.create(
                purchase_order=order,
                supplier=self.supplier,
                method=SupplierPayment.Method.CASH,
                amount=Decimal("4.00"),
            )
        self.seeded += count

    def _payload(self, report_type):
        today = timezone.localdate()
        return generate_report_payload(
            report_type=report_type,
            params={
                "start_date": (today - timezone.timedelta(days=7)).isoformat(),
                "end_date": today.isoformat(),
            },
            user=self.manager,
        )

    def _query_count(self, report_type):
        with CaptureQueriesContext(connection) as captured:
            self._payload(report_type)
        return len(captured)

    def test_detail_sections_do_not_scale_with_row_count(self):
        self._seed(BASE_ROWS)
        baseline = {
            report: self._query_count(report) for report in SCALING_REPORTS
        }
        self._seed(BASE_ROWS)
        for report in SCALING_REPORTS:
            with self.subTest(report=report):
                self.assertEqual(
                    self._query_count(report),
                    baseline[report],
                    f"{report} costs a query per row: {baseline[report]} at "
                    f"{BASE_ROWS} rows, more at {BASE_ROWS * 2}.",
                )

    def test_primed_rows_still_carry_the_values_they_report(self):
        """The prefetches must not change what the sections say."""
        self._seed(1)
        variant = StockItem.objects.get().variant

        inventory = self._payload(ReportRun.ReportType.INVENTORY_STATUS)
        rows = self._section(inventory, "inventory_items")["rows"]
        self.assertEqual(rows[0]["product_name"], variant.full_name)

        movements = self._payload(ReportRun.ReportType.STOCK_MOVEMENTS)
        rows = self._section(movements, "stock_movements")["rows"]
        self.assertEqual(rows[0]["product_name"], variant.full_name)

        reorder = self._payload(ReportRun.ReportType.REORDER_ITEMS)
        rows = self._section(reorder, "reorder_items")["rows"]
        self.assertEqual(rows[0]["product_name"], variant.full_name)

        purchasing = self._payload(ReportRun.ReportType.PURCHASING_SUMMARY)
        rows = self._section(purchasing, "purchase_orders")["rows"]
        order = PurchaseOrder.objects.get()
        self.assertEqual(rows[0]["balance_due"], f"{order.balance_due:.2f}")

    def _section(self, payload, key):
        return next(
            section for section in payload["sections"] if section["key"] == key
        )
