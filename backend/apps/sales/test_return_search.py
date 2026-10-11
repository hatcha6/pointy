"""The returns desk's one search box (``orders/return-search/?q=``).

A customer brings the receipt, the goods, or neither. The desk answers a whole
receipt or its QR by opening that invoice, a receipt's tail with the invoices
it can mean, and the goods — or a phone number — with what was sold inside
the shop's return window and can still come back.
"""

from datetime import timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.db import connection
from django.test import SimpleTestCase, TestCase
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.models import (
    ProductAlias,
    ProductUnit,
    ProductUnitBarcode,
    UnitOfMeasure,
)
from apps.catalog.testing import create_product_with_default_variant
from apps.core.models import ShopSettings
from apps.core.roles import CASHIER_GROUP, ensure_role_groups
from apps.customers.models import Customer

from .models import (
    Order,
    OrderAdjustment,
    OrderAdjustmentLine,
    OrderLine,
    RegisterSession,
)
from .return_search import invoice_token_from_url, receipt_tail
from .testing import issue

RECEIPT = "R20261009000123"


class ReceiptTailTests(SimpleTestCase):
    def test_a_short_number_means_the_sequence_printed_six_wide(self):
        for typed in ("123", "000123", "١٢٣", " 123 ", "r000123"):
            with self.subTest(typed=typed):
                self.assertEqual(receipt_tail(typed), "000123")

    def test_a_longer_tail_means_itself(self):
        self.assertEqual(receipt_tail("09000123"), "09000123")
        self.assertEqual(receipt_tail("R2026100900012"), "2026100900012")

    def test_a_whole_receipt_or_words_are_not_a_tail(self):
        for typed in ("20261009000123", "R20261009000123", "حليب", "AB12", "0", ""):
            with self.subTest(typed=typed):
                self.assertIsNone(receipt_tail(typed))


class InvoiceQrTests(SimpleTestCase):
    def test_the_receipt_qr_link_carries_the_invoice_token(self):
        token = "Ab_9-" + "x" * 27
        url = f"https://relay.example.ly/api/invoices/inst-1/{token}"
        self.assertEqual(invoice_token_from_url(url), token)
        self.assertEqual(invoice_token_from_url(url + "/"), token)
        self.assertIsNone(invoice_token_from_url("R20261009000123"))
        self.assertIsNone(invoice_token_from_url("https://example.ly/products/1"))


class ReturnSearchEndpointTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        settings = ShopSettings.load()
        settings.cashier_return_window_hours = 72
        settings.save()
        user_model = get_user_model()
        # The returns desk: a cashier who may reach a sale they did not ring up.
        desk = user_model.objects.create_user(username="returns-desk", password="p")
        desk.groups.add(Group.objects.get(name=CASHIER_GROUP))
        desk.user_permissions.add(
            Permission.objects.get(codename="process_return_lookup")
        )
        seller = user_model.objects.create_user(
            username="seller", password="p", first_name="سالم"
        )
        seller.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.desk = user_model.objects.get(pk=desk.pk)
        self.client = APIClient()
        self.client.force_authenticate(self.desk)
        # Rung up by someone else, so every hit proves the widened scope.
        self.session = RegisterSession.objects.create(
            owner=seller, owner_key=f"user:{seller.pk}", opening_cash=Decimal("0")
        )
        self.rice = create_product_with_default_variant(
            name="أرز النجمة حبة قصيرة",
            sku="RICE-1",
            barcode="6241000123456",
            unit_price="12.50",
        )
        self.milk = create_product_with_default_variant(
            name="حليب نيدو", sku="MILK-1", barcode="6241000999999", unit_price="30.00"
        )
        self.rice_variant = self.rice.variants.get()
        self.milk_variant = self.milk.variants.get()

    # -- fixtures -------------------------------------------------------------

    def _sale(self, *lines, receipt="", hours_ago=1, status=Order.Status.PAID, customer=None):
        order = Order.objects.create(
            register_session=self.session,
            receipt_number=receipt,
            customer=customer,
            subtotal=Decimal("0"),
            total=Decimal("0"),
        )
        created = []
        for variant, quantity in lines:
            created.append(
                OrderLine.objects.create(
                    order=order,
                    variant=variant,
                    quantity=Decimal(quantity),
                    unit_price=variant.unit_price,
                )
            )
        issue(order, status=status)
        Order.objects.filter(pk=order.pk).update(
            created_at=timezone.now() - timedelta(hours=hours_ago)
        )
        order.refresh_from_db()
        return order, created

    def _returned(self, line, quantity):
        adjustment = OrderAdjustment.objects.create(
            order=line.order,
            register_session=self.session,
            adjustment_type=OrderAdjustment.AdjustmentType.RETURN,
            amount=Decimal("1.00"),
        )
        OrderAdjustmentLine.objects.create(
            adjustment=adjustment,
            order_line=line,
            variant=line.variant,
            quantity=Decimal(quantity),
            unit_price=line.unit_price,
        )

    def _search(self, query):
        response = self.client.get(reverse("order-return-search"), {"q": query})
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        return response.data

    def _line_ids(self, data):
        return [line["id"] for line in data["lines"]]

    # -- receipts -------------------------------------------------------------

    def test_a_whole_receipt_opens_that_invoice_with_its_lines(self):
        order, _ = self._sale((self.rice_variant, "2"), receipt=RECEIPT, hours_ago=24 * 30)
        for typed in (RECEIPT, "r 20261009 000123", "٢٠٢٦١٠٠٩٠٠٠١٢٣"):
            with self.subTest(typed=typed):
                data = self._search(typed)
                self.assertEqual(data["order"]["id"], order.pk)
                self.assertEqual(len(data["order"]["lines"]), 1)
                self.assertEqual(data["lines"], [])

    def test_the_receipt_qr_opens_that_invoice(self):
        order, _ = self._sale((self.rice_variant, "1"), receipt=RECEIPT)
        url = f"https://relay.example.ly/api/invoices/inst-1/{order.public_token}"
        self.assertEqual(self._search(url)["order"]["id"], order.pk)

    def test_the_end_of_a_receipt_lists_the_invoices_it_can_mean(self):
        order, _ = self._sale((self.rice_variant, "1"), receipt=RECEIPT, hours_ago=24 * 90)
        # Past 999999 the sequence prints seven wide and shares the tail.
        later, _ = self._sale((self.milk_variant, "1"), receipt="R202610091000123")
        self._sale((self.milk_variant, "1"), receipt="R20261009000124")
        for typed in ("123", "000123", "١٢٣"):
            with self.subTest(typed=typed):
                data = self._search(typed)
                self.assertIsNone(data["order"])
                self.assertEqual(
                    [row["id"] for row in data["invoices"]], [later.pk, order.pk]
                )
                self.assertTrue(data["invoices"][0]["has_returnable_items"])

    # -- goods ----------------------------------------------------------------

    def test_a_scanned_barcode_lists_the_returnable_lines_inside_the_window(self):
        recent, (recent_line,) = self._sale((self.rice_variant, "2"), hours_ago=2)
        older, (older_line, _) = self._sale(
            (self.rice_variant, "1"), (self.milk_variant, "1"), hours_ago=48
        )
        self._sale((self.rice_variant, "1"), hours_ago=100)  # outside 72 h
        self._sale((self.rice_variant, "1"), status=Order.Status.VOID)
        _, (gone,) = self._sale((self.rice_variant, "1"))
        self._returned(gone, "1")

        data = self._search("6241000123456")
        self.assertEqual(self._line_ids(data), [recent_line.pk, older_line.pk])
        first = data["lines"][0]
        self.assertEqual(first["order"], recent.pk)
        self.assertEqual(first["product_name"], "أرز النجمة حبة قصيرة")
        self.assertEqual(first["returnable_quantity"], 2.0)
        self.assertEqual(first["matched_by"], "barcode")
        self.assertEqual(first["cashier_name"], "سالم")
        self.assertEqual(data["window_hours"], 72)

    def test_a_partly_returned_line_offers_what_is_left(self):
        _, (line,) = self._sale((self.rice_variant, "3"))
        self._returned(line, "1")
        (row,) = self._search("6241000123456")["lines"]
        self.assertEqual(row["returned_quantity"], 1.0)
        self.assertEqual(row["returnable_quantity"], 2.0)

    def test_codes_are_read_however_the_scanner_typed_them(self):
        _, (line,) = self._sale((self.rice_variant, "1"))
        for typed in ("٦٢٤١٠٠٠١٢٣٤٥٦", "rice-1", "RICE-1"):
            with self.subTest(typed=typed):
                self.assertEqual(self._line_ids(self._search(typed)), [line.pk])
        self.assertEqual(self._search("rice-1")["lines"][0]["matched_by"], "sku")

    def test_a_carton_barcode_finds_the_product(self):
        box, _ = UnitOfMeasure.objects.get_or_create(
            code="box", defaults={"name": "كرتونة"}
        )
        unit = ProductUnit.objects.create(
            product=self.rice, unit=box, factor_to_base=Decimal("10")
        )
        ProductUnitBarcode.objects.create(product_unit=unit, barcode="6241000777777")
        _, (line,) = self._sale((self.rice_variant, "1"))
        self.assertEqual(self._line_ids(self._search("6241000777777")), [line.pk])

    def test_a_handsets_imei_names_its_own_line(self):
        from apps.inventory.models import StockUnit, Warehouse

        _, (first, _) = self._sale((self.milk_variant, "1"), (self.milk_variant, "1"))
        StockUnit.objects.create(
            variant=self.milk_variant,
            warehouse_id=Warehouse.default_id(),
            code="356938035643809",
            status=StockUnit.Status.SOLD,
            incoming_rate=Decimal("0"),
            sold_order_line=first,
        )
        (row,) = self._search("356938035643809")["lines"]
        self.assertEqual(row["id"], first.pk)
        self.assertEqual(row["matched_by"], "serial")
        self.assertEqual(row["matched_code"], "356938035643809")

    def test_words_of_the_name_find_it_however_they_are_spelled(self):
        _, (line, _) = self._sale((self.rice_variant, "1"), (self.milk_variant, "1"))
        for typed in ("ارز", "النجمه ارز", "أرز قصيرة", "hv."):  # last: «ارز» on EN layout
            with self.subTest(typed=typed):
                data = self._search(typed)
                self.assertEqual(self._line_ids(data), [line.pk])
                self.assertEqual(data["lines"][0]["matched_by"], "name")
        self.assertEqual(self._search("ارز نيدو")["lines"], [])

    def test_an_alias_finds_the_product(self):
        ProductAlias.objects.create(
            product=self.milk, alias="بودرة الحليب", normalized="بودره الحليب"
        )
        _, (_, line) = self._sale((self.rice_variant, "1"), (self.milk_variant, "1"))
        self.assertEqual(self._line_ids(self._search("بودره")), [line.pk])

    def test_a_customers_phone_lists_their_invoices_inside_the_window(self):
        customer = Customer.objects.create(full_name="خالد", phone="0912345678")
        recent, _ = self._sale((self.rice_variant, "1"), customer=customer)
        self._sale((self.rice_variant, "1"), customer=customer, hours_ago=200)
        data = self._search("+218 91 234 5678")
        self.assertEqual([row["id"] for row in data["invoices"]], [recent.pk])

    def test_a_closed_window_finds_no_goods_but_still_finds_receipts(self):
        ShopSettings.objects.filter(pk=1).update(cashier_return_window_hours=0)
        order, _ = self._sale((self.rice_variant, "1"), receipt=RECEIPT)
        data = self._search("6241000123456")
        self.assertEqual(data["lines"], [])
        self.assertEqual(data["window_hours"], 0)
        self.assertEqual(self._search(RECEIPT)["order"]["id"], order.pk)

    # -- access & cost --------------------------------------------------------

    def test_only_the_returns_desk_may_search(self):
        plain = get_user_model().objects.create_user(username="plain", password="p")
        plain.groups.add(Group.objects.get(name=CASHIER_GROUP))
        client = APIClient()
        client.force_authenticate(get_user_model().objects.get(pk=plain.pk))
        response = client.get(reverse("order-return-search"), {"q": "123"})
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_a_blank_search_is_refused(self):
        response = self.client.get(reverse("order-return-search"), {"q": "  "})
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_the_cost_does_not_grow_with_the_lines_found(self):
        def count():
            self._search("ارز")
            with CaptureQueriesContext(connection) as queries:
                data = self._search("ارز")
            return len(queries), len(data["lines"])

        for _ in range(2):
            self._sale((self.rice_variant, "1"))
        small, small_lines = count()
        for _ in range(6):
            self._sale((self.rice_variant, "1"))
        large, large_lines = count()
        self.assertEqual((small_lines, large_lines), (2, 8))
        self.assertEqual(small, large, f"{small} queries at 2 lines, {large} at 8")
