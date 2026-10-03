"""Selling a serial-numbered article under warranty texts the customer its
number and the day its cover ends — when the shop has that text on."""

from decimal import Decimal

from django.test import TestCase

from apps.catalog.models import Product
from apps.core.models import ShopSettings
from apps.customers.models import Customer
from apps.inventory.models import StockUnit
from apps.inventory.test_used_goods import IMEI_A, _session
from apps.inventory.tracked_testing import receive, tracked_product
from apps.messaging.models import MessagingGateway, OutboundMessage
from apps.sales.services import checkout_order

from .transactional import notify_warranties


class WarrantyTextTests(TestCase):
    def setUp(self):
        settings = ShopSettings.load()
        settings.shop_name = "محل النور"
        settings.save()
        self.gateway = MessagingGateway.objects.create(
            name="phone", provider=MessagingGateway.Provider.FAKE, is_default=True,
            auto_messages={"warranty_registered": True},
        )
        product = tracked_product(name="iPhone 14", sku="IP14", mode=Product.TrackingMode.SERIAL, unit_price="2000.00")
        product.warranty_days = 365
        product.save(update_fields=["warranty_days"])
        self.variant = product.default_variant
        receive(variant=self.variant, quantity=1, unit_cost="1500.00", units=[{"code": IMEI_A, "identifier_kind": "imei"}])
        self.unit = StockUnit.objects.get(code_normalized=IMEI_A)
        self.customer = Customer.objects.create(full_name="زبون", phone="0912345678")

    def sell(self):
        return checkout_order(
            register_session=_session(),
            lines_data=[{
                "variant": self.variant, "quantity": Decimal("1"),
                "effective_unit_price": Decimal("2000.00"), "stock_units": [self.unit.pk],
            }],
            payments_data=[{"method": "cash", "amount": Decimal("2000.00")}],
            customer=self.customer,
        )

    def test_the_customer_gets_the_number_and_the_end_of_cover(self):
        order = self.sell()
        with self.captureOnCommitCallbacks(execute=True):
            notify_warranties(order)
            notify_warranties(order)
        [text] = OutboundMessage.objects.filter(template_kind="warranty_registered")
        self.unit.refresh_from_db()
        self.assertEqual(
            text.body, f"محل النور: ضمان iPhone 14 ({IMEI_A}) حتى {self.unit.warranty_expires_on:%Y/%m/%d}."
        )

    def test_off_by_default(self):
        self.gateway.auto_messages = {}
        self.gateway.save(update_fields=["auto_messages"])
        order = self.sell()
        with self.captureOnCommitCallbacks(execute=True):
            notify_warranties(order)
        self.assertFalse(OutboundMessage.objects.exists())
