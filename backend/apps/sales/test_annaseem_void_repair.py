"""The one-off repair of Annaseem's drawers (``apps.sales.annaseem_repair``).

Eight cards refused by Qareeb stayed paid sales in RS-36; voided after RS-36
closed, their refunds landed in the manager's RS-25. A 20 د.ل Daftar card the
owner sold in RS-25 was refused too and stayed paid. The repair moves the eight
voids to RS-36 and gives the card back in RS-25 — on that installation only,
for rows matching every fingerprint, and whether or not the drawers have been
closed since.
"""

from decimal import Decimal
from unittest import mock

from django.contrib.auth import get_user_model
from django.test import TransactionTestCase, override_settings
from django.utils import timezone

from apps.catalog.testing import create_product_with_default_variant
from apps.core.models import RelayInstallation
from apps.documents.guards import system_write
from apps.integrations.fulfillment import resolve_line_integration
from apps.integrations.models import IntegrationFulfillment
from apps.integrations.provisioning import service_variant_for
from apps.integrations.tests import make_account
from apps.inventory.models import StockItem
from apps.sales import annaseem_repair as repair
from apps.sales.models import Order, OrderAdjustment, RegisterSession
from apps.sales.services import checkout_order, void_order


def _plant_receipt(order, receipt):
    with system_write():  # the shop's own receipt numbers
        Order.objects.filter(pk=order.pk).update(receipt_number=receipt)


@override_settings(
    CACHES={"default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"}}
)
class AnnaseemRepairTests(TransactionTestCase):
    reset_sequences = True

    def setUp(self):
        cashier = get_user_model().objects.create_user(username="cashier", password="p")
        manager = get_user_model().objects.create_user(username="manager", password="p")
        product = create_product_with_default_variant(
            name="شدات ببجي", sku="QRB-UC", barcode="", unit_price=Decimal("1919.00")
        )
        StockItem.objects.create(
            variant=product.default_variant, quantity_on_hand=Decimal("100")
        )
        self.manager_drawer = RegisterSession.objects.create(
            pk=repair.VOIDED_IN, owner=manager, owner_key=f"user:{manager.pk}"
        )
        self.cashier_drawer = RegisterSession.objects.create(
            pk=repair.SOLD_IN,
            owner=cashier,
            owner_key=f"user:{cashier.pk}",
            opening_cash=Decimal("4.00"),
        )
        self.cards = []
        for receipt in repair.CARD_RECEIPTS:
            order = checkout_order(
                register_session=self.cashier_drawer,
                lines_data=[{"variant": product.default_variant, "quantity": Decimal("1")}],
                payments_data=[{"method": "cash", "amount": Decimal("1919.00")}],
                request=None,
            )
            _plant_receipt(order, receipt)
            self.cards.append(order)
        # The drawer closes on what was really there; the voids then land in
        # the manager's open drawer.
        self._close(repair.SOLD_IN, Decimal("4.00"))
        for order in self.cards:
            void_order(
                order=Order.objects.get(pk=order.pk),
                reason="فشل الشحن",
                register_session=self.manager_drawer,
            )
        self.daftar_card = self._refused_card_in_manager_drawer()

    def _close(self, pk, counted):
        RegisterSession.objects.filter(pk=pk).update(
            status=RegisterSession.Status.CLOSED,
            closed_at=timezone.now(),
            closing_cash=counted,
        )

    def _refused_card_in_manager_drawer(self):
        make_account()
        variant = service_variant_for("hdbox")
        resolved = resolve_line_integration(
            {
                "provider": "hdbox",
                "subscriber_ref": "210906803499",
                "option_code": "renew:1",
                "cost": Decimal("19.50"),
            },
            variant,
        )
        order = checkout_order(
            register_session=self.manager_drawer,
            lines_data=[
                {
                    "variant": variant,
                    "quantity": Decimal("1"),
                    "effective_unit_price": resolved["price"],
                    "integration": resolved,
                }
            ],
            payments_data=[{"method": "cash", "amount": resolved["price"]}],
            request=None,
        )
        _plant_receipt(order, repair.REFUSED_DAFTAR_CARD)
        # Refused before refusals were given back: still sold, still owed.
        IntegrationFulfillment.objects.filter(order_line__order=order).update(
            last_error_code="insufficient_float"
        )
        return Order.objects.get(pk=order.pk)

    def _annaseem(self, installation_id=repair.ANNASEEM):
        RelayInstallation.objects.create(
            installation_id=installation_id,
            relay_public_api_url="https://relay.example",
            connector_token="x",
            access_token="x",
        )

    def _run(self):
        with mock.patch.object(repair, "REFUSED_DAFTAR_TOTAL", self.daftar_card.total):
            return repair.repair()

    def _session(self, pk):
        return RegisterSession.objects.get(pk=pk)

    def test_both_drawers_are_put_right(self):
        self._annaseem()
        card = self.daftar_card.total
        self.assertEqual(self._session(repair.SOLD_IN).cash_variance, Decimal("-15352.00"))
        self.assertEqual(
            self._session(repair.VOIDED_IN).expected_cash, Decimal("-15352.00") + card
        )

        self.assertEqual(self._run(), {"moved": 8, "given_back": True})

        self.assertEqual(self._session(repair.SOLD_IN).cash_variance, Decimal("0.00"))
        self.assertEqual(self._session(repair.VOIDED_IN).expected_cash, Decimal("0.00"))
        self.daftar_card.refresh_from_db()
        self.assertEqual(self.daftar_card.status, Order.Status.VOID)
        refund = self.daftar_card.adjustments.get()
        self.assertEqual(refund.register_session_id, repair.VOIDED_IN)
        self.assertIsNone(refund.created_by_id, "the system gave it back, not a person")
        # Every later boot finds nothing to do.
        self.assertEqual(self._run(), {"moved": 0, "given_back": False})

    def test_drawers_closed_before_the_update_are_put_right_too(self):
        # The shop keeps working: by the time the update lands, the manager
        # has closed RS-25 on the cash really in it.
        self._annaseem()
        self._close(repair.VOIDED_IN, self.daftar_card.total)
        self.assertEqual(
            self._session(repair.VOIDED_IN).cash_variance, Decimal("15352.00")
        )

        self._run()

        self.assertEqual(self._session(repair.SOLD_IN).cash_variance, Decimal("0.00"))
        # Only the refused card is left: given back, its 20 reads as over until
        # it is handed to the customer — what the till now says at the counter.
        self.assertEqual(
            self._session(repair.VOIDED_IN).cash_variance, self.daftar_card.total
        )

    def test_any_other_shop_is_left_alone(self):
        self._annaseem("another-shop")
        self.assertEqual(self._run(), {})
        self.assertEqual(
            OrderAdjustment.objects.filter(register_session_id=repair.VOIDED_IN).count(), 8
        )
        self.daftar_card.refresh_from_db()
        self.assertEqual(self.daftar_card.status, Order.Status.PAID)

    def test_a_row_that_no_longer_matches_is_left_alone(self):
        self._annaseem()
        _plant_receipt(self.cards[0], "R-OTHER")
        IntegrationFulfillment.objects.filter(order_line__order=self.daftar_card).update(
            status=IntegrationFulfillment.Status.CONFIRMED
        )
        self.assertEqual(self._run(), {"moved": 7, "given_back": False})
