"""The batched previous-cost primer must agree with the per-line lookup it replaces.

``previous_unit_cost`` (and the change/percent/changed fields derived from it)
used to cost one ``ORDER BY created_at LIMIT 1`` query per line — the last
per-line query on ``purchaseorder-detail``. ``previous_purchase_lines_for``
resolves the whole order in 2 queries by expressing the same selection rule as a
correlated subquery, so these tests pin the two paths together on the cases where
they could drift: mixed purchase packs, cancelled orders, several prior buys, and
repeated variants inside one order.

Measured on the 20-line order in ``test_receive_query_scaling``:
``purchaseorder-detail`` 43 -> 25 queries (1.0 -> 0.05 per line).
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.db import connection
from django.test import TestCase
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from rest_framework.test import APIClient

from apps.catalog.models import ProductUnit, UnitOfMeasure
from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import MANAGER_GROUP, ensure_role_groups

from .models import PurchaseOrder, Supplier
from .serializers import PurchaseLineSerializer

COST_FIELDS = (
    "previous_unit_cost",
    "unit_cost_change",
    "unit_cost_change_percent",
    "unit_cost_changed",
)


class PreviousUnitCostPrimerTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(
            username="primer-buyer", password="pass"
        )
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=self.user)
        self.supplier = Supplier.objects.create(name="Primer supplier")
        carton = UnitOfMeasure.objects.get(code="carton")
        self.variants = []
        for index in range(4):
            product = create_product_with_default_variant(
                sku=f"PRIMER-{index}",
                barcode="",
                name=f"Primer product {index}",
                unit_price=Decimal("3.00"),
            )
            ProductUnit.objects.create(
                product=product,
                unit=carton,
                factor_to_base=Decimal("24"),
            )
            self.variants.append(product.default_variant)

    def _order(self, lines, *, status=None):
        # The history below deliberately jumps 2.00 -> 99.00 to prove a
        # cancelled order stays invisible to both lookup paths. That is the
        # exact shape apps.purchasing.cost_guard refuses, so this fixture
        # confirms past it the way the purchasing screen's buyer would.
        response = self.client.post(
            reverse("purchaseorder-list"),
            {
                "supplier": self.supplier.pk,
                "lines": lines,
                "acknowledge_cost_warnings": True,
            },
            format="json",
        )
        self.assertEqual(response.status_code, 201, response.data)
        order = PurchaseOrder.objects.get(pk=response.data["id"])
        if status is not None:
            order.status = status
            order.save(update_fields=["status"])
        return order

    def _cold_line_payload(self, line):
        """The per-line lookup path: a lone line never goes through the primer."""
        return {
            field: PurchaseLineSerializer(line).data[field] for field in COST_FIELDS
        }

    def _history(self):
        """Prior purchases for every variant, in loose pieces and by the carton,
        including one cancelled order that must be invisible to both paths."""
        self._order(
            [
                {"variant": variant.pk, "quantity": 5, "unit_cost": "2.00"}
                for variant in self.variants
            ]
        )
        self._order(
            [
                {
                    "variant": self.variants[0].pk,
                    "quantity": 2,
                    "unit": "carton",
                    "unit_cost": "48.00",
                },
                {"variant": self.variants[1].pk, "quantity": 5, "unit_cost": "2.50"},
            ]
        )
        self._order(
            [
                {"variant": variant.pk, "quantity": 5, "unit_cost": "99.00"}
                for variant in self.variants
            ],
            status=PurchaseOrder.Status.CANCELLED,
        )

    def test_primed_payload_matches_the_per_line_lookup(self):
        self._history()
        # A variant may appear only once per order, so the interesting spread is
        # across variants: one with a pack in its history, one bought in a pack
        # now, one plain, one whose only other buy was on the cancelled order.
        order = self._order(
            [
                {
                    "variant": self.variants[0].pk,
                    "quantity": 1,
                    "unit_cost": "2.10",
                },
                {
                    "variant": self.variants[1].pk,
                    "quantity": 1,
                    "unit": "carton",
                    "unit_cost": "60.00",
                },
                {"variant": self.variants[2].pk, "quantity": 1, "unit_cost": "2.00"},
                {"variant": self.variants[3].pk, "quantity": 1, "unit_cost": "1.50"},
            ]
        )
        lines = list(order.lines.order_by("id"))

        response = self.client.get(reverse("purchaseorder-detail", args=[order.pk]))
        self.assertEqual(response.status_code, 200)
        primed = response.data["lines"]
        self.assertEqual(len(primed), len(lines))

        for payload, line in zip(primed, lines):
            cold = self._cold_line_payload(line)
            for field in COST_FIELDS:
                self.assertEqual(
                    payload[field],
                    cold[field],
                    f"{field} disagrees on line {line.pk} (variant {line.variant_id})",
                )

        # Sanity-check the values themselves, so "both paths agree" can't be
        # satisfied by both being wrong: 48.00/carton of 24 = 2.00/piece.
        self.assertEqual(primed[0]["previous_unit_cost"], "2.00")
        self.assertEqual(primed[0]["unit_cost_change"], "0.10")
        self.assertTrue(primed[0]["unit_cost_changed"])
        # Last buy of variant 1 was 2.50 loose → 60.00 per carton: no change.
        self.assertEqual(primed[1]["previous_unit_cost"], "60.00")
        self.assertFalse(primed[1]["unit_cost_changed"])
        # The cancelled 99.00 order is invisible to both paths.
        self.assertEqual(primed[3]["previous_unit_cost"], "2.00")

    def test_first_ever_purchases_have_no_previous_cost(self):
        order = self._order(
            [
                {"variant": variant.pk, "quantity": 1, "unit_cost": "5.00"}
                for variant in self.variants
            ]
        )
        response = self.client.get(reverse("purchaseorder-detail", args=[order.pk]))

        for payload, line in zip(response.data["lines"], order.lines.order_by("id")):
            self.assertIsNone(payload["previous_unit_cost"])
            self.assertFalse(payload["unit_cost_changed"])
            self.assertEqual(payload, {**payload, **self._cold_line_payload(line)})

    def test_previous_cost_lookup_does_not_scale_with_line_count(self):
        self._history()
        order = self._order(
            [
                {"variant": variant.pk, "quantity": 1, "unit_cost": "2.20"}
                for variant in self.variants
            ]
        )
        lines = list(order.lines.order_by("id"))

        serializer = PurchaseLineSerializer(many=True)
        with CaptureQueriesContext(connection) as queries:
            serializer.child.prime_previous_unit_costs(lines)
        # One correlated-subquery pass to find the previous line ids, one bulk
        # read to load them — flat, whatever the line count.
        self.assertEqual(len(queries), 2, [q["sql"] for q in queries])

        with CaptureQueriesContext(connection) as reads:
            for line in lines:
                serializer.child.get_previous_unit_cost(line)
        self.assertEqual(len(reads), 0, "primed lines must not re-query")
