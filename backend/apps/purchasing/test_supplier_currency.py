"""Costing a purchase the supplier invoiced in another currency.

The invariant every test here defends: **``PurchaseLine.unit_cost`` is always
the shop's own currency.** What the supplier invoiced lives beside it, and the
rate that converted them is frozen on the order. Everything downstream of
``unit_cost`` — net cost, landed-cost allocation, valuation, COGS, margin —
therefore never learns a currency was involved.
"""

from datetime import timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.urls import reverse
from django.utils import timezone
from rest_framework.test import APITestCase

from apps.catalog.models import Product, ProductVariant
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.fx import currencies as ref
from apps.fx.models import ExchangeRate
from apps.fx.rates import invalidate_rate_cache
from apps.fx.services import ensure_builtin_currencies
from apps.purchasing import currency as purchase_currency
from apps.purchasing.models import PurchaseOrder, Supplier


class SupplierCurrencyTestCase(APITestCase):
    def setUp(self):
        super().setUp()
        ensure_builtin_currencies()
        invalidate_rate_cache()
        ensure_role_groups()
        self.now = timezone.now()
        self.user = get_user_model().objects.create_user(
            username="buyer", password="pw-buyer-1"
        )
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(self.user)
        self.supplier = Supplier.objects.create(name="Istanbul Trading")
        self.product = Product.objects.create(name="Kettle")
        self.variant = ProductVariant.objects.create(
            product=self.product,
            sku="KET-1",
            unit_price=Decimal("120.00"),
            is_default=True,
        )

    def add_rate(self, rate, *, at=None, frm="USD"):
        return ExchangeRate.objects.create(
            from_currency_id=frm,
            to_currency_id="LYD",
            instrument=ref.INSTRUMENT_CASH,
            effective_at=at or self.now,
            rate=Decimal(rate),
            source=ref.SOURCE_RELAY,
        )

    def post_order(self, **overrides):
        payload = {
            "supplier": self.supplier.pk,
            "lines": [
                {
                    "variant": self.variant.pk,
                    "quantity": "10",
                    "unit_cost": "0.00",
                }
            ],
        }
        payload.update(overrides)
        return self.client.post(
            reverse("purchaseorder-list"), payload, format="json"
        )


class BaseCurrencyOrdersAreUnchangedTests(SupplierCurrencyTestCase):
    """Every order that exists today keeps behaving exactly as it did."""

    def test_an_order_with_no_currency_stores_the_cost_it_was_sent(self):
        response = self.post_order(
            lines=[
                {
                    "variant": self.variant.pk,
                    "quantity": "10",
                    "unit_cost": "80.00",
                }
            ]
        )
        self.assertEqual(response.status_code, 201, response.data)
        order = PurchaseOrder.objects.get(pk=response.data["id"])
        line = order.lines.get()
        self.assertEqual(line.unit_cost, Decimal("80.00"))
        self.assertIsNone(line.unit_cost_in_currency)
        self.assertIsNone(order.currency_id)
        self.assertIsNone(order.exchange_rate)

    def test_the_derived_foreign_total_is_absent(self):
        response = self.post_order(
            lines=[
                {
                    "variant": self.variant.pk,
                    "quantity": "10",
                    "unit_cost": "80.00",
                }
            ]
        )
        self.assertIsNone(response.data["foreign_total"])


