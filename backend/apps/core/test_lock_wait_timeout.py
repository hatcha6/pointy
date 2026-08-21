"""A till must never wait forever for a row lock somebody else is holding.

Postgres' default ``lock_timeout`` is 0 — wait forever. Every money mutation
here runs inside ``run_idempotent_request``'s transaction and takes row locks
(the idempotency record, the cart's stock rows, the order, the register
session), so before ``bounded_lock_wait`` a checkout that met a held lock simply
stopped: no error, no recovery, no bound. The holders are ordinary shop
operations — a bulk reprice over a few thousand products, a stock-count apply,
a legacy import — and the pathological one, a session left *idle in
transaction* by a worker that was blocked or killed mid-flight, which never
lets go at all.

The failure is injected the way it actually happens: a second, real database
connection takes ``SELECT ... FOR UPDATE`` on the row the cart needs and holds
it. It is the server-side twin of the black-hole listener — the lock is really
held, by a real session, and nothing in the request path is mocked.

The checkout runs on its own thread so that "hangs forever" is a *failing* test
rather than a hanging one: on ``main`` the thread is still blocked when the join
deadline passes and the assertion fires.
"""

import threading
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.db import connection, connections
from django.test import TransactionTestCase, override_settings
from rest_framework.test import APIClient

from apps.catalog.testing import create_product_with_default_variant
from apps.core.models import ShopSettings
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.inventory.models import StockItem
from apps.sales.models import Order, RegisterSession

#: Short enough to keep the suite quick, long enough that ordinary contention
#: between two tills (milliseconds) never trips it.
LOCK_WAIT_SECONDS = 1.0

#: How long the test is willing to believe the checkout is still working. Well
#: clear of LOCK_WAIT_SECONDS, and far under the client's real 60s deadline.
JOIN_DEADLINE_SECONDS = 20.0


@override_settings(POINTY_DB_LOCK_WAIT_TIMEOUT_SECONDS=LOCK_WAIT_SECONDS)
class CheckoutLockWaitTests(TransactionTestCase):
    """One cart, one product — whose stock row another session is sitting on."""

    # TransactionTestCase (not TestCase): the rows have to be committed, or the
    # second connection cannot see them to lock them.
    reset_sequences = True

    def setUp(self):
        if connection.vendor != "postgresql":
            self.skipTest("Row locks and lock_timeout only exist on Postgres.")
        ensure_role_groups()
        User = get_user_model()
        self.user = User.objects.create_user(username="lock-cashier", password="pass")
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        shop_settings = ShopSettings.load()
        shop_settings.allow_overselling = False
        shop_settings.enable_cash_payments = True
        shop_settings.auto_print_receipts = False
        shop_settings.save()

        self.product = create_product_with_default_variant(
            name="Rice", sku="RICE", unit_price="10.00"
        )
        self.variant = self.product.default_variant
        self.stock = StockItem.objects.create(
            variant=self.variant, quantity_on_hand=Decimal("50")
        )
        self.session = RegisterSession.objects.create(
            owner=self.user, owner_key=f"user:{self.user.pk}"
        )

    def _checkout(self, key):
        client = APIClient()
        client.force_authenticate(self.user)
        return client.post(
            "/api/orders/checkout/",
            {
                "register_session": self.session.pk,
                "lines": [{"variant": self.variant.pk, "quantity": "2"}],
                "payment_method": "cash",
            },
            format="json",
            HTTP_IDEMPOTENCY_KEY=key,
        )

    def _checkout_on_its_own_thread(self, key):
        """Run a checkout off-thread and return ``(response, timed_out)``.

        A thread is the only way to assert "did not hang": the unbounded
        behaviour blocks the caller indefinitely, which would wedge the runner
        instead of failing it.
        """
        outcome = {}

        def run():
            try:
                outcome["response"] = self._checkout(key)
            except BaseException as exc:  # surfaced by the assertions below
                outcome["error"] = exc
            finally:
                # Threads get their own connection; leave none behind for
                # TransactionTestCase's truncate to block on.
                connections.close_all()

        worker = threading.Thread(target=run, daemon=True)
        worker.start()
        worker.join(JOIN_DEADLINE_SECONDS)
        if worker.is_alive():
            return None, True
        if "error" in outcome:
            raise outcome["error"]
        return outcome["response"], False

    def _hold_the_stock_row(self):
        """A second real session holding this variant's stock row, exactly as a
        bulk operation or a stalled worker would."""
        holder = connections.create_connection("default")
        holder.set_autocommit(False)
        cursor = holder.cursor()
        cursor.execute(
            "SELECT id FROM inventory_stockitem WHERE variant_id = %s FOR UPDATE",
            [self.variant.pk],
        )
        cursor.fetchall()
        return holder

    def _release(self, holder):
        try:
            holder.rollback()
        finally:
            holder.close()

    def test_a_held_stock_row_fails_the_checkout_instead_of_hanging_it(self):
        holder = self._hold_the_stock_row()
        try:
            response, timed_out = self._checkout_on_its_own_thread("locked-checkout-1")
        finally:
            self._release(holder)

        self.assertFalse(
            timed_out,
            "checkout was still waiting on the row lock after "
            f"{JOIN_DEADLINE_SECONDS}s — an unbounded wait",
        )
        self.assertEqual(response.status_code, 503, response.data)
        self.assertEqual(response.data["detail"].code, "lock_wait_timeout")

    def test_the_failed_checkout_sold_nothing(self):
        """Fail-closed is the point: the goods must still be in stock and no
        order left half-recorded, so the cashier's retry is safe."""
        holder = self._hold_the_stock_row()
        try:
            self._checkout_on_its_own_thread("locked-checkout-2")
        finally:
            self._release(holder)

        self.stock.refresh_from_db()
        self.assertEqual(self.stock.quantity_on_hand, Decimal("50"))
        self.assertEqual(Order.objects.count(), 0)

    def test_the_same_cart_goes_through_once_the_holder_lets_go(self):
        """The bound must not poison the retry: the cashier presses checkout
        again and the sale completes normally."""
        holder = self._hold_the_stock_row()
        try:
            self._checkout_on_its_own_thread("locked-checkout-3")
        finally:
            self._release(holder)

        response, timed_out = self._checkout_on_its_own_thread("locked-checkout-4")
        self.assertFalse(timed_out)
        self.assertEqual(response.status_code, 201, response.data)
        self.stock.refresh_from_db()
        self.assertEqual(self.stock.quantity_on_hand, Decimal("48"))

    def test_an_uncontended_checkout_is_untouched(self):
        """Guards the premise: the bound costs nothing when no one is holding
        anything."""
        response, timed_out = self._checkout_on_its_own_thread("uncontended-1")
        self.assertFalse(timed_out)
        self.assertEqual(response.status_code, 201, response.data)
