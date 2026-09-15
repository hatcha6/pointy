"""Auto-print, but only for sales worth a slip.

A shop that sells one loaf of bread at a time does not want a receipt for every
loaf — it wants one for the weekly shop. The floor is two numbers, a line count
and a total, and a sale prints by itself when it clears *either*: a big basket
of cheap things qualifies on lines, a single expensive thing on money.

Leaving both empty is the old behaviour, every sale prints. A floor never stops
a cashier printing by hand — that request arrives as an explicit reprint, which
is covered here too, because a shop that discovers the floor swallowed a receipt
the customer asked for would rightly turn the whole feature off.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.testing import create_product_with_default_variant
from apps.core.models import ShopSettings
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.inventory.models import StockItem
from apps.payments.models import Payment
from apps.printing.models import PrintAgent, PrintJob
from apps.printing.services import (
    enqueue_receipt_print_job,
    order_clears_auto_print_floor,
)
from apps.printing.tests import PrintingTestMixin
from apps.sales.models import Order, OrderLine


class AutoPrintFloorRuleTests(TestCase):
    """The rule itself, with no order and no queue in the way."""

    def setUp(self):
        self.settings = ShopSettings.load()

    def _floor(self, *, lines=None, total=None):
        self.settings.auto_print_min_line_count = lines
        self.settings.auto_print_min_total = (
            None if total is None else Decimal(total)
        )
        return self.settings

    def test_no_floor_prints_everything(self):
        settings = self._floor()

        self.assertFalse(settings.has_auto_print_floor)
        self.assertTrue(
            settings.sale_clears_auto_print_floor(
                line_count=1,
                total=Decimal("0.50"),
            )
        )

    def test_either_floor_is_enough(self):
        settings = self._floor(lines=3, total="20.00")

        with self.subTest("on lines alone"):
            self.assertTrue(
                settings.sale_clears_auto_print_floor(
                    line_count=3,
                    total=Decimal("4.00"),
                )
            )
        with self.subTest("on money alone"):
            self.assertTrue(
                settings.sale_clears_auto_print_floor(
                    line_count=1,
                    total=Decimal("20.00"),
                )
            )
        with self.subTest("on neither"):
            self.assertFalse(
                settings.sale_clears_auto_print_floor(
                    line_count=2,
                    total=Decimal("19.99"),
                )
            )

    def test_each_floor_stands_alone(self):
        """A shop that sets one number has not implicitly set the other."""
        lines_only = self._floor(lines=4)
        self.assertFalse(
            lines_only.sale_clears_auto_print_floor(
                line_count=3,
                total=Decimal("9999.00"),
            ),
            "an unset money floor must not qualify a sale on its own",
        )

        money_only = self._floor(total="50.00")
        self.assertFalse(
            money_only.sale_clears_auto_print_floor(
                line_count=99,
                total=Decimal("10.00"),
            ),
            "an unset line floor must not qualify a sale on its own",
        )

    def test_the_floor_is_inclusive(self):
        settings = self._floor(lines=3, total="20.00")

        self.assertTrue(
            settings.sale_clears_auto_print_floor(
                line_count=3,
                total=Decimal("0.00"),
            )
        )
        self.assertTrue(
            settings.sale_clears_auto_print_floor(
                line_count=0,
                total=Decimal("20.00"),
            )
        )

    def test_zero_reads_as_no_floor(self):
        """A cleared box must not mean "every sale clears it" — which is what a
        literal ``line_count >= 0`` would say."""
        settings = self._floor(lines=0, total="0.00")

        self.assertFalse(settings.has_auto_print_floor)
        self.assertTrue(
            settings.sale_clears_auto_print_floor(
                line_count=1,
                total=Decimal("0.25"),
            )
        )


class AutoPrintFloorQueueTests(TestCase):
    """What the floor does to the receipt the backend queues."""

    def setUp(self):
        settings_row = ShopSettings.load()
        settings_row.auto_print_receipts = True
        settings_row.auto_print_min_line_count = 3
        settings_row.auto_print_min_total = Decimal("20.00")
        settings_row.save()

        self.product = create_product_with_default_variant(
            name="خبز",
            sku="FLOOR-BREAD",
            unit_price="1.00",
        )

    def _paid_order(
        self,
        *,
        lines,
        total,
        receipt="R-FLOOR-1",
        sale_type=Order.SaleType.STANDARD,
    ):
        order = Order.objects.create(
            receipt_number=receipt,
            status=Order.Status.PAID,
            sale_type=sale_type,
            subtotal=Decimal(total),
            total=Decimal(total),
        )
        for _ in range(lines):
            OrderLine.objects.create(
                order=order,
                variant=self.product.default_variant,
                quantity=Decimal("1"),
                unit_price=Decimal("1.00"),
                unit_cost=Decimal("0.40"),
            )
        return order

    def test_a_loaf_of_bread_does_not_print(self):
        order = self._paid_order(lines=1, total="1.00")

        self.assertIsNone(enqueue_receipt_print_job(order.pk))
        self.assertFalse(PrintJob.objects.exists())

    def test_a_basket_prints_on_line_count(self):
        order = self._paid_order(lines=3, total="3.00")

        job = enqueue_receipt_print_job(order.pk)

        self.assertIsNotNone(job)
        self.assertEqual(job.order_id, order.pk)

    def test_one_expensive_thing_prints_on_total(self):
        order = self._paid_order(lines=1, total="45.00")

        self.assertIsNotNone(enqueue_receipt_print_job(order.pk))

    def test_clearing_the_floor_restores_printing_everything(self):
        ShopSettings.objects.filter(pk=1).update(
            auto_print_min_line_count=None,
            auto_print_min_total=None,
        )
        order = self._paid_order(lines=1, total="1.00")

        self.assertIsNotNone(enqueue_receipt_print_job(order.pk))

    def test_a_credit_invoice_under_the_floor_still_prints(self):
        """A debt slip is the customer's only record of what they owe."""
        order = self._paid_order(
            lines=1,
            total="1.00",
            receipt="R-FLOOR-CREDIT",
            sale_type=Order.SaleType.CREDIT,
        )

        self.assertIsNotNone(enqueue_receipt_print_job(order.pk))

    def test_a_quotation_under_the_floor_still_prints(self):
        """A price offer is handed to the customer by definition."""
        order = Order.objects.create(
            receipt_number="R-FLOOR-QUOTE",
            status=Order.Status.OPEN,
            sale_type=Order.SaleType.QUOTATION,
            subtotal=Decimal("1.00"),
            total=Decimal("1.00"),
        )
        OrderLine.objects.create(
            order=order,
            variant=self.product.default_variant,
            quantity=Decimal("1"),
            unit_price=Decimal("1.00"),
            unit_cost=Decimal("0.40"),
        )

        self.assertIsNotNone(enqueue_receipt_print_job(order.pk))

    def test_a_floorless_shop_never_counts_lines(self):
        """The common case pays nothing for the feature."""
        ShopSettings.objects.filter(pk=1).update(
            auto_print_min_line_count=None,
            auto_print_min_total=None,
        )
        order = self._paid_order(lines=1, total="1.00")
        settings_row = ShopSettings.load()

        with self.assertNumQueries(0):
            self.assertTrue(order_clears_auto_print_floor(order, settings_row))


