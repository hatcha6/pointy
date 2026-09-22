"""The cashier's own discount on one invoice, and the ceiling over it.

Two things are being proved here, and only one of them is the feature.

The feature is small: a cashier haggles, types a number, and the sale is that
much cheaper. The ceiling in ``ShopSettings.max_invoice_discount_amount`` bounds
it so the shop decides how much authority the counter has.

The thing worth testing is where the number *goes*. It is recorded on the order
(``Order.extra_discount_amount``) but applied to the **lines**, spread across
them by ``services.order_line_discounts``. That is not an implementation detail
— it is the difference between this feature being correct everywhere and being
correct in one place and wrong in forty. ``OrderLine.discount_total`` is what
the Z-Report sums, what every per-product and per-category rollup subtracts,
what profit is measured against, and what the returns desk credits a customer
for goods handed back. A discount that lived only on the document would leave
every one of those overstating revenue and margin by exactly this number, and
would refund a customer more than they ever paid.

``PurchaseOrder.extra_discount_amount`` learned this the hard way on the buying
side; these tests are the sales side refusing to learn it twice.
"""

from datetime import date, timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.core.cache import cache
from django.test import TestCase, override_settings
from django.urls import reverse
from rest_framework import status
from rest_framework.exceptions import ValidationError
from rest_framework.test import APIClient

from apps.catalog.testing import create_product_with_default_variant
from apps.core.models import ShopSettings
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.discounts.models import DiscountRule
from apps.reports.builders.sales import MANUAL_DISCOUNT_ROW_NAME
from apps.reports.services import generate_report_payload
from apps.inventory.models import StockItem, StockValuationBin, Warehouse
from apps.sales.models import Order, RegisterSession
from apps.sales.register_summary import build_register_session_summary
from apps.sales.services import (
    calculate_sales_discounts,
    checkout_order,
    clamped_manual_discount,
    expected_order_totals,
    line_refund_amount,
    manual_discount_room,
    order_line_discounts,
    return_order_items,
    validate_manual_discount_allowed,
)


@override_settings(
    CACHES={
        "default": {
            "BACKEND": "django.core.cache.backends.locmem.LocMemCache",
            "LOCATION": "invoice-discount-tests",
        }
    }
)
class InvoiceDiscountTestCase(TestCase):
    def setUp(self):
        self.user = get_user_model().objects.create_user(
            username="haggling-cashier", password="pass"
        )
        self.session = RegisterSession.objects.create(
            owner=self.user, owner_key=f"user:{self.user.pk}"
        )
        self.settings = ShopSettings.load()
        # Off, so a line sold under cost is not refused by a guard this file is
        # not testing. One test below turns it back on deliberately.
        self.settings.prevent_selling_at_loss = False
        self.settings.save(update_fields=["prevent_selling_at_loss"])

    def _product(self, sku, price, *, cost=None, quantity=100):
        """A sellable product, optionally with a known cost.

        The cost is written straight into the valuation bin, because that bin is
        what ``valuation_unit_costs`` reads and therefore exactly what the loss
        guard compares a discounted line against.
        """
        product = create_product_with_default_variant(
            sku=sku, name=f"Product {sku}", unit_price=Decimal(price)
        )
        variant = product.default_variant
        quantity = Decimal(quantity)
        StockItem.objects.create(variant=variant, quantity_on_hand=quantity)
        if cost is not None:
            StockValuationBin.objects.update_or_create(
                variant=variant,
                warehouse_id=Warehouse.default_id(),
                defaults={
                    "quantity": quantity,
                    "stock_value": Decimal(cost) * quantity,
                    "valuation_rate": Decimal(cost),
                },
            )
        return product

    def _checkout(self, lines_data, paid, **kwargs):
        return checkout_order(
            register_session=self.session,
            lines_data=lines_data,
            payments_data=(
                [{"method": "cash", "amount": paid}]
                if Decimal(paid) > 0
                else []
            ),
            **kwargs,
        )


