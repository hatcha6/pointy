"""الأمانات, end to end: intake, sale, the ledger, the payable and the payout.

The consignment path is the one in this plan where the obvious implementation is
*almost* right and the gap is invisible for a year. A consigned unit enters the
ledger at ``+1 @ 0`` and, if nothing else is done, leaves it at ``-1 @ payout``:
ten thousand dinars of value leaving a ledger they never entered. The bin
self-heals because it is derived; the ledger is append-only and does not. So
most of what is checked here is not "does it sell" but "does the ledger still
add up afterwards".
"""

from decimal import Decimal

from django.test import TestCase

from apps.catalog.models import Product
from apps.core.models import ShopSettings
from apps.customers.models import Customer
from apps.messaging.models import MessagingGateway, OutboundMessage
from apps.sales.models import RegisterCashMovement, RegisterSession
from apps.sales.services import checkout_order, return_order_items
from apps.treasury.position import obligations

from . import consignment as figures
from . import consignment_service
from .integrity import assert_tracking_invariants, tracking_invariant_violations
from .models import (
    ConsignmentAgreement,
    ConsignorPayout,
    StockItem,
    StockLedgerEntry,
    StockUnit,
    StockValuationBin,
)
from .tracked_testing import receive, tracked_product

WATCH_A = "ROLEX-116610-A"
WATCH_B = "ROLEX-116610-B"

_TILL = 0


def _session(user=None):
    global _TILL
    _TILL += 1
    return RegisterSession.objects.create(
        owner=user,
        owner_key=f"consign-till-{_TILL}",
        status=RegisterSession.Status.OPEN,
        opening_cash=Decimal("0.00"),
    )


class ConsignmentTestCase(TestCase):
    def setUp(self):
        self.product = tracked_product(
            name="ساعة رولكس",
            sku="RLX-116610",
            mode=Product.TrackingMode.SERIAL,
            unit_price="12000.00",
        )
        self.variant = self.product.default_variant
        self.consignor = Customer.objects.create(full_name="سالم", phone="0912345678")
        self.agreement = ConsignmentAgreement.objects.create(
            consignor=self.consignor,
            payout_mode=ConsignmentAgreement.PayoutMode.FIXED,
            payout_rate=Decimal("10000.00"),
        )

    def _take_in(self, *codes, **overrides):
        return consignment_service.take_into_consignment(
            agreement=self.agreement,
            items=[
                {
                    "variant": self.variant,
                    "code": code,
                    "declared_value": Decimal("12000.00"),
                    **overrides,
                }
                for code in codes
            ],
        )

    def _sell(self, unit, price="12000.00", *, sale_type=None, session=None):
        kwargs = {}
        if sale_type is not None:
            kwargs["sale_type"] = sale_type
        return checkout_order(
            register_session=session or _session(),
            lines_data=[
                {
                    "variant": self.variant,
                    "quantity": Decimal("1"),
                    "effective_unit_price": Decimal(price),
                    "stock_units": [unit.pk],
                }
            ],
            payments_data=(
                [] if sale_type == "credit" else [
                    {"method": "cash", "amount": Decimal(price)}
                ]
            ),
            customer=Customer.objects.create(full_name="مشتري") if sale_type else None,
            **kwargs,
        )