class ForeignCurrencyOrderTests(SupplierCurrencyTestCase):
    def setUp(self):
        super().setUp()
        self.add_rate("6.85")

    def test_the_invoiced_cost_is_converted_into_the_shops_currency(self):
        response = self.post_order(
            currency="USD",
            lines=[
                {
                    "variant": self.variant.pk,
                    "quantity": "10",
                    "unit_cost": "0.00",
                    "unit_cost_in_currency": "12.00",
                }
            ],
        )
        self.assertEqual(response.status_code, 201, response.data)
        line = PurchaseOrder.objects.get(pk=response.data["id"]).lines.get()
        self.assertEqual(line.unit_cost, Decimal("82.20"))
        self.assertEqual(line.unit_cost_in_currency, Decimal("12.00"))

    def test_the_rate_is_frozen_on_the_order_with_its_provenance(self):
        response = self.post_order(
            currency="USD",
            lines=[
                {
                    "variant": self.variant.pk,
                    "quantity": "10",
                    "unit_cost": "0.00",
                    "unit_cost_in_currency": "12.00",
                }
            ],
        )
        order = PurchaseOrder.objects.get(pk=response.data["id"])
        self.assertEqual(order.exchange_rate, Decimal("6.85000000"))
        self.assertEqual(order.rate_source, ref.SOURCE_RELAY)
        self.assertIsNotNone(order.rate_effective_at)

    def test_a_later_rate_move_does_not_touch_the_recorded_cost(self):
        # The buy-side mirror of the sell-side rule: a purchase order records
        # what the shop actually PAID. Re-deriving it would rewrite the margin
        # on goods already sold.
        response = self.post_order(
            currency="USD",
            lines=[
                {
                    "variant": self.variant.pk,
                    "quantity": "10",
                    "unit_cost": "0.00",
                    "unit_cost_in_currency": "12.00",
                }
            ],
        )
        order = PurchaseOrder.objects.get(pk=response.data["id"])
        self.add_rate("9.50", at=timezone.now())
        invalidate_rate_cache()
        order.refresh_from_db()
        line = order.lines.get()
        self.assertEqual(line.unit_cost, Decimal("82.20"))
        self.assertEqual(order.exchange_rate, Decimal("6.85000000"))

    def test_a_typed_rate_overrides_the_feed_and_is_marked_as_the_shops_own(self):
        response = self.post_order(
            currency="USD",
            exchange_rate="7.20",
            lines=[
                {
                    "variant": self.variant.pk,
                    "quantity": "10",
                    "unit_cost": "0.00",
                    "unit_cost_in_currency": "12.00",
                }
            ],
        )
        self.assertEqual(response.status_code, 201, response.data)
        order = PurchaseOrder.objects.get(pk=response.data["id"])
        self.assertEqual(order.exchange_rate, Decimal("7.20000000"))
        self.assertEqual(order.rate_source, ref.SOURCE_MANUAL)
        self.assertEqual(order.lines.get().unit_cost, Decimal("86.40"))

    def test_the_foreign_total_reconciles_against_the_paper_invoice(self):
        response = self.post_order(
            currency="USD",
            lines=[
                {
                    "variant": self.variant.pk,
                    "quantity": "10",
                    "unit_cost": "0.00",
                    "unit_cost_in_currency": "12.00",
                }
            ],
        )
        self.assertEqual(Decimal(response.data["foreign_total"]), Decimal("120.00"))

    def test_the_stored_totals_stay_in_the_shops_currency(self):
        # What every report reads must not change meaning.
        response = self.post_order(
            currency="USD",
            lines=[
                {
                    "variant": self.variant.pk,
                    "quantity": "10",
                    "unit_cost": "0.00",
                    "unit_cost_in_currency": "12.00",
                }
            ],
        )
        order = PurchaseOrder.objects.get(pk=response.data["id"])
        self.assertEqual(order.subtotal, Decimal("822.00"))
        self.assertEqual(order.total, Decimal("822.00"))

    def test_an_order_in_a_currency_with_no_rate_is_refused_not_guessed(self):
        response = self.post_order(
            currency="TRY",
            lines=[
                {
                    "variant": self.variant.pk,
                    "quantity": "10",
                    "unit_cost": "0.00",
                    "unit_cost_in_currency": "300.00",
                }
            ],
        )
        self.assertEqual(response.status_code, 400)
        self.assertIn("exchange_rate", response.data)

    def test_a_currency_with_no_rate_is_accepted_when_a_rate_is_typed(self):
        response = self.post_order(
            currency="TRY",
            exchange_rate="0.21",
            lines=[
                {
                    "variant": self.variant.pk,
                    "quantity": "10",
                    "unit_cost": "0.00",
                    "unit_cost_in_currency": "300.00",
                }
            ],
        )
        self.assertEqual(response.status_code, 201, response.data)
        self.assertEqual(
            PurchaseOrder.objects.get(pk=response.data["id"]).lines.get().unit_cost,
            Decimal("63.00"),
        )

    def test_clearing_the_currency_clears_the_rate_and_the_foreign_cost(self):
        response = self.post_order(
            currency="USD",
            lines=[
                {
                    "variant": self.variant.pk,
                    "quantity": "10",
                    "unit_cost": "0.00",
                    "unit_cost_in_currency": "12.00",
                }
            ],
        )
        order_id = response.data["id"]
        response = self.client.patch(
            reverse("purchaseorder-detail", kwargs={"pk": order_id}),
            {
                "currency": None,
                "lines": [
                    {
                        "variant": self.variant.pk,
                        "quantity": "10",
                        "unit_cost": "75.00",
                        # Sent, and must be discarded: an order with no currency
                        # has nothing for a foreign amount to be denominated in.
                        "unit_cost_in_currency": "12.00",
                    }
                ],
            },
            format="json",
        )
        self.assertEqual(response.status_code, 200, response.data)
        order = PurchaseOrder.objects.get(pk=order_id)
        self.assertIsNone(order.currency_id)
        self.assertIsNone(order.exchange_rate)
        line = order.lines.get()
        self.assertEqual(line.unit_cost, Decimal("75.00"))
        self.assertIsNone(line.unit_cost_in_currency)