class ManualDiscountReachesTheLinesTests(InvoiceDiscountTestCase):
    """Where the number lands — the property the whole design rests on."""

    def setUp(self):
        super().setUp()
        self.apples = self._product("HAG-APPLE", "10.00")
        self.bread = self._product("HAG-BREAD", "5.00")

    def test_the_sale_is_cheaper_by_what_the_cashier_typed(self):
        order = self._checkout(
            [
                {"variant": self.apples.default_variant, "quantity": Decimal("1")},
                {"variant": self.bread.default_variant, "quantity": Decimal("1")},
            ],
            Decimal("12.00"),
            extra_discount_amount=Decimal("3.00"),
        )

        self.assertEqual(order.subtotal, Decimal("15.00"))
        self.assertEqual(order.discount_total, Decimal("3.00"))
        self.assertEqual(order.extra_discount_amount, Decimal("3.00"))
        self.assertEqual(order.total, Decimal("12.00"))

    def test_the_lines_carry_it_so_every_other_sum_is_right(self):
        """The document total is the easy half. This is the half that matters:
        the discount has to be *on the lines*, or the Z-Report, the rollups,
        profit and the returns desk all go on quoting the undiscounted sale."""
        order = self._checkout(
            [
                {"variant": self.apples.default_variant, "quantity": Decimal("1")},
                {"variant": self.bread.default_variant, "quantity": Decimal("1")},
            ],
            Decimal("12.00"),
            extra_discount_amount=Decimal("3.00"),
        )

        lines = {line.variant.sku: line for line in order.lines.all()}
        # Weighted by what each line is worth: 10 and 5 of a 15 cart take 2.00
        # and 1.00 of a 3.00 discount.
        self.assertEqual(lines["HAG-APPLE"].discount_total, Decimal("2.00"))
        self.assertEqual(lines["HAG-BREAD"].discount_total, Decimal("1.00"))
        self.assertEqual(
            sum(line.discount_total for line in order.lines.all()),
            order.discount_total,
        )
        # And the per-line money the rollups read follows from it.
        self.assertEqual(lines["HAG-APPLE"].line_total, Decimal("8.00"))
        self.assertEqual(lines["HAG-BREAD"].line_total, Decimal("4.00"))

    def test_profit_is_measured_against_the_discounted_revenue(self):
        order = self._checkout(
            [{"variant": self.apples.default_variant, "quantity": Decimal("1")}],
            Decimal("7.00"),
            extra_discount_amount=Decimal("3.00"),
        )
        line = order.lines.get()

        # Whatever the goods cost, the margin is measured against 7.00 — the
        # money that actually came in — not the 10.00 on the shelf edge.
        self.assertEqual(line.line_total, Decimal("7.00"))
        self.assertEqual(line.line_profit, line.line_total - line.line_cost)
        self.assertEqual(order.total_profit, order.total - order.total_cost)

    def test_not_one_cent_is_created_or_lost_splitting_it(self):
        """Three lines and an amount that does not divide by three."""
        third = self._product("HAG-THIRD", "10.00")
        order = self._checkout(
            [
                {"variant": self.apples.default_variant, "quantity": Decimal("1")},
                {"variant": self.bread.default_variant, "quantity": Decimal("1")},
                {"variant": third.default_variant, "quantity": Decimal("1")},
            ],
            Decimal("24.99"),
            extra_discount_amount=Decimal("0.01"),
        )

        self.assertEqual(order.discount_total, Decimal("0.01"))
        self.assertEqual(
            sum(line.discount_total for line in order.lines.all()),
            Decimal("0.01"),
        )
        self.assertEqual(order.total, Decimal("24.99"))

    def test_a_rounder_split_still_sums_to_the_typed_amount(self):
        third = self._product("HAG-THIRD", "10.00")
        order = self._checkout(
            [
                {"variant": self.apples.default_variant, "quantity": Decimal("1")},
                {"variant": self.bread.default_variant, "quantity": Decimal("1")},
                {"variant": third.default_variant, "quantity": Decimal("1")},
            ],
            Decimal("24.00"),
            extra_discount_amount=Decimal("1.00"),
        )

        self.assertEqual(
            sum(line.discount_total for line in order.lines.all()),
            Decimal("1.00"),
        )
        self.assertEqual(order.total, Decimal("24.00"))


