"""A supplier exchange must hand back the units it took.

``PurchaseOrderAdjustmentReplacementLine`` carries no unit: it is keyed by
variant alone, and ``record_purchase_replacement_stock_movements`` adds its
``quantity`` straight to ``quantity_on_hand``. Its quantity and unit cost are
therefore per **base** unit, while the outbound purchase line it mirrors is
denominated in that line's purchase unit — a carton of 24.

The like-for-like default (an exchange posted without ``replacement_lines``)
copied the pack figures across unconverted, so exchanging one carton took 24
bottles out of stock and put 1 back. The money said the swap was value-neutral,
which is why nothing else noticed.
"""

from decimal import Decimal

from django.urls import reverse
from rest_framework import status

from apps.inventory.models import StockItem
from apps.inventory.models import StockMovement
from apps.purchasing.models import PurchaseOrder
from apps.purchasing.test_units import PurchaseUnitTestCase


class PackExchangeStockConservationTests(PurchaseUnitTestCase):
    """Soda, purchased by the carton of 24 (see ``PurchaseUnitTestCase``)."""

    def _received_order(self, *, quantity=3, unit="carton", unit_cost="48.00"):
        create = self.client.post(
            reverse("purchaseorder-list"),
            {
                "supplier": self.supplier.pk,
                "lines": [
                    {
                        "variant": self.variant.pk,
                        "quantity": quantity,
                        "unit": unit,
                        "unit_cost": unit_cost,
                    }
                ],
            },
            format="json",
        )
        self.assertEqual(create.status_code, status.HTTP_201_CREATED, create.data)
        order_id = create.data["id"]
        self.client.post(reverse("purchaseorder-submit", args=[order_id]), format="json")
        received = self.client.post(
            reverse("purchaseorder-receive", args=[order_id]), format="json"
        )
        self.assertEqual(received.status_code, status.HTTP_200_OK, received.data)
        self.assertEqual(received.data["status"], PurchaseOrder.Status.RECEIVED)
        return order_id, create.data["lines"][0]["id"]

    def _on_hand(self):
        return StockItem.objects.get(variant=self.variant).quantity_on_hand

    def _exchange(self, order_id, line_id, quantity, **payload):
        response = self.client.post(
            reverse("purchaseorder-exchange-items", args=[order_id]),
            {"lines": [{"line": line_id, "quantity": quantity}], **payload},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        return response.data["adjustments"][0]

    def setUp(self):
        super().setUp()
        StockItem.objects.create(variant=self.variant, quantity_on_hand=Decimal("0"))

    def test_like_for_like_pack_exchange_leaves_stock_untouched(self):
        order_id, line_id = self._received_order()
        self.assertEqual(self._on_hand(), Decimal("72.000"))

        self._exchange(order_id, line_id, 1)

        # One carton out, one carton back: 24 bottles must return, not 1.
        self.assertEqual(self._on_hand(), Decimal("72.000"))

    def test_replacement_line_is_denominated_in_base_units(self):
        order_id, line_id = self._received_order()

        adjustment = self._exchange(order_id, line_id, 1)

        replacement = adjustment["replacement_lines"][0]
        self.assertEqual(Decimal(replacement["quantity"]), Decimal("24.000"))
        # 48.00 a carton ÷ 24 = 2.00 a bottle.
        self.assertEqual(replacement["unit_cost"], "2.00")
        self.assertEqual(replacement["line_total"], "48.00")

    def test_exchange_stays_value_neutral(self):
        order_id, line_id = self._received_order()

        adjustment = self._exchange(order_id, line_id, 1)

        self.assertEqual(adjustment["outbound_amount"], "48.00")
        self.assertEqual(adjustment["replacement_amount"], "48.00")
        self.assertEqual(adjustment["net_amount"], "0.00")

    def test_both_stock_movements_are_written_in_base_units(self):
        order_id, line_id = self._received_order()

        self._exchange(order_id, line_id, 2)

        outbound = StockMovement.objects.filter(
            variant=self.variant,
            movement_type=StockMovement.Type.DECREASE,
            note__contains="استبدال",
        ).latest("id")
        replacement = StockMovement.objects.filter(
            variant=self.variant,
            movement_type=StockMovement.Type.INCREASE,
            note__contains="استلام بديل",
        ).latest("id")
        self.assertEqual(outbound.quantity, Decimal("48.000"))
        self.assertEqual(replacement.quantity, Decimal("48.000"))
        self.assertEqual(replacement.on_hand_after, Decimal("72.000"))

    def test_exchange_consumes_the_adjustable_quantity_in_pack_units(self):
        """The outbound side stays in packs — it is what ``accepted_quantity``
        counts, so only the replacement crosses into base units."""
        order_id, line_id = self._received_order()

        adjustment = self._exchange(order_id, line_id, 1)

        self.assertEqual(Decimal(adjustment["lines"][0]["quantity"]), Decimal("1.000"))
        detail = self.client.get(reverse("purchaseorder-detail", args=[order_id]))
        self.assertEqual(
            Decimal(detail.data["lines"][0]["adjustable_quantity"]), Decimal("2")
        )

    def test_repeated_pack_exchanges_each_return_their_own_units(self):
        order_id, line_id = self._received_order()

        self._exchange(order_id, line_id, 1)
        self.assertEqual(self._on_hand(), Decimal("72.000"))
        self._exchange(order_id, line_id, 2)
        self.assertEqual(self._on_hand(), Decimal("72.000"))

    def test_explicit_replacement_lines_are_left_alone(self):
        """A caller that names its own replacement already speaks base units."""
        order_id, line_id = self._received_order()

        adjustment = self._exchange(
            order_id,
            line_id,
            1,
            replacement_lines=[
                {
                    "variant": self.variant.pk,
                    "quantity": "24",
                    "unit_cost": "2.00",
                }
            ],
        )

        self.assertEqual(self._on_hand(), Decimal("72.000"))
        self.assertEqual(adjustment["replacement_amount"], "48.00")

    def test_single_unit_line_is_unaffected(self):
        """The factor-1 case every existing test covers must not move."""
        order_id, line_id = self._received_order(
            quantity=6, unit="", unit_cost="2.00"
        )
        self.assertEqual(self._on_hand(), Decimal("6.000"))

        adjustment = self._exchange(order_id, line_id, 2)

        self.assertEqual(self._on_hand(), Decimal("6.000"))
        replacement = adjustment["replacement_lines"][0]
        self.assertEqual(Decimal(replacement["quantity"]), Decimal("2.000"))
        self.assertEqual(replacement["unit_cost"], "2.00")
        self.assertEqual(adjustment["net_amount"], "0.00")

    def test_return_already_removed_base_units(self):
        """The outbound half was always right — pinned so a fix to the
        replacement half cannot quietly change it."""
        order_id, line_id = self._received_order()

        response = self.client.post(
            reverse("purchaseorder-return-items", args=[order_id]),
            {"lines": [{"line": line_id, "quantity": 1}]},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(self._on_hand(), Decimal("48.000"))
        self.assertEqual(response.data["adjustments"][0]["outbound_amount"], "48.00")