class CostGuardSeesOneCurrencyTests(SupplierCurrencyTestCase):
    """The guard compares a cost against a selling price. Both must be base.

    Without converting before the guard runs, every foreign line would look
    like a catastrophic loss (12 USD "below" a 120 LYD price) or a wild spike,
    and the buyer would be asked to acknowledge a warning that is nonsense.
    """

    def setUp(self):
        super().setUp()
        self.add_rate("6.85")

    def test_the_derived_cost_replaces_whatever_base_cost_was_sent(self):
        """The guard must judge the DERIVED cost, not the one on the wire.

        The base ``unit_cost`` here is absurd (5,000 against a 120 price) and
        would trip the guard on its own. It must be overwritten by the derived
        82.20 before the guard ever sees it — which is also what stops a client
        from sending two numbers that disagree.
        """
        response = self.post_order(
            currency="USD",
            lines=[
                {
                    "variant": self.variant.pk,
                    "quantity": "10",
                    "unit_cost": "5000.00",
                    "unit_cost_in_currency": "12.00",
                }
            ],
        )
        self.assertEqual(response.status_code, 201, response.data)
        line = PurchaseOrder.objects.get(pk=response.data["id"]).lines.get()
        self.assertEqual(line.unit_cost, Decimal("82.20"))

    def test_a_genuinely_absurd_foreign_cost_is_still_caught(self):
        # 300 USD = 2,055 LYD against a 120 LYD price. The guard must still see
        # it — converting must not disarm the check.
        response = self.post_order(
            currency="USD",
            lines=[
                {
                    "variant": self.variant.pk,
                    "quantity": "1",
                    "unit_cost": "0.00",
                    "unit_cost_in_currency": "300.00",
                }
            ],
        )
        self.assertEqual(response.status_code, 400, response.data)

    def test_acknowledging_lets_a_thin_foreign_margin_through(self):
        response = self.post_order(
            currency="USD",
            acknowledge_cost_warnings=True,
            lines=[
                {
                    "variant": self.variant.pk,
                    "quantity": "1",
                    "unit_cost": "0.00",
                    "unit_cost_in_currency": "300.00",
                }
            ],
        )
        self.assertEqual(response.status_code, 201, response.data)


class ConversionUnitTests(SupplierCurrencyTestCase):
    """The service itself, away from the API."""

    def test_conversion_rounds_once_to_the_base_precision(self):
        self.assertEqual(
            purchase_currency.convert_unit_cost(
                "12.005", currency_code="USD", rate=Decimal("6.85")
            ),
            Decimal("82.23"),
        )

    def test_a_missing_rate_is_an_error_not_a_silent_one_to_one(self):
        with self.assertRaises(purchase_currency.PurchaseCurrencyError):
            purchase_currency.convert_unit_cost(
                "12.00", currency_code="USD", rate=None
            )

    def test_a_non_positive_rate_is_refused(self):
        with self.assertRaises(purchase_currency.PurchaseCurrencyError):
            purchase_currency.convert_unit_cost(
                "12.00", currency_code="USD", rate=Decimal("0")
            )

    def test_the_shops_own_currency_is_not_foreign(self):
        self.assertFalse(purchase_currency.is_foreign("LYD"))
        self.assertFalse(purchase_currency.is_foreign(""))
        self.assertFalse(purchase_currency.is_foreign(None))
        self.assertTrue(purchase_currency.is_foreign("USD"))

    def test_resolving_a_rate_for_the_shops_own_currency_returns_nothing(self):
        self.assertIsNone(purchase_currency.resolve_order_rate("LYD"))

    def test_an_older_rate_can_be_resolved_for_a_backdated_order(self):
        self.add_rate("6.10", at=self.now - timedelta(days=5))
        self.add_rate("6.85", at=self.now)
        invalidate_rate_cache()
        resolved = purchase_currency.resolve_order_rate(
            "USD", at=self.now - timedelta(days=4)
        )
        self.assertEqual(resolved.rate, Decimal("6.10"))