class ManualDiscountWithTheEngineTests(InvoiceDiscountTestCase):
    """The cashier's number on top of the owner's rules — added, never doubled."""

    def setUp(self):
        super().setUp()
        self.apples = self._product("MIX-APPLE", "10.00")
        self.bread = self._product("MIX-BREAD", "5.00")
        rule = DiscountRule.objects.create(
            name="Ten percent off apples",
            channel=DiscountRule.Channel.SALES,
            scope=DiscountRule.Scope.LINE,
            value_type=DiscountRule.ValueType.PERCENTAGE,
            value=Decimal("10"),
        )
        rule.products.set([self.apples])

    def test_both_discounts_land_and_the_total_counts_each_once(self):
        lines_data = [
            {"variant": self.apples.default_variant, "quantity": Decimal("1")},
            {"variant": self.bread.default_variant, "quantity": Decimal("1")},
        ]
        order = self._checkout(
            lines_data, Decimal("12.00"), extra_discount_amount=Decimal("2.00")
        )

        # 15.00 of goods, 1.00 off by rule, 2.00 off by the cashier.
        self.assertEqual(order.subtotal, Decimal("15.00"))
        self.assertEqual(order.discount_total, Decimal("3.00"))
        self.assertEqual(order.extra_discount_amount, Decimal("2.00"))
        self.assertEqual(order.total, Decimal("12.00"))
        self.assertEqual(
            sum(line.discount_total for line in order.lines.all()),
            Decimal("3.00"),
        )

    def test_the_manual_share_follows_what_a_line_still_costs(self):
        """Weighted by the room left after the rules, not by the shelf price:
        a line the engine already emptied cannot absorb any more."""
        lines_data = [
            {"variant": self.apples.default_variant, "quantity": Decimal("1")},
            {"variant": self.bread.default_variant, "quantity": Decimal("1")},
        ]
        discounts = order_line_discounts(
            lines_data,
            calculate_sales_discounts(lines_data=lines_data),
            Decimal("7.00"),
        )

        # After the rule: apples have 9.00 of room, bread 5.00, 14.00 in all.
        # 7.00 splits exactly half and half: 4.50 and 2.50.
        self.assertEqual(discounts["0"], Decimal("1.00") + Decimal("4.50"))
        self.assertEqual(discounts["1"], Decimal("2.50"))
        self.assertEqual(sum(discounts.values()), Decimal("8.00"))


class ManualDiscountIsBoundedByTheCartTests(InvoiceDiscountTestCase):
    """A sale cannot charge less than nothing, whatever was typed."""

    def setUp(self):
        super().setUp()
        self.apples = self._product("CAP-APPLE", "10.00")

    def test_a_discount_larger_than_the_cart_is_held_to_the_cart(self):
        order = self._checkout(
            [{"variant": self.apples.default_variant, "quantity": Decimal("1")}],
            Decimal("0.00"),
            extra_discount_amount=Decimal("999.00"),
        )

        self.assertEqual(order.total, Decimal("0.00"))
        self.assertEqual(order.discount_total, Decimal("10.00"))
        self.assertEqual(order.lines.get().line_total, Decimal("0.00"))

    def test_the_column_records_the_discount_actually_given(self):
        """Not the figure that was typed. The receipt prints this column and an
        owner reads it back; a 999 against a ten dinar sale is a lie about what
        happened, and it would not add up against ``discount_total``."""
        order = self._checkout(
            [{"variant": self.apples.default_variant, "quantity": Decimal("1")}],
            Decimal("0.00"),
            extra_discount_amount=Decimal("999.00"),
        )

        self.assertEqual(order.extra_discount_amount, Decimal("10.00"))

    def test_no_line_is_ever_discounted_below_zero(self):
        cheap = self._product("CAP-CHEAP", "0.50")
        order = self._checkout(
            [
                {"variant": self.apples.default_variant, "quantity": Decimal("1")},
                {"variant": cheap.default_variant, "quantity": Decimal("1")},
            ],
            Decimal("0.00"),
            extra_discount_amount=Decimal("10.50"),
        )

        for line in order.lines.all():
            self.assertGreaterEqual(line.line_total, Decimal("0.00"))
            self.assertLessEqual(line.discount_total, line.line_subtotal)

    def test_room_is_what_the_goods_are_worth_after_the_rules(self):
        rule = DiscountRule.objects.create(
            name="Half off",
            channel=DiscountRule.Channel.SALES,
            scope=DiscountRule.Scope.LINE,
            value_type=DiscountRule.ValueType.PERCENTAGE,
            value=Decimal("50"),
        )
        rule.products.set([self.apples])
        lines_data = [
            {"variant": self.apples.default_variant, "quantity": Decimal("1")}
        ]
        discount_result = calculate_sales_discounts(lines_data=lines_data)

        self.assertEqual(
            manual_discount_room(lines_data, discount_result), Decimal("5.00")
        )
        self.assertEqual(
            clamped_manual_discount(
                lines_data, discount_result, Decimal("40.00")
            ),
            Decimal("5.00"),
        )