class IntakeTests(ConsignmentTestCase):
    def test_goods_arrive_counted_and_worth_nothing(self):
        """The whole of §5.8's first two rows, in one assertion each."""
        units = self._take_in(WATCH_A, WATCH_B)

        self.assertEqual(len(units), 2)
        item = StockItem.objects.get(variant=self.variant)
        # Counted: the watches are on the shelf and a stock count will find them.
        self.assertEqual(item.quantity_on_hand, Decimal("2.000"))
        bin_row = StockValuationBin.objects.get(variant=self.variant)
        # Worth nothing: they are not the shop's.
        self.assertEqual(bin_row.stock_value, Decimal("0.000000"))
        for unit in StockUnit.objects.all():
            self.assertTrue(unit.is_consignment)
            self.assertEqual(unit.consignor_id, self.consignor.pk)
            self.assertEqual(unit.incoming_rate, Decimal("0.000000"))
        assert_tracking_invariants()

    def test_consigned_goods_do_not_dilute_the_valuation_rate(self):
        """Invariant 9, which is why the engine tracks unowned quantity at all.

        Three owned handsets at 1,200 beside seven consigned watches must still
        report 1,200 apiece. Without the divisor rule the bin says 360 and every
        report that multiplies a rate by a quantity is wrong by a factor of
        three.
        """
        receive(
            variant=self.variant,
            quantity=3,
            unit_cost="1200.00",
            units=[{"code": f"OWNED-{index}"} for index in range(3)],
        )
        self._take_in(*[f"CONSIGNED-{index}" for index in range(7)])

        bin_row = StockValuationBin.objects.get(variant=self.variant)
        self.assertEqual(bin_row.quantity, Decimal("10.000"))
        self.assertEqual(bin_row.stock_value, Decimal("3600.000000"))
        self.assertEqual(bin_row.valuation_rate, Decimal("1200.000000"))
        assert_tracking_invariants()

    def test_the_voucher_keeps_the_words_it_was_printed_with(self):
        settings = ShopSettings.load()
        settings.consignment_clause_owner_risk = "النص الأول"
        settings.save(update_fields=["consignment_clause_owner_risk"])

        agreement, _ = consignment_service.submit_agreement(self.agreement)
        self.assertEqual(agreement.liability_clause, "النص الأول")

        settings.consignment_clause_owner_risk = "النص الثاني"
        settings.save(update_fields=["consignment_clause_owner_risk"])
        agreement.refresh_from_db()
        # Re-wording the template has not re-worded a signed contract.
        self.assertEqual(agreement.liability_clause, "النص الأول")

    def test_an_agreement_is_numbered_from_a_counter(self):
        second = ConsignmentAgreement.objects.create(
            consignor=self.consignor,
            payout_mode=ConsignmentAgreement.PayoutMode.FIXED,
            payout_rate=Decimal("500.00"),
        )
        self.assertTrue(self.agreement.number)
        self.assertNotEqual(self.agreement.number, second.number)


