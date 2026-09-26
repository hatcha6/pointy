"""A line's discount must live in the line's own rounding regime.

The discount engine rounds 2dp HALF_UP (``apps.discounts.services.money``) and
caps a line's discount at *its* subtotal; an order line rounds 2dp HALF_EVEN
(``OrderLine.line_subtotal``). On a gross landing exactly on a half-cent the two
disagree by a cent — 0.750 kg at 5.50 is 4.125, which the engine calls 4.13 and
the line calls 4.12 — so a discount that consumed the whole engine line arrived
at the order line a cent larger than the line could carry.

The order's own totals were right either way (``Order.recalculate`` clamps the
document discount to the subtotal), which is why this survived: only the *line*
was wrong, at ``line_total = -0.01``. What that cost is at the returns desk —
``adjustment_amount`` refuses a non-positive refund, so the goods could not be
handed back at all, and in a mixed return the negative line quietly ate a cent
of the customer's refund.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase

from apps.catalog.testing import create_product_with_default_variant
from apps.discounts.models import DiscountRule
from apps.inventory.models import StockItem
from apps.sales.models import RegisterSession
from apps.sales.services import (
    calculate_sales_discounts,
    checkout_order,
    expected_order_totals,
    line_refund_amount,
    return_order_items,
)


class HalfCentLineDiscountRegimeTests(TestCase):
    """0.750 kg at 5.50 — the worked example the regimes disagree on."""

    def setUp(self):
        self.user = get_user_model().objects.create_user(
            username="regime-cashier", password="pass"
        )
        self.session = RegisterSession.objects.create(
            owner=self.user, owner_key=f"user:{self.user.pk}"
        )
        # 5.50 a kg: 0.750 kg is 4.125, the half-cent.
        self.weighed = create_product_with_default_variant(
            sku="REGIME-KG", name="Weighed goods", unit_price=Decimal("5.50")
        )
        self.weighed.unit = "kg"
        self.weighed.save(update_fields=["unit"])
        StockItem.objects.create(
            variant=self.weighed.default_variant, quantity_on_hand=Decimal("100")
        )
        # A plain whole-price product, so a cart can hold a second line whose
        # gross is not a half-cent.
        self.plain = create_product_with_default_variant(
            sku="REGIME-PC", name="Plain goods", unit_price=Decimal("2.00")
        )
        StockItem.objects.create(
            variant=self.plain.default_variant, quantity_on_hand=Decimal("100")
        )

    def _free_the_weighed_product(self):
        rule = DiscountRule.objects.create(
            name="Free by the kilo",
            channel=DiscountRule.Channel.SALES,
            scope=DiscountRule.Scope.LINE,
            value_type=DiscountRule.ValueType.PERCENTAGE,
            value=Decimal("100"),
        )
        rule.products.set([self.weighed])
        return rule

    def _checkout(self, lines_data, paid):
        # A free cart takes no tender, as at the till: a zero payment is refused.
        return checkout_order(
            register_session=self.session,
            lines_data=lines_data,
            payments_data=[{"method": "cash", "amount": paid}] if paid > 0 else [],
        )

    def test_a_fully_discounted_half_cent_line_is_not_over_discounted(self):
        self._free_the_weighed_product()
        order = self._checkout(
            [
                {
                    "variant": self.weighed.default_variant,
                    "quantity": Decimal("0.750"),
                }
            ],
            Decimal("0.00"),
        )
        line = order.lines.get()
        # The engine's own cap for this line is 4.13; the line holds 4.12.
        self.assertEqual(line.line_subtotal, Decimal("4.12"))
        self.assertEqual(line.discount_total, Decimal("4.12"))
        self.assertEqual(line.line_total, Decimal("0.00"))
        self.assertGreaterEqual(line.line_total, Decimal("0.00"))

    def test_a_cart_pays_for_the_goods_it_is_charged_for(self):
        """The other side of the same cent, at the document.

        ``expected_order_totals`` summed the engine's raw allocations, so the
        4.13 the engine put on a line worth 4.12 came off the whole cart: 6.00
        of plain goods next to the free item was rung up at 5.99. The customer
        must pay for exactly what is not free.
        """
        self._free_the_weighed_product()
        lines_data = [
            {"variant": self.weighed.default_variant, "quantity": Decimal("0.750")},
            {"variant": self.plain.default_variant, "quantity": Decimal("3")},
        ]
        discount_result = calculate_sales_discounts(lines_data=lines_data)
        # The engine's own view of the free line is unchanged — it is right in
        # its own domain, and this fix does not touch it.
        self.assertEqual(discount_result.discount_total, Decimal("4.13"))

        subtotal, discount_total, total = expected_order_totals(
            lines_data, discount_result
        )
        self.assertEqual(subtotal, Decimal("10.12"))
        self.assertEqual(discount_total, Decimal("4.12"))
        self.assertEqual(total, Decimal("6.00"))

        # And the order the till actually writes agrees with the quote, which is
        # the property that keeps checkout from refusing the payment the preview
        # asked for.
        order = self._checkout(lines_data, total)
        self.assertEqual(
            (order.subtotal, order.discount_total, order.total),
            (subtotal, discount_total, total),
        )

    def test_a_single_line_cart_is_unaffected(self):
        """Nothing moves when there is nothing to move it onto: a solo free
        line still rings up at 0.00, exactly as before."""
        self._free_the_weighed_product()
        order = self._checkout(
            [
                {
                    "variant": self.weighed.default_variant,
                    "quantity": Decimal("0.750"),
                }
            ],
            Decimal("0.00"),
        )
        self.assertEqual(
            (order.subtotal, order.discount_total, order.total),
            (Decimal("4.12"), Decimal("4.12"), Decimal("0.00")),
        )

    def test_line_discounts_sum_to_the_order_discount(self):
        """``sum(lines) == document`` — the identity an over-discounted line
        breaks, and the one ``Order.recalculate``'s defensive clamp hides."""
        self._free_the_weighed_product()
        order = self._checkout(
            [
                {
                    "variant": self.weighed.default_variant,
                    "quantity": Decimal("0.750"),
                },
                {"variant": self.plain.default_variant, "quantity": Decimal("3")},
            ],
            Decimal("6.00"),
        )
        lines = list(order.lines.all())
        self.assertEqual(
            sum((line.discount_total for line in lines), Decimal("0.00")),
            order.discount_total,
        )
        self.assertEqual(
            sum((line.line_total for line in lines), Decimal("0.00")),
            order.total,
        )
        for line in lines:
            self.assertLessEqual(line.discount_total, line.line_subtotal)

    def test_returning_a_free_line_credits_nothing_rather_than_minus_a_cent(self):
        """The returns desk. A refund line worth -0.01 is not merely a display
        bug: ``adjustment_amount`` refuses a non-positive refund, so a solo
        return of these goods is rejected, and in a mixed return the negative
        line takes a cent off what the customer gets back."""
        self._free_the_weighed_product()
        order = self._checkout(
            [
                {
                    "variant": self.weighed.default_variant,
                    "quantity": Decimal("0.750"),
                },
                {"variant": self.plain.default_variant, "quantity": Decimal("3")},
            ],
            Decimal("6.00"),
        )
        weighed_line = order.lines.get(variant=self.weighed.default_variant)
        plain_line = order.lines.get(variant=self.plain.default_variant)
        self.assertEqual(
            line_refund_amount(weighed_line, Decimal("0.750")), Decimal("0.00")
        )

        adjustment = return_order_items(
            order=order,
            lines=[
                (weighed_line, Decimal("0.750")),
                (plain_line, Decimal("3")),
            ],
            reason="regression",
            register_session=self.session,
        )
        # The customer paid 6.00 and gets 6.00 back, not 5.99.
        self.assertEqual(adjustment.amount, Decimal("6.00"))
        self.assertEqual(
            sum(
                (line.line_total for line in adjustment.lines.all()),
                Decimal("0.00"),
            ),
            adjustment.amount,
        )
        for line in adjustment.lines.all():
            self.assertGreaterEqual(line.line_total, Decimal("0.00"))