class InvoiceDiscountCeilingTests(InvoiceDiscountTestCase):
    """``ShopSettings.max_invoice_discount_amount`` — how much the counter may
    decide on its own."""

    def _set_ceiling(self, value):
        self.settings.max_invoice_discount_amount = value
        self.settings.save(update_fields=["max_invoice_discount_amount"])
        return ShopSettings.load()

    def test_no_ceiling_by_default_so_an_update_changes_nothing(self):
        self.assertIsNone(ShopSettings.load().max_invoice_discount_amount)
        validate_manual_discount_allowed(
            Decimal("5000.00"), settings=ShopSettings.load()
        )

    def test_a_discount_at_the_ceiling_is_allowed(self):
        settings = self._set_ceiling(Decimal("20.00"))
        validate_manual_discount_allowed(Decimal("20.00"), settings=settings)

    def test_a_discount_over_the_ceiling_is_refused(self):
        settings = self._set_ceiling(Decimal("20.00"))
        with self.assertRaises(ValidationError) as caught:
            validate_manual_discount_allowed(Decimal("20.01"), settings=settings)

        self.assertIn("extra_discount_amount", caught.exception.detail)

    def test_a_zero_ceiling_means_the_counter_does_not_discount(self):
        settings = self._set_ceiling(Decimal("0.00"))
        with self.assertRaises(ValidationError):
            validate_manual_discount_allowed(Decimal("0.01"), settings=settings)
        # ...and nothing is still nothing.
        validate_manual_discount_allowed(Decimal("0.00"), settings=settings)

    def test_the_ceiling_is_judged_before_the_cart_clamps_it(self):
        """A 500 discount typed against a 10 dinar cart is over a 20 ceiling,
        even though the cart could only ever have absorbed 10 of it. Clamping
        first would let every over-ceiling amount through on a small sale —
        which is most sales."""
        settings = self._set_ceiling(Decimal("20.00"))
        with self.assertRaises(ValidationError):
            validate_manual_discount_allowed(Decimal("500.00"), settings=settings)


class ManualDiscountAtTheReturnsDeskTests(InvoiceDiscountTestCase):
    """The conservation law: a line handed back cancels its own sale, term for
    term. A customer is credited what they paid for the goods — not the shelf
    price they were never charged."""

    def setUp(self):
        super().setUp()
        self.apples = self._product("RET-APPLE", "10.00")
        self.bread = self._product("RET-BREAD", "5.00")

    def test_a_returned_line_is_credited_net_of_the_haggle(self):
        order = self._checkout(
            [
                {"variant": self.apples.default_variant, "quantity": Decimal("1")},
                {"variant": self.bread.default_variant, "quantity": Decimal("1")},
            ],
            Decimal("12.00"),
            extra_discount_amount=Decimal("3.00"),
        )
        apples_line = order.lines.get(variant=self.apples.default_variant)

        # The apples took 2.00 of the 3.00, so they were sold for 8.00.
        self.assertEqual(
            line_refund_amount(apples_line, Decimal("1")), Decimal("8.00")
        )

    def test_returning_the_whole_sale_refunds_exactly_what_was_paid(self):
        order = self._checkout(
            [
                {"variant": self.apples.default_variant, "quantity": Decimal("1")},
                {"variant": self.bread.default_variant, "quantity": Decimal("1")},
            ],
            Decimal("12.00"),
            extra_discount_amount=Decimal("3.00"),
        )
        adjustment = return_order_items(
            order=order,
            lines=[(line, line.quantity) for line in order.lines.all()],
            reason="changed mind",
            register_session=self.session,
        )

        self.assertEqual(adjustment.amount, Decimal("12.00"))