class ForeignCostReachesValuationTests(SupplierCurrencyTestCase):
    """The point of the whole feature: the converted cost becomes the cost basis.

    Recording what the supplier invoiced is only worth doing if that number ends
    up as the shop's real cost of goods. These tests follow it all the way from
    the invoice to stock valuation.
    """

    def setUp(self):
        super().setUp()
        self.add_rate("6.85")

    def _receive(self, **overrides):
        response = self.post_order(**overrides)
        self.assertEqual(response.status_code, 201, response.data)
        order_id = response.data["id"]
        self.client.post(
            reverse("purchaseorder-submit", args=[order_id]), format="json"
        )
        received = self.client.post(
            reverse("purchaseorder-receive", args=[order_id]), format="json"
        )
        self.assertEqual(received.status_code, 200, received.data)
        return order_id

    def _latest_ledger_rate(self):
        from apps.inventory.models import StockLedgerEntry

        entry = StockLedgerEntry.objects.filter(variant=self.variant).latest("id")
        return entry.valuation_rate.quantize(Decimal("0.01"))

    def test_stock_is_valued_at_the_converted_cost_not_the_invoiced_one(self):
        from apps.inventory.models import StockItem, StockValuationBin

        self._receive(
            currency="USD",
            lines=[
                {
                    "variant": self.variant.pk,
                    "quantity": "10",
                    "unit_cost": "0.00",
                    "unit_cost_in_currency": "12.00",
                }
            ],
        )
        stock = StockItem.objects.get(variant=self.variant)
        self.assertEqual(stock.quantity_on_hand, Decimal("10.000"))
        # 82.20 per unit, NOT 12.00 — the dollar figure never becomes a dinar
        # valuation.
        valuation = StockValuationBin.objects.filter(variant=self.variant).first()
        self.assertIsNotNone(valuation, "expected the receipt to be valued")
        self.assertEqual(
            valuation.valuation_rate.quantize(Decimal("0.01")), Decimal("82.20")
        )

    def test_the_valuation_ledger_carries_the_converted_cost(self):
        self._receive(
            currency="USD",
            lines=[
                {
                    "variant": self.variant.pk,
                    "quantity": "10",
                    "unit_cost": "0.00",
                    "unit_cost_in_currency": "12.00",
                }
            ],
        )
        self.assertEqual(self._latest_ledger_rate(), Decimal("82.20"))

    def test_two_deliveries_at_different_rates_value_differently(self):
        """The reason to freeze the rate per order rather than per shop.

        Same dollar price, two different weeks, two different costs — which is
        exactly what a moving-average or FIFO cost should reflect.
        """
        self._receive(
            currency="USD",
            lines=[
                {
                    "variant": self.variant.pk,
                    "quantity": "10",
                    "unit_cost": "0.00",
                    "unit_cost_in_currency": "12.00",
                }
            ],
        )
        first = self._latest_ledger_rate()

        self.add_rate("7.50", at=timezone.now())
        invalidate_rate_cache()
        self._receive(
            currency="USD",
            lines=[
                {
                    "variant": self.variant.pk,
                    "quantity": "10",
                    "unit_cost": "0.00",
                    "unit_cost_in_currency": "12.00",
                }
            ],
        )
        second = self._latest_ledger_rate()

        self.assertEqual(first, Decimal("82.20"))
        self.assertEqual(second, Decimal("90.00"))

    def test_a_base_currency_delivery_is_valued_exactly_as_before(self):
        self._receive(
            lines=[
                {
                    "variant": self.variant.pk,
                    "quantity": "10",
                    "unit_cost": "80.00",
                }
            ]
        )
        self.assertEqual(self._latest_ledger_rate(), Decimal("80.00"))


class PosCashPurchaseStaysInTheDrawersCurrencyTests(SupplierCurrencyTestCase):
    """A drawer pay-out happens in the shop's own cash.

    Recording a foreign-currency purchase against it would put a converted
    figure next to a cash movement that never happened in that currency, and the
    register would reconcile against a number nobody counted.
    """

    def setUp(self):
        super().setUp()
        self.add_rate("6.85")

    def test_a_foreign_currency_cash_purchase_is_refused(self):
        """Refused on the CURRENCY, not incidentally on a missing session."""
        from types import SimpleNamespace

        from rest_framework import serializers as drf_serializers

        from apps.fx.models import Currency
        from apps.purchasing.services import create_pos_cash_purchase
        from apps.sales.models import RegisterSession

        RegisterSession.objects.create(
            owner=self.user,
            owner_key=f"user:{self.user.pk}",
            status=RegisterSession.Status.OPEN,
            opening_cash=Decimal("100.00"),
        )
        request = SimpleNamespace(user=self.user)

        with self.assertRaises(drf_serializers.ValidationError) as caught:
            create_pos_cash_purchase(
                request=request,
                validated_data={
                    "supplier": self.supplier,
                    "currency": Currency.objects.get(pk="USD"),
                    "lines": [],
                },
            )
        self.assertIn("currency", caught.exception.detail)

    def test_a_base_currency_cash_purchase_is_not_blocked_by_the_new_check(self):
        """The guard must not break the flow it sits in front of."""
        from types import SimpleNamespace

        from rest_framework import serializers as drf_serializers

        from apps.purchasing.services import create_pos_cash_purchase
        from apps.sales.models import RegisterSession

        RegisterSession.objects.create(
            owner=self.user,
            owner_key=f"user:{self.user.pk}",
            status=RegisterSession.Status.OPEN,
            opening_cash=Decimal("100.00"),
        )
        request = SimpleNamespace(user=self.user)

        try:
            create_pos_cash_purchase(
                request=request,
                validated_data={
                    "supplier": self.supplier,
                    "currency": None,
                    "lines": [],
                },
            )
        except drf_serializers.ValidationError as error:
            # It may still fail for its own reasons (no lines); it must not
            # fail on the currency.
            self.assertNotIn("currency", error.detail)


