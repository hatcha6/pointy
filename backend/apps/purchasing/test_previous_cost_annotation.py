"""The SQL-annotated previous-purchase cost must equal the row-by-row lookup.

``PurchaseLineSerializer`` shows each line's cost against the previous purchase
of the same variant, and it drives the ``unit_cost_changed`` flag the purchasing
screen highlights. Resolving that per line cost 1 query per line on every payload
that ships line items; ``previous_purchase_line_annotations`` folds it into the
``lines`` prefetch as two correlated subqueries.

That is only safe if the annotated path and the cold lookup agree EXACTLY —
including across mixed packs (a carton of 24 vs loose pieces), where a rounding
difference of one hundredth per base unit re-scales into a fake "cost changed"
badge. These tests pin that equality on real value assertions, so an annotation
that silently disagrees (or silently returns nothing) fails loudly.
"""

from decimal import Decimal

from django.db import connection
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from rest_framework import status

from .models import PurchaseLine, PurchaseOrder
from .serializers import PurchaseLineSerializer
from .test_units import PurchaseUnitTestCase

# The cost fields whose value depends on the previous purchase.
_COST_FIELDS = (
    "previous_unit_cost",
    "unit_cost_change",
    "unit_cost_change_percent",
    "unit_cost_changed",
)


class PreviousCostAnnotationParityTests(PurchaseUnitTestCase):
    def _received_line(self, *, unit="", unit_factor="1", unit_cost, status_=None):
        order = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=status_ or PurchaseOrder.Status.RECEIVED,
        )
        return order.lines.create(
            variant=self.variant,
            quantity=Decimal("1"),
            unit=unit,
            unit_factor=Decimal(unit_factor),
            unit_cost=Decimal(unit_cost),
        )

    def _cold_costs(self, line_pk):
        """The pre-annotation behaviour: a bare line, resolved with a query."""
        line = PurchaseLine.objects.get(pk=line_pk)
        self.assertFalse(hasattr(line, "previous_line_unit_cost"))
        serializer = PurchaseLineSerializer()
        return {
            field: getattr(serializer, f"get_{field}")(line) for field in _COST_FIELDS
        }

    def _annotated_costs(self, order_id):
        response = self.client.get(reverse("purchaseorder-detail", args=[order_id]))
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        line = response.data["lines"][0]
        return {field: line[field] for field in _COST_FIELDS}

    def _assert_parity(self, line, expected):
        annotated = self._annotated_costs(line.purchase_order_id)
        self.assertEqual(annotated, self._cold_costs(line.pk))
        # Pinned separately so the two paths agreeing on a wrong answer fails.
        self.assertEqual(annotated, expected)

    def test_matches_the_lookup_when_the_previous_buy_was_a_pack(self):
        self._received_line(unit="carton", unit_factor="24", unit_cost="48.00")
        line = self._received_line(unit_cost="2.10")
        # 48 a carton of 24 is 2.00 a piece; this buy is 2.10 → up 5%.
        self._assert_parity(
            line,
            {
                "previous_unit_cost": "2.00",
                "unit_cost_change": "0.10",
                "unit_cost_change_percent": "5.00",
                "unit_cost_changed": True,
            },
        )

    def test_matches_the_lookup_when_this_buy_is_a_pack(self):
        self._received_line(unit_cost="2.00")
        line = self._received_line(unit="carton", unit_factor="24", unit_cost="48.00")
        # Re-expressed in cartons: same price, so no change — not a +2300% spike.
        self._assert_parity(
            line,
            {
                "previous_unit_cost": "48.00",
                "unit_cost_change": "0.00",
                "unit_cost_change_percent": "0.00",
                "unit_cost_changed": False,
            },
        )

    def test_matches_the_lookup_on_a_cost_that_does_not_divide_evenly(self):
        # 100/3 per base unit has no exact decimal form: the annotated and cold
        # paths must round-trip it identically or the badge flickers.
        self._received_line(unit="carton", unit_factor="3", unit_cost="100.00")
        line = self._received_line(unit="carton", unit_factor="3", unit_cost="100.00")
        self._assert_parity(
            line,
            {
                "previous_unit_cost": "100.00",
                "unit_cost_change": "0.00",
                "unit_cost_change_percent": "0.00",
                "unit_cost_changed": False,
            },
        )

    def test_the_first_ever_purchase_has_no_previous_cost(self):
        line = self._received_line(unit_cost="2.10")
        self._assert_parity(
            line,
            {
                "previous_unit_cost": None,
                "unit_cost_change": None,
                "unit_cost_change_percent": None,
                "unit_cost_changed": False,
            },
        )

    def test_a_cancelled_order_is_not_the_previous_purchase(self):
        self._received_line(unit_cost="2.00")
        self._received_line(unit_cost="9.99", status_=PurchaseOrder.Status.CANCELLED)
        line = self._received_line(unit_cost="2.10")
        # The cancelled 9.99 is skipped: compared against the 2.00 before it.
        self._assert_parity(
            line,
            {
                "previous_unit_cost": "2.00",
                "unit_cost_change": "0.10",
                "unit_cost_change_percent": "5.00",
                "unit_cost_changed": True,
            },
        )

    def test_the_detail_payload_costs_no_query_per_line(self):
        for index in range(4):
            self._received_line(unit_cost=f"2.0{index}")
        order = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.RECEIVED,
        )
        for _ in range(4):
            order.lines.create(
                variant=self.variant,
                quantity=Decimal("1"),
                unit_factor=Decimal("1"),
                unit_cost=Decimal("2.10"),
            )
        url = reverse("purchaseorder-detail", args=[order.pk])
        self.client.get(url)  # warm the permission/content-type caches

        with CaptureQueriesContext(connection) as queries:
            response = self.client.get(url)

        self.assertEqual(len(response.data["lines"]), 4)
        self.assertTrue(all(row["previous_unit_cost"] for row in response.data["lines"]))
        # Four lines resolved without four `latest_purchase_line_for_variant`
        # round-trips: the lines table is read exactly once for the whole page
        # (the prefetch), with the history resolved inside it as subqueries.
        line_reads = [
            query["sql"]
            for query in queries.captured_queries
            if 'FROM "purchasing_purchaseline"' in query["sql"]
        ]
        self.assertEqual(len(line_reads), 1, "\n\n".join(line_reads))