class ManualDiscountInTheZReportTests(InvoiceDiscountTestCase):
    """The shift summary counts it without being told it exists — the whole
    point of putting the number on the lines."""

    def setUp(self):
        super().setUp()
        self.apples = self._product("ZED-APPLE", "10.00")

    def test_the_session_summary_counts_the_haggle_as_a_discount(self):
        self._checkout(
            [{"variant": self.apples.default_variant, "quantity": Decimal("2")}],
            Decimal("17.00"),
            extra_discount_amount=Decimal("3.00"),
        )
        summary = build_register_session_summary(self.session)

        self.assertEqual(Decimal(summary["sales"]["gross_sales"]), Decimal("20.00"))
        self.assertEqual(
            Decimal(summary["sales"]["discount_total"]), Decimal("3.00")
        )
        self.assertEqual(Decimal(summary["sales"]["net_sales"]), Decimal("17.00"))

    def test_the_category_rollup_states_the_discounted_revenue(self):
        """Built in Python from ``OrderLine.discount_total``, line by line —
        a document-only discount would have missed this one entirely."""
        self._checkout(
            [{"variant": self.apples.default_variant, "quantity": Decimal("2")}],
            Decimal("17.00"),
            extra_discount_amount=Decimal("3.00"),
        )
        summary = build_register_session_summary(self.session)

        self.assertEqual(
            sum(Decimal(bucket["net"]) for bucket in summary["categories"]),
            Decimal("17.00"),
        )


class ManualDiscountInTheDiscountAuditTests(InvoiceDiscountTestCase):
    """"Everything the shop gave away, and who authorised it" — the report this
    feature most obviously belongs in, and the one whose breakdown would
    otherwise stop adding up to its own headline."""

    def setUp(self):
        super().setUp()
        ensure_role_groups()
        self.manager = get_user_model().objects.create_user(
            username="audit-manager", password="pass"
        )
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.apples = self._product("AUD-APPLE", "10.00")

    def _audit(self):
        cache.clear()
        return generate_report_payload(
            report_type="discount_audit",
            params={
                "start_date": (date.today() - timedelta(days=1)).isoformat(),
                "end_date": (date.today() + timedelta(days=1)).isoformat(),
            },
            user=self.manager,
        )

    def _section(self, payload, key):
        for section in payload["sections"]:
            if section["key"] == key:
                return section
        self.fail(f"discount_audit has no {key} section")

    def test_the_headline_counts_what_the_counter_gave_away(self):
        self._checkout(
            [{"variant": self.apples.default_variant, "quantity": Decimal("1")}],
            Decimal("7.00"),
            extra_discount_amount=Decimal("3.00"),
        )

        self.assertEqual(
            Decimal(self._audit()["summary"]["discount_total"]), Decimal("3.00")
        )

    def test_the_rule_breakdown_names_the_discount_that_had_no_rule(self):
        """Without its own row an owner reads a shop that gave away 3.00 and a
        list that accounts for none of it."""
        self._checkout(
            [{"variant": self.apples.default_variant, "quantity": Decimal("1")}],
            Decimal("7.00"),
            extra_discount_amount=Decimal("3.00"),
        )
        rows = self._section(self._audit(), "discount_rules")["rows"]

        manual = [
            row for row in rows if row["rule_name"] == MANUAL_DISCOUNT_ROW_NAME
        ]
        self.assertEqual(len(manual), 1)
        self.assertEqual(Decimal(manual[0]["amount"]), Decimal("3.00"))
        self.assertEqual(manual[0]["times_used"], 1)
        # And the list now accounts for the headline.
        self.assertEqual(
            sum(Decimal(row["amount"]) for row in rows), Decimal("3.00")
        )

    def test_a_shop_that_never_haggles_sees_no_such_row(self):
        self._checkout(
            [{"variant": self.apples.default_variant, "quantity": Decimal("1")}],
            Decimal("10.00"),
        )
        rows = self._section(self._audit(), "discount_rules")["rows"]

        self.assertEqual(rows, [])

    def test_the_discount_is_attributed_to_the_cashier_who_gave_it(self):
        """The section exists to show concentration — one cashier holding most
        of the shop's discounts. A discount nobody is named for defeats it."""
        self._checkout(
            [{"variant": self.apples.default_variant, "quantity": Decimal("1")}],
            Decimal("7.00"),
            extra_discount_amount=Decimal("3.00"),
        )
        rows = self._section(self._audit(), "giveaway_by_staff")["rows"]

        mine = [row for row in rows if row["staff_name"] == self.user.username]
        self.assertEqual(len(mine), 1)
        self.assertEqual(Decimal(mine[0]["discount_total"]), Decimal("3.00"))


