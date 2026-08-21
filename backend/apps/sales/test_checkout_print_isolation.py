"""Printing must never be able to discard a completed sale.

``run_idempotent_request`` wraps the whole checkout — validation, stock
deduction, payments *and* the print steps that follow — in one transaction, so
anything that raises after ``serializer.save()`` does not merely lose the
receipt: it rolls the sale back. The cashier is then told the checkout failed
while the customer is standing there, and retrying fails again for as long as
the printing fault lasts.

Two guards have to hold for that not to happen:

* the receipt claim has to be *caught at all* — it wasn't, even though the
  kitchen enqueue beside it claims to "mirror the receipt enqueue";
* catching has to leave the outer transaction usable. A ``try/except`` around a
  bare ``.save()`` does not: the failing statement aborts the whole Postgres
  transaction, so the swallow is decoration and the next query — the
  idempotency record's own save — raises anyway. Only a savepoint
  (``transaction.atomic()``) around the fragile step actually recovers.
"""

from decimal import Decimal
from unittest import mock

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.db import connection
from django.test import TestCase
from rest_framework.test import APIClient

from apps.catalog.testing import create_product_with_default_variant
from apps.core.models import ShopSettings
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.inventory.models import StockItem

from .models import Order, RegisterSession


def _raise_plain(*args, **kwargs):
    """A printing fault that never touches the database (a bad payload, a
    missing template asset, a driver misconfiguration)."""
    raise RuntimeError("receipt rendering blew up")


def _abort_the_transaction(*args, **kwargs):
    """A printing fault that *is* a database error — a statement timeout, a
    lost connection, a constraint violation on a bare ``.save()``.

    On Postgres this poisons the surrounding transaction, which is exactly the
    failure a plain ``try/except`` cannot recover from.
    """
    with connection.cursor() as cursor:
        cursor.execute("SELECT 1 / 0")


class CheckoutPrintIsolationTests(TestCase):
    """One product, one cashier, one cash sale — with the printer misbehaving."""

    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.user = User.objects.create_user(username="print-cashier", password="pass")
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        settings = ShopSettings.load()
        settings.allow_overselling = False
        settings.enable_cash_payments = True
        settings.auto_print_receipts = True
        settings.save()

        self.product = create_product_with_default_variant(
            name="Sugar", sku="SUGAR", unit_price="10.00"
        )
        self.variant = self.product.default_variant
        self.stock = StockItem.objects.create(
            variant=self.variant, quantity_on_hand=Decimal("50")
        )
        self.session = RegisterSession.objects.create(
            owner=self.user, owner_key=f"user:{self.user.pk}"
        )
        self.client = APIClient()
        self.client.force_authenticate(self.user)

    def checkout(self, *, key="checkout-print-1"):
        # The POS always sends an idempotency key, which is what puts the whole
        # checkout — print steps included — inside one transaction.
        return self.client.post(
            "/api/orders/checkout/",
            {
                "register_session": self.session.pk,
                "lines": [{"variant": self.variant.pk, "quantity": "2"}],
                "payment_method": "cash",
                "print_invoice": {"agent_id": "till-1"},
            },
            format="json",
            HTTP_IDEMPOTENCY_KEY=key,
        )

    def assertSaleWentThrough(self, response):
        self.assertEqual(response.status_code, 201, response.data)
        order = Order.objects.get(pk=response.data["id"])
        self.assertEqual(order.status, Order.Status.PAID)
        self.stock.refresh_from_db()
        self.assertEqual(self.stock.quantity_on_hand, Decimal("48"))
        return order

    def requires_postgres(self):
        if connection.vendor != "postgresql":
            self.skipTest(
                "A failing statement only aborts the surrounding transaction on "
                "the real database."
            )

    def test_the_happy_path_still_returns_a_claimed_print_job(self):
        """Guards the premise: without a fault the receipt really is claimed."""
        response = self.checkout()
        self.assertSaleWentThrough(response)
        self.assertIn("print_job", response.data)

    def test_a_receipt_rendering_fault_does_not_discard_the_sale(self):
        with mock.patch(
            "apps.printing.services.build_receipt_payload", _raise_plain
        ):
            response = self.checkout()

        order = self.assertSaleWentThrough(response)
        # No receipt, and the response says so by omission rather than by
        # pretending one was claimed. The order is reprintable from its record.
        self.assertNotIn("print_job", response.data)
        self.assertEqual(order.print_jobs.count(), 0)

    def test_a_receipt_database_fault_does_not_discard_the_sale(self):
        self.requires_postgres()
        with mock.patch(
            "apps.printing.services.build_receipt_payload", _abort_the_transaction
        ):
            response = self.checkout()

        self.assertSaleWentThrough(response)
        self.assertNotIn("print_job", response.data)

    def test_a_kitchen_chit_database_fault_does_not_discard_the_sale(self):
        """The kitchen enqueue is already wrapped in ``try/except`` — but a
        database error there aborts the transaction, so the swallow cannot save
        the sale on its own."""
        self.requires_postgres()
        with mock.patch(
            "apps.printing.services.enqueue_kitchen_print_jobs", _abort_the_transaction
        ):
            response = self.checkout()

        self.assertSaleWentThrough(response)