class AutoPrintFloorCheckoutTests(PrintingTestMixin, TestCase):
    """A floor decides what prints on its own — never what a cashier may ask
    for. Under the floor the POS shows the manual print box again, and the
    request it sends has to produce a printed slip."""

    def setUp(self):
        super().setUp()
        settings_row = ShopSettings.load()
        settings_row.auto_print_receipts = True
        settings_row.auto_print_min_line_count = 3
        settings_row.auto_print_min_total = Decimal("20.00")
        settings_row.save()

        self.product = create_product_with_default_variant(
            name="خبز",
            sku="FLOOR-CHECKOUT-BREAD",
            unit_price="1.00",
        )
        StockItem.objects.create(
            variant=self.product.default_variant,
            quantity_on_hand=50,
        )
        PrintAgent.objects.update_or_create(
            identifier="pointy-local-agent",
            defaults={
                "name": "pointy-local-agent",
                "is_active": True,
                "last_seen_at": timezone.now(),
            },
        )
        self.cashier_client.post(
            reverse("register-session-start"),
            {"opening_cash": "0.00"},
            format="json",
        )

    def _checkout(self, *, quantity, print_invoice=False):
        payload = {
            "lines": [
                {"variant": self.product.default_variant.pk, "quantity": quantity}
            ],
            "payment_method": Payment.Method.CASH,
            "amount_received": f"{quantity}.00",
            "receipt_delivery": "agent",
        }
        if print_invoice:
            payload["print_invoice"] = {
                "agent_id": "pointy-local-agent",
                "printer_endpoint": {
                    "kind": "serial",
                    "name": "Counter printer",
                    "address": "/dev/tty.usbserial",
                    "baud_rate": 9600,
                },
            }
        with self.captureOnCommitCallbacks(execute=True):
            return self.cashier_client.post(
                reverse("order-checkout"),
                payload,
                format="json",
            )

    def test_a_sale_under_the_floor_queues_nothing_on_its_own(self):
        response = self._checkout(quantity=1)

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertFalse(PrintJob.objects.exists())

    def test_the_cashier_can_still_print_a_sale_under_the_floor(self):
        response = self._checkout(quantity=1, print_invoice=True)

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        job = PrintJob.objects.get()
        self.assertEqual(job.order_id, response.data["id"])
        self.assertEqual(job.status, PrintJob.Status.CLAIMED)
        self.assertIn("print_job", response.data)

    def test_a_sale_over_the_floor_still_prints_exactly_once(self):
        """The auto path and the till's print request must not each mint a job."""
        response = self._checkout(quantity=25, print_invoice=True)

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(PrintJob.objects.count(), 1)
        self.assertEqual(PrintJob.objects.get().status, PrintJob.Status.CLAIMED)