class ManualDiscountMeetsTheLossGuardTests(InvoiceDiscountTestCase):
    """``prevent_selling_at_loss`` has to see the haggle, or the setting is a
    formality: a cashier stopped from repricing a line under cost would simply
    type the same number into the discount box instead."""

    def setUp(self):
        super().setUp()
        self.settings.prevent_selling_at_loss = True
        self.settings.save(update_fields=["prevent_selling_at_loss"])
        # Sells at 10.00, cost 8.00: a 3.00 discount puts it under.
        self.apples = self._product("LOSS-APPLE", "10.00", cost="8.00")

    def test_a_discount_that_pushes_a_line_under_cost_is_refused(self):
        with self.assertRaises(ValidationError) as caught:
            self._checkout(
                [{"variant": self.apples.default_variant, "quantity": Decimal("1")}],
                Decimal("7.00"),
                extra_discount_amount=Decimal("3.00"),
            )

        self.assertEqual(
            caught.exception.detail.get("code"), "sale_at_loss_blocked"
        )

    def test_a_multi_line_cart_is_judged_line_by_line(self):
        """Each line carries its OWN share of the discount, not the whole thing.

        The guards run before the discount engine has been asked anything, so on
        this path every line still answers to the same default key. Reading the
        spread back by that key handed each line the entire invoice discount,
        and a cart of two comfortably profitable items was refused as a sale at
        a loss the moment a cashier took a dinar off it.
        """
        # 10.00 selling, 8.00 cost, twice over: a 1.00 invoice discount is
        # 0.50 a line, which leaves both lines 1.50 clear of cost.
        second = self._product("LOSS-BREAD", "10.00", cost="8.00")

        order = self._checkout(
            [
                {"variant": self.apples.default_variant, "quantity": Decimal("1")},
                {"variant": second.default_variant, "quantity": Decimal("1")},
            ],
            Decimal("19.00"),
            extra_discount_amount=Decimal("1.00"),
        )

        self.assertEqual(order.total, Decimal("19.00"))
        for line in order.lines.all():
            self.assertEqual(line.discount_total, Decimal("0.50"))

    def test_a_discount_that_keeps_the_line_above_cost_goes_through(self):
        order = self._checkout(
            [{"variant": self.apples.default_variant, "quantity": Decimal("1")}],
            Decimal("9.00"),
            extra_discount_amount=Decimal("1.00"),
        )

        self.assertEqual(order.total, Decimal("9.00"))