class ConsignmentSaleTests(ConsignmentTestCase):
    def test_the_payout_becomes_the_cost_and_the_ledger_balances(self):
        """Invariant 10: value leaving the ledger is value that entered it."""
        unit = self._take_in(WATCH_A)[0]

        order = self._sell(unit, "12000.00")

        unit.refresh_from_db()
        self.assertEqual(unit.status, StockUnit.Status.SOLD)
        self.assertEqual(unit.incoming_rate, Decimal("10000.000000"))
        line = order.lines.get()
        # COGS is the payout, so gross profit is the shop's commission and every
        # existing margin report is already right.
        self.assertEqual(line.unit_cost, Decimal("10000.00"))
        self.assertEqual(line.line_profit, Decimal("2000.00"))

        entries = list(
            StockLedgerEntry.objects.filter(variant=self.variant).order_by("id")
        )
        kinds = [entry.voucher_type for entry in entries]
        self.assertEqual(
            kinds,
            [
                StockLedgerEntry.VoucherType.CONSIGNMENT_INTAKE,
                StockLedgerEntry.VoucherType.CONSIGNMENT_COST,
                StockLedgerEntry.VoucherType.SALE,
            ],
        )
        cost_entry = entries[1]
        # The purchase half: no quantity, all value, posted immediately before
        # the issue it pays for.
        self.assertEqual(cost_entry.quantity_change, Decimal("0.000"))
        self.assertEqual(cost_entry.value_change, Decimal("10000.000000"))
        self.assertEqual(entries[2].value_change, Decimal("-10000.000000"))
        # And the running value never dips below zero on the way through.
        self.assertTrue(all(entry.balance_value >= 0 for entry in entries))
        assert_tracking_invariants()

    def test_a_commission_payout_follows_the_price_actually_paid(self):
        self.agreement.payout_mode = ConsignmentAgreement.PayoutMode.COMMISSION
        self.agreement.commission_pct = Decimal("15.00")
        self.agreement.payout_rate = None
        self.agreement.save()
        unit = self._take_in(WATCH_A)[0]

        self._sell(unit, "10000.00")

        unit.refresh_from_db()
        self.assertEqual(unit.incoming_rate, Decimal("8500.000000"))
        self.assertEqual(figures.consignor_payout_due(unit), Decimal("8500.00"))

    def test_editing_the_terms_later_does_not_rewrite_a_settled_debt(self):
        unit = self._take_in(WATCH_A)[0]
        self._sell(unit, "12000.00")

        self.agreement.payout_rate = Decimal("1.00")
        self.agreement.save(update_fields=["payout_rate"])

        unit.refresh_from_db()
        # What was owed was fixed when the watch left the shop.
        self.assertEqual(figures.consignor_payout_due(unit), Decimal("10000.00"))

    def test_selling_below_a_fixed_payout_is_refused(self):
        """The guard the loss guard cannot be: a consigned unit's cost is zero
        until the instant of sale, so ``prevent_selling_at_loss`` is asleep on
        exactly the goods where losing money is easiest."""
        from rest_framework import serializers as drf_serializers

        unit = self._take_in(WATCH_A)[0]

        with self.assertRaises(drf_serializers.ValidationError) as caught:
            self._sell(unit, "9000.00")
        detail = caught.exception.detail
        self.assertEqual(detail["code"], "consignment_below_payout")
        self.assertEqual(detail["consignment"][0]["floor"], "10000.00")
        unit.refresh_from_db()
        self.assertEqual(unit.status, StockUnit.Status.IN_STOCK)

    def test_a_reserve_above_the_payout_is_the_floor(self):
        from rest_framework import serializers as drf_serializers

        self.agreement.reserve_price = Decimal("11000.00")
        self.agreement.save(update_fields=["reserve_price"])
        unit = self._take_in(WATCH_A)[0]

        with self.assertRaises(drf_serializers.ValidationError):
            self._sell(unit, "10500.00")

    def test_a_commission_line_has_no_arithmetic_floor(self):
        """The payout scales with the price, so the shop cannot lose its own
        money — the reserve there protects the consignor and stays advisory."""
        self.agreement.payout_mode = ConsignmentAgreement.PayoutMode.COMMISSION
        self.agreement.commission_pct = Decimal("15.00")
        self.agreement.payout_rate = None
        self.agreement.reserve_price = Decimal("11000.00")
        self.agreement.save()
        unit = self._take_in(WATCH_A)[0]

        self._sell(unit, "9000.00")

        unit.refresh_from_db()
        self.assertEqual(unit.status, StockUnit.Status.SOLD)

    def test_the_per_unit_price_overrides_the_variant(self):
        unit = self._take_in(WATCH_A, list_price=Decimal("13500.00"))[0]
        self.assertEqual(unit.list_price, Decimal("13500.00"))