class RateIsReadAsOfTheInvoiceDateTests(SupplierCurrencyTestCase):
    """An invoice is costed at the rate that applied when it was billed.

    An importer types last Tuesday's invoice in on Sunday. Costing it at
    Sunday's rate silently misstates the cost basis by however far the dinar
    moved in between — exactly the error this feature exists to remove.
    """

    def setUp(self):
        super().setUp()
        self.today = timezone.localdate()
        # A falling dinar over four days.
        self.add_rate("6.10", at=self.now - timedelta(days=4))
        self.add_rate("6.85", at=self.now - timedelta(days=2))
        self.add_rate("7.50", at=self.now)
        invalidate_rate_cache()

    def _order(self, **overrides):
        response = self.post_order(
            currency="USD",
            lines=[
                {
                    "variant": self.variant.pk,
                    "quantity": "10",
                    "unit_cost": "0.00",
                    "unit_cost_in_currency": "12.00",
                }
            ],
            **overrides,
        )
        self.assertEqual(response.status_code, 201, response.data)
        return PurchaseOrder.objects.get(pk=response.data["id"])

    def test_an_invoice_dated_earlier_uses_that_days_rate(self):
        order = self._order(
            supplier_invoice_date=(self.today - timedelta(days=2)).isoformat()
        )
        self.assertEqual(order.exchange_rate, Decimal("6.85000000"))
        self.assertEqual(order.lines.get().unit_cost, Decimal("82.20"))

    def test_an_older_invoice_reaches_further_back(self):
        order = self._order(
            supplier_invoice_date=(self.today - timedelta(days=3)).isoformat()
        )
        self.assertEqual(order.exchange_rate, Decimal("6.10000000"))
        # 12.00 USD at 6.10 is 73.20 per unit.
        self.assertEqual(order.lines.get().unit_cost, Decimal("73.20"))

    def test_no_invoice_date_falls_back_to_today(self):
        order = self._order()
        self.assertEqual(order.exchange_rate, Decimal("7.50000000"))
        self.assertEqual(order.lines.get().unit_cost, Decimal("90.00"))

    def test_an_invoice_dated_today_uses_the_latest_rate_of_the_day(self):
        # End-of-day, not midnight: a rate published this morning must count.
        order = self._order(supplier_invoice_date=self.today.isoformat())
        self.assertEqual(order.exchange_rate, Decimal("7.50000000"))

    def test_the_rates_own_instant_is_recorded_so_the_choice_is_auditable(self):
        order = self._order(
            supplier_invoice_date=(self.today - timedelta(days=2)).isoformat()
        )
        self.assertIsNotNone(order.rate_effective_at)
        # It is the RATE's instant, not the invoice date — that is what makes
        # "which rate did we use?" answerable years later.
        self.assertLess(order.rate_effective_at, timezone.now())

    def test_a_typed_rate_still_wins_over_the_invoice_date_lookup(self):
        order = self._order(
            supplier_invoice_date=(self.today - timedelta(days=2)).isoformat(),
            exchange_rate="9.99",
        )
        self.assertEqual(order.exchange_rate, Decimal("9.99000000"))
        self.assertEqual(order.rate_source, ref.SOURCE_MANUAL)

    def test_the_moment_helper_is_the_end_of_the_invoiced_day(self):
        from datetime import date

        moment = purchase_currency.rate_moment_for(date(2026, 8, 25))
        self.assertEqual(moment.date(), date(2026, 8, 25))
        self.assertEqual(moment.hour, 23)
        self.assertIsNone(purchase_currency.rate_moment_for(None))