class ManualDiscountPreviewAgreesWithCheckoutTests(InvoiceDiscountTestCase):
    """The quote on the screen is the amount the drawer asks for.

    ``expected_order_totals`` is the one function the preview, the tender check
    and the saved order all reach their number through. If the manual discount
    did not travel through it, the till would show one total and then refuse the
    payment it had just asked for.
    """

    def setUp(self):
        super().setUp()
        self.apples = self._product("PRE-APPLE", "10.00")
        self.weighed = self._product("PRE-KG", "5.50")

    def test_the_quoted_total_is_the_total_the_order_stores(self):
        lines_data = [
            {"variant": self.apples.default_variant, "quantity": Decimal("1")},
            {"variant": self.weighed.default_variant, "quantity": Decimal("0.750")},
        ]
        discount_result = calculate_sales_discounts(lines_data=lines_data)
        subtotal, discount_total, total = expected_order_totals(
            lines_data, discount_result, Decimal("2.00")
        )

        order = self._checkout(
            lines_data, total, extra_discount_amount=Decimal("2.00")
        )

        self.assertEqual(
            (order.subtotal, order.discount_total, order.total),
            (subtotal, discount_total, total),
        )

    def test_a_half_cent_line_does_not_break_the_agreement(self):
        """0.750 kg at 5.50 is 4.125 — the gross the two rounding regimes
        disagree on. The manual discount rides the same capped per-line figures
        the engine's does, so it cannot reintroduce the cent."""
        lines_data = [
            {"variant": self.weighed.default_variant, "quantity": Decimal("0.750")},
        ]
        discount_result = calculate_sales_discounts(lines_data=lines_data)
        subtotal, _, total = expected_order_totals(
            lines_data, discount_result, Decimal("4.12")
        )

        self.assertEqual(subtotal, Decimal("4.12"))
        self.assertEqual(total, Decimal("0.00"))

        order = self._checkout(
            lines_data, total, extra_discount_amount=Decimal("4.12")
        )
        self.assertEqual(order.total, Decimal("0.00"))
        self.assertEqual(order.lines.get().line_total, Decimal("0.00"))