class PayableTests(ConsignmentTestCase):
    def test_the_payable_is_derived_and_closes_when_paid(self):
        unit = self._take_in(WATCH_A)[0]
        self.assertEqual(figures.consignor_payable(), Decimal("0.00"))

        self._sell(unit, "12000.00")
        self.assertEqual(figures.consignor_payable(), Decimal("10000.00"))

        session = _session()
        unit.refresh_from_db()
        payout = consignment_service.disburse_payout(
            units=[unit], request=_request_with(session)
        )

        self.assertEqual(payout.amount, Decimal("10000.00"))
        self.assertEqual(figures.consignor_payable(), Decimal("0.00"))
        movement = RegisterCashMovement.objects.get()
        self.assertEqual(movement.movement_type, RegisterCashMovement.MovementType.PAY_OUT)
        self.assertEqual(movement.amount, Decimal("10000.00"))

    def test_a_credit_sale_owes_the_consignor_before_the_shop_collects(self):
        """The single fastest way a consignment module can empty a till, said
        out loud: the payout falls due when the watch sells, the receivable does
        not."""
        unit = self._take_in(WATCH_A)[0]
        self._sell(unit, "12000.00", sale_type="credit")

        self.assertEqual(figures.consignor_payable(), Decimal("10000.00"))

    def test_paying_twice_is_refused(self):
        from rest_framework import serializers as drf_serializers

        unit = self._take_in(WATCH_A)[0]
        self._sell(unit, "12000.00")
        unit.refresh_from_db()
        consignment_service.disburse_payout(
            units=[unit], request=_request_with(_session())
        )

        unit.refresh_from_db()
        with self.assertRaises(drf_serializers.ValidationError):
            consignment_service.disburse_payout(
                units=[unit], request=_request_with(_session())
            )

    def test_one_voucher_settles_several_of_the_same_consignor_s_articles(self):
        first, second = self._take_in(WATCH_A, WATCH_B)
        self._sell(first, "12000.00")
        self._sell(second, "12000.00")
        first.refresh_from_db()
        second.refresh_from_db()

        payout = consignment_service.disburse_payout(
            units=[first, second], request=_request_with(_session())
        )

        self.assertEqual(payout.amount, Decimal("20000.00"))
        self.assertEqual(ConsignorPayout.objects.count(), 1)

    def test_the_money_position_carries_the_obligation_as_an_overlay(self):
        unit = self._take_in(WATCH_A)[0]
        self._sell(unit, "12000.00")

        block = obligations()
        self.assertEqual(block["consignor_payable"], Decimal("10000.00"))
        self.assertEqual(block["custody"]["unit_count"], 0)

    def test_custody_exposure_counts_what_is_still_held(self):
        self._take_in(WATCH_A, WATCH_B)
        block = obligations()
        self.assertEqual(block["custody"]["unit_count"], 2)
        self.assertEqual(block["custody"]["declared_value"], Decimal("24000.00"))


class NotificationTests(ConsignmentTestCase):
    def setUp(self):
        super().setUp()
        MessagingGateway.objects.create(
            name="gate",
            channel=MessagingGateway.Channel.SMS,
            is_active=True,
        )

    def test_the_consignor_hears_about_it_the_moment_it_sells(self):
        unit = self._take_in(WATCH_A)[0]
        # The message is queued on commit, deliberately: a message about a sale
        # that then rolled back would be worse than no message at all.
        with self.captureOnCommitCallbacks(execute=True):
            self._sell(unit, "12000.00")

        message = OutboundMessage.objects.get()
        self.assertEqual(message.source_type, "consignment_sale")
        self.assertIn("10000.00", message.body)
        self.assertIn("سالم", message.body)

    def test_resending_queues_one_message_not_two(self):
        unit = self._take_in(WATCH_A)[0]
        with self.captureOnCommitCallbacks(execute=True):
            self._sell(unit, "12000.00")
        unit.refresh_from_db()

        consignment_service.resend_sale_sms(unit)

        # Idempotent by the dedup key the sale already used, so a cashier who
        # taps "resend" twice queues one message rather than two.
        self.assertEqual(OutboundMessage.objects.count(), 1)

    def test_a_shop_that_turned_it_off_sends_nothing(self):
        settings = ShopSettings.load()
        settings.consignment_auto_sms_on_sale = False
        settings.save(update_fields=["consignment_auto_sms_on_sale"])
        unit = self._take_in(WATCH_A)[0]

        with self.captureOnCommitCallbacks(execute=True):
            self._sell(unit, "12000.00")

        self.assertEqual(OutboundMessage.objects.count(), 0)


class ReturnToConsignorTests(ConsignmentTestCase):
    def test_unsold_goods_go_back_with_no_money_moving(self):
        unit = self._take_in(WATCH_A)[0]

        consignment_service.return_to_consignor(unit)

        unit.refresh_from_db()
        self.assertEqual(unit.status, StockUnit.Status.RETURNED)
        item = StockItem.objects.get(variant=self.variant)
        self.assertEqual(item.quantity_on_hand, Decimal("0.000"))
        bin_row = StockValuationBin.objects.get(variant=self.variant)
        self.assertEqual(bin_row.stock_value, Decimal("0.000000"))
        self.assertEqual(ConsignorPayout.objects.count(), 0)
        assert_tracking_invariants()


