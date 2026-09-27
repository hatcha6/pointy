"""A line keyed as a total is saved as that total.

Field telemetry, one back office, 22–26 September 2026: the buyer keys what the
supplier's paper says — "15 loaves, 58.00" — and the screen divides it into a
unit cost, 3.8666…. The unit cost went to the server as 3.87 and was stored in
a two-place column, so the order read 58.05. A 107-line delivery keyed the same
way was shown to the buyer as 28,769.22 and saved as 28,797.96. The shop then
owed its supplier a figure no invoice ever said.

A unit cost is a rate, so it keeps six places (like the stock ledger's rates);
only money — line totals, the subtotal, what is owed — is rounded to two.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.inventory.models import StockLedgerEntry

from .models import PurchaseOrder, Supplier
from .services import purchase_adjustable_line_value
from .unit_costs import cost_string


class PurchaseUnitCostPrecisionTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        user = get_user_model().objects.create_user(username="buyer", password="pass")
        user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=user)
        self.supplier = Supplier.objects.create(name="مشتريات عامة")

    def _variant(self, index=0, unit_price=Decimal("5.00")):
        return create_product_with_default_variant(
            sku=f"LOAF-{index}",
            barcode="",
            name=f"خبزة {index}",
            unit_price=unit_price,
        ).default_variant

    def _create(self, lines, **extra):
        response = self.client.post(
            reverse("purchaseorder-list"),
            {"supplier": self.supplier.pk, "lines": lines, **extra},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        return response

    def test_fifteen_for_58_is_saved_as_58(self):
        """The field case, exactly: 58.00 over 15 is 3.866667 each."""
        variant = self._variant()

        response = self._create(
            [{"variant": variant.pk, "quantity": "15.000", "unit_cost": "3.866667"}]
        )

        order = PurchaseOrder.objects.get(pk=response.data["id"])
        self.assertEqual(order.subtotal, Decimal("58.00"))
        self.assertEqual(order.total, Decimal("58.00"))
        line = response.data["lines"][0]
        self.assertEqual(line["unit_cost"], "3.866667")
        self.assertEqual(line["line_total"], "58.00")
        self.assertEqual(line["net_line_total"], "58.00")

    def test_a_long_order_keyed_by_totals_adds_up_to_what_was_keyed(self):
        """Many lines, each a round total over an awkward count — the shape of
        the 107-line delivery that drifted by 28.74."""
        keyed = [
            (Decimal("190.00"), 12),
            (Decimal("260.00"), 24),
            (Decimal("130.00"), 12),
            (Decimal("110.00"), 24),
            (Decimal("171.00"), 600),
            (Decimal("800.00"), 120),
            (Decimal("175.00"), 288),
            (Decimal("1130.00"), 240),
        ]
        lines = []
        for index, (total, quantity) in enumerate(keyed):
            unit_cost = (total / quantity).quantize(Decimal("0.000001"))
            lines.append(
                {
                    "variant": self._variant(index).pk,
                    "quantity": f"{quantity}.000",
                    "unit_cost": f"{unit_cost}",
                }
            )

        response = self._create(lines, acknowledge_cost_warnings=True)

        order = PurchaseOrder.objects.get(pk=response.data["id"])
        self.assertEqual(order.total, sum(total for total, _ in keyed))
        self.assertEqual(
            [line["line_total"] for line in response.data["lines"]],
            [f"{total:.2f}" for total, _ in keyed],
        )

    def test_the_preview_quotes_the_total_the_save_writes(self):
        variant = self._variant()
        lines = [{"variant": variant.pk, "quantity": "15", "unit_cost": "3.866667"}]

        preview = self.client.post(
            reverse("purchaseorder-discount-preview"),
            {"supplier": self.supplier.pk, "lines": lines},
            format="json",
        )

        self.assertEqual(preview.status_code, status.HTTP_200_OK, preview.data)
        self.assertEqual(preview.data["lines"][0]["line_total"], "58.00")
        self.assertEqual(preview.data["lines"][0]["unit_cost"], "3.866667")
        saved = PurchaseOrder.objects.get(pk=self._create(lines).data["id"])
        self.assertEqual(saved.total, Decimal("58.00"))

    def test_an_ordinary_cost_still_reads_as_money(self):
        """Six places are for the arithmetic; "12.50" must not become
        "12.500000" in every response a client already parses."""
        variant = self._variant()

        response = self._create(
            [{"variant": variant.pk, "quantity": "2", "unit_cost": "12.50"}]
        )

        line = response.data["lines"][0]
        self.assertEqual(line["unit_cost"], "12.50")
        self.assertEqual(line["net_unit_cost"], "12.50")
        self.assertEqual(line["effective_unit_cost"], "12.50")

    def test_a_two_place_client_is_still_accepted(self):
        """Tills on the frozen build send two places; nothing changes for them."""
        variant = self._variant()

        response = self._create(
            [{"variant": variant.pk, "quantity": "15", "unit_cost": "3.87"}]
        )

        self.assertEqual(response.data["lines"][0]["line_total"], "58.05")

    def _received_order(self, variant):
        response = self._create(
            [{"variant": variant.pk, "quantity": "15", "unit_cost": "3.866667"}]
        )
        order_id = response.data["id"]
        submitted = self.client.post(reverse("purchaseorder-submit", args=[order_id]))
        self.assertEqual(submitted.status_code, status.HTTP_200_OK, submitted.data)
        received = self.client.post(
            reverse("purchaseorder-receive", args=[order_id]), {}, format="json"
        )
        self.assertEqual(received.status_code, status.HTTP_200_OK, received.data)
        return PurchaseOrder.objects.get(pk=order_id)

    def test_receiving_books_the_stock_at_what_was_paid(self):
        """Valuation follows the same exact rate, so the shelf carries 58.00
        of bread against the 58.00 owed — not 58.05."""
        variant = self._variant()
        self._received_order(variant)

        booked = sum(
            entry.value_change
            for entry in StockLedgerEntry.objects.filter(variant=variant)
        )
        self.assertEqual(booked.quantize(Decimal("0.01")), Decimal("58.00"))

    def test_a_full_return_credits_what_was_paid(self):
        order = self._received_order(self._variant())

        self.assertEqual(
            purchase_adjustable_line_value(order.lines.get()), Decimal("58.00")
        )

    def test_cost_string_keeps_two_places_and_drops_the_rest_of_the_zeros(self):
        self.assertEqual(cost_string(Decimal("12.5")), "12.50")
        self.assertEqual(cost_string(Decimal("12.500000")), "12.50")
        self.assertEqual(cost_string(Decimal("3.8666666")), "3.866667")
        self.assertEqual(cost_string(Decimal("0.416667")), "0.416667")
        self.assertEqual(cost_string(Decimal("1.545")), "1.545")
        self.assertEqual(cost_string(Decimal("0")), "0.00")