class PartialReturnOfAFreeLineTests(TestCase):
    """The second half: even with the line capped, a *part* of a fully
    discounted line rounds its own share, and the share can land a cent above
    the gross it is subtracted from."""

    def setUp(self):
        self.user = get_user_model().objects.create_user(
            username="partial-cashier", password="pass"
        )
        self.session = RegisterSession.objects.create(
            owner=self.user, owner_key=f"user:{self.user.pk}"
        )
        # 3.33 a kg. 1.500 kg is 4.995 -> the line stores 5.00; returning
        # 0.500 kg is a 1.67 share of that discount against a 1.66 gross.
        self.weighed = create_product_with_default_variant(
            sku="PARTIAL-KG", name="Weighed goods", unit_price=Decimal("3.33")
        )
        self.weighed.unit = "kg"
        self.weighed.save(update_fields=["unit"])
        StockItem.objects.create(
            variant=self.weighed.default_variant, quantity_on_hand=Decimal("100")
        )
        self.plain = create_product_with_default_variant(
            sku="PARTIAL-PC", name="Plain goods", unit_price=Decimal("2.00")
        )
        StockItem.objects.create(
            variant=self.plain.default_variant, quantity_on_hand=Decimal("100")
        )
        rule = DiscountRule.objects.create(
            name="Free by the kilo",
            channel=DiscountRule.Channel.SALES,
            scope=DiscountRule.Scope.LINE,
            value_type=DiscountRule.ValueType.PERCENTAGE,
            value=Decimal("100"),
        )
        rule.products.set([self.weighed])

    def test_a_part_of_a_free_line_never_credits_less_than_nothing(self):
        order = checkout_order(
            register_session=self.session,
            lines_data=[
                {
                    "variant": self.weighed.default_variant,
                    "quantity": Decimal("1.500"),
                },
                {"variant": self.plain.default_variant, "quantity": Decimal("2")},
            ],
            payments_data=[{"method": "cash", "amount": Decimal("4.00")}],
        )
        weighed_line = order.lines.get(variant=self.weighed.default_variant)
        self.assertEqual(weighed_line.line_subtotal, Decimal("5.00"))
        self.assertEqual(weighed_line.discount_total, Decimal("5.00"))
        # 0.500 kg of it: gross 1.66, proportional share of the discount 1.67.
        self.assertEqual(
            line_refund_amount(weighed_line, Decimal("0.500")), Decimal("0.00")
        )

    def test_a_partial_return_of_a_free_line_pays_the_rest_in_full(self):
        order = checkout_order(
            register_session=self.session,
            lines_data=[
                {
                    "variant": self.weighed.default_variant,
                    "quantity": Decimal("1.500"),
                },
                {"variant": self.plain.default_variant, "quantity": Decimal("2")},
            ],
            payments_data=[{"method": "cash", "amount": Decimal("4.00")}],
        )
        weighed_line = order.lines.get(variant=self.weighed.default_variant)
        plain_line = order.lines.get(variant=self.plain.default_variant)
        adjustment = return_order_items(
            order=order,
            lines=[
                (weighed_line, Decimal("0.500")),
                (plain_line, Decimal("2")),
            ],
            reason="regression",
            register_session=self.session,
        )
        # The free half-kilo is worth nothing; the 4.00 of plain goods is worth
        # 4.00, and the customer must not be shorted the cent.
        self.assertEqual(adjustment.amount, Decimal("4.00"))
        self.assertEqual(
            sum(
                (line.line_total for line in adjustment.lines.all()),
                Decimal("0.00"),
            ),
            adjustment.amount,
        )