class ManualDiscountThroughTheApiTests(TestCase):
    """What a till actually posts, and what the endpoint does with it.

    The tests above drive ``checkout_order`` and the validator directly, which
    proves the arithmetic and the rule but not that the endpoint applies either.
    A ceiling the checkout serializer forgot to consult is a ceiling that does
    not exist, however well its function is tested.
    """

    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.cashier = User.objects.create_user(username="api-till", password="x")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(self.cashier)

        self.product = create_product_with_default_variant(
            name="أرز", sku="API-RICE", unit_price=Decimal("10.00")
        )
        self.variant = self.product.default_variant
        StockItem.objects.create(
            variant=self.variant, quantity_on_hand=Decimal("100")
        )
        RegisterSession.objects.create(
            owner_key=f"user:{self.cashier.pk}", opening_cash=Decimal("0.00")
        )
        settings = ShopSettings.load()
        settings.prevent_selling_at_loss = False
        settings.save(update_fields=["prevent_selling_at_loss"])

    def _set_ceiling(self, value):
        settings = ShopSettings.load()
        settings.max_invoice_discount_amount = value
        settings.save(update_fields=["max_invoice_discount_amount"])

    def _checkout(self, *, discount=None, amount="10.00", quantity="1"):
        body = {
            "lines": [{"variant": self.variant.pk, "quantity": quantity}],
            "payments": [{"method": "cash", "amount": amount}],
        }
        if discount is not None:
            body["extra_discount_amount"] = discount
        return self.client.post(
            reverse("order-checkout"), body, format="json"
        )

    def _preview(self, *, discount=None, quantity="1"):
        body = {"lines": [{"variant": self.variant.pk, "quantity": quantity}]}
        if discount is not None:
            body["extra_discount_amount"] = discount
        return self.client.post(
            reverse("order-discount-preview"), body, format="json"
        )

    def test_a_cashier_can_discount_an_invoice(self):
        response = self._checkout(discount="3.00", amount="7.00")

        self.assertEqual(
            response.status_code, status.HTTP_201_CREATED, response.data
        )
        order = Order.objects.get()
        self.assertEqual(order.total, Decimal("7.00"))
        self.assertEqual(order.extra_discount_amount, Decimal("3.00"))
        self.assertEqual(order.lines.get().discount_total, Decimal("3.00"))

    def test_the_tender_must_match_the_discounted_total(self):
        """Not the shelf price. The whole sale hinges on the server agreeing
        with the figure the cashier read off the screen."""
        response = self._checkout(discount="3.00", amount="10.00")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertFalse(Order.objects.exists())

    def test_the_endpoint_enforces_the_shops_ceiling(self):
        self._set_ceiling(Decimal("2.00"))

        response = self._checkout(discount="3.00", amount="7.00")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("extra_discount_amount", response.data)
        self.assertFalse(Order.objects.exists())

    def test_a_zero_ceiling_turns_till_discounting_off(self):
        self._set_ceiling(Decimal("0.00"))

        response = self._checkout(discount="0.50", amount="9.50")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertFalse(Order.objects.exists())

    def test_a_negative_discount_is_refused(self):
        # Otherwise the box is a way to charge MORE than the price on the shelf.
        response = self._checkout(discount="-5.00", amount="15.00")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertFalse(Order.objects.exists())

    def test_an_older_till_that_sends_nothing_still_sells(self):
        response = self._checkout(amount="10.00")

        self.assertEqual(
            response.status_code, status.HTTP_201_CREATED, response.data
        )
        self.assertEqual(Order.objects.get().extra_discount_amount, Decimal("0.00"))

    def test_the_preview_quotes_the_total_checkout_will_charge(self):
        preview = self._preview(discount="3.00")

        self.assertEqual(preview.status_code, status.HTTP_200_OK, preview.data)
        self.assertEqual(preview.data["total"], "7.00")
        self.assertEqual(preview.data["discount_total"], "3.00")
        self.assertEqual(preview.data["extra_discount_amount"], "3.00")

        # ...and the sale goes through at exactly that figure.
        response = self._checkout(
            discount="3.00", amount=preview.data["total"]
        )
        self.assertEqual(
            response.status_code, status.HTTP_201_CREATED, response.data
        )

    def test_the_preview_reports_what_the_cart_can_actually_carry(self):
        preview = self._preview(discount="50.00")

        self.assertEqual(preview.data["max_extra_discount_amount"], "10.00")
        self.assertEqual(preview.data["extra_discount_amount"], "10.00")
        self.assertEqual(preview.data["total"], "0.00")

    def test_the_preview_refuses_an_over_ceiling_amount_too(self):
        # Met while the cashier is typing, not held back until they ask the
        # customer for money.
        self._set_ceiling(Decimal("2.00"))

        preview = self._preview(discount="3.00")

        self.assertEqual(preview.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("extra_discount_amount", preview.data)


class ManualDiscountLeavesOrdinarySalesAloneTests(InvoiceDiscountTestCase):
    """Nothing typed, nothing changed — the shape of every sale this shop has
    ever rung up."""

    def setUp(self):
        super().setUp()
        self.apples = self._product("NIL-APPLE", "10.00")

    def test_a_sale_with_no_haggle_is_untouched(self):
        order = self._checkout(
            [{"variant": self.apples.default_variant, "quantity": Decimal("1")}],
            Decimal("10.00"),
        )

        self.assertEqual(order.extra_discount_amount, Decimal("0.00"))
        self.assertEqual(order.discount_total, Decimal("0.00"))
        self.assertEqual(order.total, Decimal("10.00"))
        self.assertEqual(order.lines.get().discount_total, Decimal("0.00"))

    def test_a_credit_invoice_can_be_haggled_over_too(self):
        order = self._checkout(
            [{"variant": self.apples.default_variant, "quantity": Decimal("1")}],
            Decimal("0.00"),
            sale_type=Order.SaleType.CREDIT,
            extra_discount_amount=Decimal("2.00"),
        )

        self.assertEqual(order.total, Decimal("8.00"))
        self.assertEqual(order.balance_due, Decimal("8.00"))