class CustomerReturnTests(ConsignmentTestCase):
    def test_buying_it_in_makes_the_shop_the_owner_at_what_it_paid(self):
        unit = self._take_in(WATCH_A)[0]
        order = self._sell(unit, "12000.00")
        unit.refresh_from_db()
        consignment_service.disburse_payout(
            units=[unit], request=_request_with(_session())
        )

        return_order_items(
            order=order,
            lines=[(order.lines.get(), 1)],
            reason="عاد بعد ثلاثة أيام",
            consignment_action="buy_in",
        )

        unit.refresh_from_db()
        self.assertFalse(unit.is_consignment)
        self.assertEqual(unit.status, StockUnit.Status.IN_STOCK)
        # The shop owns a watch it paid ten thousand for, which is what happened.
        self.assertEqual(unit.incoming_rate, Decimal("10000.000000"))
        self.assertEqual(unit.stock_value, Decimal("10000.000000"))
        self.assertEqual(tracking_invariant_violations(), [])

    def test_reopening_puts_it_back_as_the_consignor_s(self):
        unit = self._take_in(WATCH_A)[0]
        order = self._sell(unit, "12000.00")
        unit.refresh_from_db()
        consignment_service.disburse_payout(
            units=[unit], request=_request_with(_session())
        )

        return_order_items(
            order=order,
            lines=[(order.lines.get(), 1)],
            reason="عاد",
            consignment_action="reopen",
        )

        unit.refresh_from_db()
        self.assertTrue(unit.is_consignment)
        self.assertEqual(unit.incoming_rate, Decimal("0.000000"))
        self.assertEqual(unit.stock_value, Decimal("0"))
        self.assertEqual(tracking_invariant_violations(), [])

    def test_an_article_already_back_on_the_shelf_cannot_be_returned_again(self):
        from rest_framework import serializers as drf_serializers

        receive(
            variant=self.variant,
            quantity=1,
            unit_cost="1000.00",
            units=[{"code": "OWNED-1"}],
        )
        owned = StockUnit.objects.get(code_normalized="OWNED1")
        order = checkout_order(
            register_session=_session(),
            lines_data=[
                {
                    "variant": self.variant,
                    "quantity": Decimal("1"),
                    "effective_unit_price": Decimal("2000.00"),
                    "stock_units": [owned.pk],
                }
            ],
            payments_data=[{"method": "cash", "amount": Decimal("2000.00")}],
        )
        line = order.lines.get()
        return_order_items(order=order, lines=[(line, 1)], reason="أول")

        owned.refresh_from_db()
        self.assertEqual(owned.status, StockUnit.Status.IN_STOCK)

        from apps.inventory import tracking

        # Planning its return again is refused outright — today the double
        # return is prevented only by quantity arithmetic, and arithmetic cannot
        # tell that the shelf has gained a second of a thing there is one of.
        with self.assertRaises(drf_serializers.ValidationError):
            tracking.plan_return(units=[owned], warehouse=owned.warehouse_id)


def _request_with(session):
    """A request whose user owns ``session`` — the till a cash payout leaves.

    ``RegisterSession.open_for`` keys on ``user:{pk}``, so the session is
    re-keyed to the user rather than the user being invented around the session.
    """
    from django.contrib.auth import get_user_model

    global _USER_SEQUENCE
    _USER_SEQUENCE += 1
    user = get_user_model().objects.create_user(
        username=f"payer-{_USER_SEQUENCE}", password="x"
    )
    RegisterSession.objects.filter(pk=session.pk).update(owner_key=f"user:{user.pk}")

    class _Request:
        pass

    request = _Request()
    request.user = user
    return request


_USER_SEQUENCE = 0
