"""The four reports that only exist once stock has names.

Each is run through the real endpoint rather than by calling its builder,
because half of what can go wrong with a report is its registration: a type
with no definition is a 400, a definition with no builder is a 500, and a
headline naming a figure the payload does not carry prints a blank box at an
owner.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.models import Product
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.customers.models import Customer
from apps.inventory import consignment_service
from apps.inventory.models import ConsignmentAgreement, StockUnit
from apps.inventory.tracked_testing import receive, tracked_product
from apps.reports.models import ReportRun
from apps.sales.models import RegisterSession
from apps.sales.services import checkout_order

IMEI_A = "351234567890116"
IMEI_B = "351234567890124"


class IdentifiedReportTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.manager = get_user_model().objects.create_user(
            username="manager", password="pass"
        )
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(user=self.manager)

        self.product = tracked_product(
            name="iPhone 13",
            sku="IP13",
            mode=Product.TrackingMode.SERIAL,
            unit_price="1500.00",
        )
        self.variant = self.product.default_variant
        receive(
            variant=self.variant,
            quantity=2,
            unit_cost="1000.00",
            units=[{"code": IMEI_A}, {"code": IMEI_B}],
        )

    def _run(self, report_type, params=None):
        response = self.client.post(
            reverse("report-list"),
            {
                "report_type": report_type,
                "output_format": ReportRun.OutputFormat.JSON,
                "params": params or {},
            },
            format="json",
        )
        self.assertEqual(
            response.status_code, status.HTTP_201_CREATED, response.data
        )
        self.assertEqual(response.data["status"], ReportRun.Status.SUCCESS)
        return response.data["payload"]

    def _sell(self, unit, price="1500.00"):
        session = RegisterSession.objects.create(
            owner_key=f"report-till-{unit.pk}",
            status=RegisterSession.Status.OPEN,
            opening_cash=Decimal("0.00"),
        )
        return checkout_order(
            register_session=session,
            lines_data=[
                {
                    "variant": self.variant,
                    "quantity": Decimal("1"),
                    "effective_unit_price": Decimal(price),
                    "stock_units": [unit.pk],
                }
            ],
            payments_data=[{"method": "cash", "amount": Decimal(price)}],
        )

    def test_aging_counts_the_shelf_and_the_capital_on_it(self):
        payload = self._run(ReportRun.ReportType.UNIT_AGING)

        self.assertEqual(payload["summary"]["unit_count"], 2)
        self.assertEqual(payload["summary"]["capital_on_shelf"], "2000.00")

    def test_aging_counts_a_consignment_but_does_not_value_it(self):
        consignor = Customer.objects.create(full_name="سالم")
        agreement = ConsignmentAgreement.objects.create(
            consignor=consignor,
            payout_mode=ConsignmentAgreement.PayoutMode.FIXED,
            payout_rate=Decimal("900.00"),
        )
        consignment_service.take_into_consignment(
            agreement=agreement,
            items=[
                {
                    "variant": self.variant,
                    "code": "CONSIGNED-1",
                    "declared_value": Decimal("1200.00"),
                }
            ],
        )

        payload = self._run(ReportRun.ReportType.UNIT_AGING)

        # Three on the shelf; two of them the shop's money.
        self.assertEqual(payload["summary"]["unit_count"], 3)
        self.assertEqual(payload["summary"]["capital_on_shelf"], "2000.00")

    def test_margin_is_per_article_not_per_model(self):
        unit = StockUnit.objects.get(code_normalized=IMEI_A)
        self._sell(unit, "1500.00")

        payload = self._run(ReportRun.ReportType.UNIT_MARGIN)

        self.assertEqual(payload["summary"]["units_sold"], 1)
        self.assertEqual(payload["summary"]["revenue"], "1500.00")
        self.assertEqual(payload["summary"]["gross_profit"], "500.00")

    def test_the_unit_ledger_needs_an_identifier(self):
        response = self.client.post(
            reverse("report-list"),
            {
                "report_type": ReportRun.ReportType.UNIT_LEDGER,
                "output_format": ReportRun.OutputFormat.JSON,
                "params": {},
            },
            format="json",
        )
        # A report about a thing has no useful version that covers all of them.
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_the_unit_ledger_reads_one_article_s_whole_life(self):
        unit = StockUnit.objects.get(code_normalized=IMEI_A)
        self._sell(unit, "1500.00")

        payload = self._run(
            ReportRun.ReportType.UNIT_LEDGER, params={"code": IMEI_A}
        )

        self.assertEqual(payload["summary"]["status"], StockUnit.Status.SOLD)
        # In and out: the receipt that brought it, and the sale that took it.
        self.assertEqual(payload["summary"]["event_count"], 2)

    def test_the_consignment_ledger_carries_the_four_figures(self):
        consignor = Customer.objects.create(full_name="سالم", phone="0910000000")
        agreement = ConsignmentAgreement.objects.create(
            consignor=consignor,
            payout_mode=ConsignmentAgreement.PayoutMode.FIXED,
            payout_rate=Decimal("900.00"),
        )
        units = consignment_service.take_into_consignment(
            agreement=agreement,
            items=[
                {
                    "variant": self.variant,
                    "code": "CONSIGNED-1",
                    "declared_value": Decimal("1200.00"),
                }
            ],
        )
        self._sell(units[0], "1200.00")

        payload = self._run(ReportRun.ReportType.CONSIGNMENT_LEDGER)

        summary = payload["summary"]
        # Zero by construction, and printed anyway.
        self.assertEqual(summary["consignment_stock_value"], "0.00")
        self.assertEqual(summary["consignor_payable"], "900.00")
        self.assertEqual(summary["shop_commission"], "300.00")