class AutoPrintFloorSettingsApiTests(TestCase):
    """The floor is two boxes on the settings form: set them, clear them."""

    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(
            username="floor-manager",
            password="pass",
        )
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(user=self.manager)

    def test_a_manager_can_set_and_clear_the_floor(self):
        set_response = self.client.patch(
            reverse("shop-settings"),
            {
                "auto_print_receipts": True,
                "auto_print_min_line_count": 3,
                "auto_print_min_total": "20.00",
            },
            format="json",
        )

        self.assertEqual(set_response.status_code, status.HTTP_200_OK)
        self.assertEqual(set_response.data["auto_print_min_line_count"], 3)
        self.assertEqual(ShopSettings.load().auto_print_min_total, Decimal("20.00"))

        # Emptying a box on the form sends null, which has to clear the floor
        # rather than be ignored as "no value supplied".
        clear_response = self.client.patch(
            reverse("shop-settings"),
            {
                "auto_print_min_line_count": None,
                "auto_print_min_total": None,
            },
            format="json",
        )

        self.assertEqual(clear_response.status_code, status.HTTP_200_OK)
        settings_row = ShopSettings.load()
        self.assertIsNone(settings_row.auto_print_min_line_count)
        self.assertIsNone(settings_row.auto_print_min_total)
        self.assertFalse(settings_row.has_auto_print_floor)

    def test_a_negative_floor_is_refused(self):
        response = self.client.patch(
            reverse("shop-settings"),
            {"auto_print_min_total": "-5.00"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("auto_print_min_total", response.data)
