"""Card takings held by the processor, and the deposits that pay them out.

A shop's card machine is Moamalat's: a card sale is the shop's money at once,
but it reaches the bank a day later — three days later over the weekend. These
tests hold the accounting to four promises:

* **Nothing is created or lost.** Holding a sale moves it from the bank to the
  clearing account, never anywhere else; the shop's total is the same number
  before and after the hold is switched on.
* **The bank agrees with its statement.** It gains exactly what the processor
  paid in, on the day it landed — never the sale itself.
* **A settlement can always be taken apart.** It names the sales it paid; a
  difference from the estimated fee is its own line; cancelling it puts every
  figure back.
* **A shop that never opens a clearing account sees nothing change.**
"""

from datetime import datetime, time, timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.db import IntegrityError, transaction
from django.test import TestCase

from apps.core.timeutils import business_local_date, business_timezone
from apps.documents import services as document_services
from apps.payments.models import Payment
from apps.sales.models import Order, RegisterSession

from .held_days import held_rows, pending_days
from .models import CardSettlement, CardSettlementLine, MoneyAccount
from .movements import account_movements
from .position import (
    COMPONENT_COMMISSION,
    COMPONENT_SALES,
    COMPONENT_SETTLEMENT_DIFFERENCE,
    COMPONENT_SETTLEMENT_IN,
    COMPONENT_SETTLEMENT_OUT,
    expected_balance_for,
    treasury_position,
    treasury_statement,
)
from .serializers import MoneyAccountSerializer, MoneyTransferSerializer
from .settlements import (
    SettlementError,
    cancel_settlement,
    record_settlement,
    settlement_fee_total,
)

User = get_user_model()


def money(value):
    return Decimal(value).quantize(Decimal("0.01"))


class HeldCardTestCase(TestCase):
    def setUp(self):
        super().setUp()
        self.owner = User.objects.create_superuser(
            username="owner", password="pw", email="owner@example.com"
        )
        self.today = business_local_date()
        self.cash = MoneyAccount.objects.get(kind=MoneyAccount.Kind.CASH)
        self.bank = MoneyAccount.objects.get(kind=MoneyAccount.Kind.BANK)
        self.bank.opening_at = self.today - timedelta(days=60)
        self.bank.opening_balance = Decimal("1000.00")
        self.bank.save()
        self.session = RegisterSession.objects.create(
            owner=self.owner,
            owner_key=f"user:{self.owner.pk}",
            opening_cash=Decimal("0.00"),
        )

    # --- helpers ---------------------------------------------------------

    def at(self, days_ago, hour=12, minute=0):
        """A moment on the shop's own clock, ``days_ago`` days back."""
        day = self.today - timedelta(days=days_ago)
        return datetime.combine(day, time(hour, minute), tzinfo=business_timezone())

    def pay(
        self,
        amount,
        *,
        days_ago=1,
        hour=12,
        method=Payment.Method.CARD,
        account=None,
        commission=None,
    ):
        amount = Decimal(amount)
        if commission is None:
            commission = (amount / 100).quantize(Decimal("0.01"))
        order = Order.objects.create(
            status=Order.Status.PAID,
            register_session=self.session,
            subtotal=amount,
            total=amount,
        )
        return Payment.objects.create(
            order=order,
            method=method,
            amount=amount,
            commission_percent=Decimal("1.00"),
            commission_amount=Decimal(commission),
            money_account=account,
            register_session=self.session,
            paid_at=self.at(days_ago, hour),
        )

    def open_clearing(self, *, bank=None, starts_days_ago=10, **extra):
        serializer = MoneyAccountSerializer(
            data={
                "name": "معاملات — قيد التسوية",
                "kind": MoneyAccount.Kind.CLEARING,
                "settles_into": (bank or self.bank).pk,
                "opening_at": (self.today - timedelta(days=starts_days_ago)).isoformat(),
                **extra,
            }
        )
        serializer.is_valid(raise_exception=True)
        return serializer.save()

    def position(self):
        return treasury_position(as_of=self.today)

    def balance(self, account):
        for entry in self.position()["accounts"]:
            if entry["account"].pk == account.pk:
                return entry["expected_balance"]
        raise AssertionError(f"{account.name} missing from the position")

    def component(self, account, code):
        for entry in self.position()["accounts"]:
            if entry["account"].pk != account.pk:
                continue
            return sum(
                (part["amount"] for part in entry["components"] if part["code"] == code),
                Decimal("0.00"),
            )
        raise AssertionError(f"{account.name} missing from the position")

    def settle(self, clearing, amount, *, days=None, **kwargs):
        days = days if days is not None else [day.day for day in pending_days(clearing)]
        return record_settlement(
            clearing_account=clearing,
            settled_on=kwargs.pop("settled_on", self.today),
            amount_received=Decimal(amount),
            days=days,
            actor=self.owner,
            **kwargs,
        )


class NothingChangesWithoutAClearingAccountTests(HeldCardTestCase):
    def test_card_takings_still_land_in_the_bank_at_the_sale(self):
        self.pay("100.00")
        self.assertEqual(self.balance(self.bank), money("1099.00"))
        self.assertEqual(self.position()["totals"]["in_transit"], money("0"))


class HoldingCardTakingsTests(HeldCardTestCase):
    def test_opening_a_clearing_account_moves_held_takings_and_keeps_the_total(self):
        self.pay("100.00", days_ago=3)
        self.pay("50.00", days_ago=1)
        before = self.position()["totals"]["total"]

        clearing = self.open_clearing(starts_days_ago=2)

        self.assertTrue(clearing.holds_untagged_card)
        # The three-day-old sale was already paid in; the newer one is held.
        self.assertEqual(self.balance(self.bank), money("1099.00"))
        self.assertEqual(self.balance(clearing), money("49.50"))
        totals = self.position()["totals"]
        self.assertEqual(totals["in_transit"], money("49.50"))
        self.assertEqual(totals["bank"], money("1099.00"))
        self.assertEqual(totals["total"], before)

    def test_the_held_sale_shows_its_takings_and_fee_on_the_clearing_account(self):
        clearing = self.open_clearing()
        self.pay("200.00")
        self.assertEqual(self.component(clearing, COMPONENT_SALES), money("200.00"))
        self.assertEqual(self.component(clearing, COMPONENT_COMMISSION), money("-2.00"))
        self.assertEqual(self.component(self.bank, COMPONENT_SALES), money("0.00"))

    def test_a_bank_transfer_is_never_held(self):
        clearing = self.open_clearing()
        self.pay("80.00", method=Payment.Method.TRANSFER, commission="0.00")
        self.assertEqual(self.balance(self.bank), money("1080.00"))
        self.assertEqual(self.balance(clearing), money("0.00"))

    def test_a_sale_before_the_hold_started_stays_with_the_bank(self):
        clearing = self.open_clearing(starts_days_ago=2)
        self.pay("100.00", days_ago=5)
        self.assertEqual(self.balance(clearing), money("0.00"))
        self.assertEqual(self.balance(self.bank), money("1099.00"))

    def test_another_banks_card_takings_are_not_this_accounts(self):
        second = MoneyAccount.objects.create(
            name="الأمان",
            kind=MoneyAccount.Kind.BANK,
            opening_at=self.today - timedelta(days=60),
        )
        clearing = self.open_clearing()
        self.pay("70.00", account=second)
        self.assertEqual(self.balance(second), money("69.30"))
        self.assertEqual(self.balance(clearing), money("0.00"))

    def test_untagged_takings_stay_with_the_default_when_the_hold_is_another_banks(self):
        """The exclusion must not swallow a row whose bank column is NULL."""
        second = MoneyAccount.objects.create(
            name="الأمان",
            kind=MoneyAccount.Kind.BANK,
            opening_at=self.today - timedelta(days=60),
        )
        clearing = self.open_clearing(bank=second)
        self.assertFalse(clearing.holds_untagged_card)
        self.pay("100.00")  # names no bank
        self.pay("40.00", account=second)

        self.assertEqual(self.balance(self.bank), money("1099.00"))
        self.assertEqual(self.balance(second), money("0.00"))
        self.assertEqual(self.balance(clearing), money("39.60"))

    def test_a_change_of_default_bank_does_not_move_held_takings(self):
        clearing = self.open_clearing()
        self.pay("100.00")
        second = MoneyAccount.objects.create(
            name="الأمان",
            kind=MoneyAccount.Kind.BANK,
            opening_at=self.today - timedelta(days=60),
        )
        MoneyAccount.objects.filter(pk=self.bank.pk).update(is_default=False)
        MoneyAccount.objects.filter(pk=second.pk).update(is_default=True)

        self.assertEqual(self.balance(clearing), money("99.00"))
        self.assertEqual(self.balance(second), money("0.00"))

    def test_a_refund_of_a_held_sale_is_held_too(self):
        clearing = self.open_clearing()
        sale = self.pay("100.00", days_ago=2)
        Payment.objects.create(
            order=sale.order,
            method=Payment.Method.CARD,
            amount=Decimal("-30.00"),
            commission_amount=Decimal("-0.30"),
            money_account=None,
            paid_at=self.at(1),
        )
        self.assertEqual(self.balance(clearing), money("69.30"))
        self.assertEqual(self.balance(self.bank), money("1000.00"))

    def test_the_drill_downs_list_the_same_money_as_the_balances(self):
        clearing = self.open_clearing()
        self.pay("100.00", days_ago=2)
        self.settle(clearing, "99.00")

        clearing_rows = account_movements(
            clearing, start=self.today - timedelta(days=5), end=self.today
        )["rows"]
        bank_rows = account_movements(
            self.bank, start=self.today - timedelta(days=5), end=self.today
        )["rows"]
        sources = {row["source"]: row["amount"] for row in clearing_rows}
        self.assertEqual(sources[COMPONENT_SALES], money("100.00"))
        self.assertEqual(sources[COMPONENT_COMMISSION], money("-1.00"))
        self.assertEqual(sources[COMPONENT_SETTLEMENT_OUT], money("-99.00"))
        self.assertEqual(
            [(row["source"], row["amount"]) for row in bank_rows],
            [(COMPONENT_SETTLEMENT_IN, money("99.00"))],
        )

    def test_a_count_of_the_clearing_account_expects_the_screens_figure(self):
        clearing = self.open_clearing()
        self.pay("100.00")
        self.assertEqual(expected_balance_for(clearing), self.balance(clearing))
        self.assertEqual(expected_balance_for(self.bank), self.balance(self.bank))


class RecordingASettlementTests(HeldCardTestCase):
    def test_the_deposit_moves_the_held_takings_into_the_bank(self):
        clearing = self.open_clearing()
        self.pay("100.00", days_ago=3)
        self.pay("50.00", days_ago=2)
        total = self.position()["totals"]["total"]

        settlement = self.settle(clearing, "148.50")

        self.assertEqual(settlement.expected_amount, money("148.50"))
        self.assertEqual(settlement.difference, money("0.00"))
        self.assertEqual(settlement.payment_count, 2)
        self.assertEqual(self.balance(clearing), money("0.00"))
        self.assertEqual(self.balance(self.bank), money("1148.50"))
        self.assertEqual(
            self.component(self.bank, COMPONENT_SETTLEMENT_IN), money("148.50")
        )
        self.assertEqual(self.position()["totals"]["total"], total)

    def test_a_fee_above_the_estimate_is_its_own_line_and_a_cost(self):
        clearing = self.open_clearing()
        self.pay("1000.00", days_ago=2)  # 10.00 estimated fee
        total = self.position()["totals"]["total"]

        self.settle(clearing, "985.00")  # the processor kept 15.00

        self.assertEqual(self.balance(clearing), money("0.00"))
        self.assertEqual(
            self.component(clearing, COMPONENT_SETTLEMENT_DIFFERENCE), money("-5.00")
        )
        self.assertEqual(self.balance(self.bank), money("1985.00"))
        self.assertEqual(self.position()["totals"]["total"], total - money("5.00"))
        self.assertEqual(settlement_fee_total(self.today, self.today), money("5.00"))

    def test_a_deposit_without_the_fee_hands_the_estimate_back(self):
        clearing = self.open_clearing()
        self.pay("1000.00", days_ago=2)
        self.settle(clearing, "1000.00")
        self.assertEqual(self.balance(clearing), money("0.00"))
        self.assertEqual(
            self.component(clearing, COMPONENT_SETTLEMENT_DIFFERENCE), money("10.00")
        )
        self.assertEqual(settlement_fee_total(self.today, self.today), money("-10.00"))

    def test_only_the_chosen_days_are_paid(self):
        clearing = self.open_clearing()
        self.pay("100.00", days_ago=3)
        self.pay("60.00", days_ago=2)
        first = pending_days(clearing)[0].day

        self.settle(clearing, "99.00", days=[first])

        self.assertEqual(self.balance(clearing), money("59.40"))
        self.assertEqual([day.day for day in pending_days(clearing)], [
            self.today - timedelta(days=2)
        ])

    def test_a_sale_the_processor_kept_back_stays_held(self):
        clearing = self.open_clearing()
        kept = self.pay("100.00", days_ago=2)
        self.pay("50.00", days_ago=2)
        self.settle(clearing, "49.50", exclude_payment_ids=[kept.pk])
        self.assertEqual([row.id for row in held_rows(clearing)], [kept.pk])
        self.assertEqual(self.balance(clearing), money("99.00"))

    def test_a_payment_is_never_paid_out_twice(self):
        clearing = self.open_clearing()
        sale = self.pay("100.00", days_ago=2)
        self.settle(clearing, "99.00")
        with self.assertRaises(SettlementError) as raised:
            self.settle(clearing, "99.00", payment_ids=[sale.pk], days=[])
        self.assertEqual(raised.exception.code, "payments_not_held")

        settlement = CardSettlement.objects.get()
        with self.assertRaises(IntegrityError), transaction.atomic():
            CardSettlementLine.objects.create(settlement=settlement, payment=sale)

    def test_a_deposit_cannot_pay_for_later_takings(self):
        clearing = self.open_clearing()
        self.pay("100.00", days_ago=1)
        with self.assertRaises(SettlementError) as raised:
            self.settle(
                clearing, "99.00", settled_on=self.today - timedelta(days=2)
            )
        self.assertEqual(raised.exception.code, "takings_after_deposit")

    def test_a_deposit_cannot_be_dated_in_the_future(self):
        clearing = self.open_clearing()
        self.pay("100.00")
        with self.assertRaises(SettlementError) as raised:
            self.settle(clearing, "99.00", settled_on=self.today + timedelta(days=1))
        self.assertEqual(raised.exception.code, "settled_in_future")

    def test_held_takings_that_changed_under_the_owner_are_refused(self):
        clearing = self.open_clearing()
        self.pay("100.00", days_ago=2)
        with self.assertRaises(SettlementError) as raised:
            self.settle(clearing, "99.00", expected_amount=Decimal("80.00"))
        self.assertEqual(raised.exception.code, "held_amount_changed")
        self.assertFalse(CardSettlement.objects.exists())

    def test_nothing_chosen_is_refused(self):
        clearing = self.open_clearing()
        self.pay("100.00", days_ago=2)
        with self.assertRaises(SettlementError) as raised:
            self.settle(clearing, "99.00", days=[])
        self.assertEqual(raised.exception.code, "nothing_selected")

    def test_a_statement_foots_across_the_settlement(self):
        clearing = self.open_clearing(starts_days_ago=6)
        self.pay("100.00", days_ago=5)
        self.settle(clearing, "98.00", settled_on=self.today - timedelta(days=3))
        self.pay("40.00", days_ago=2)

        statement = treasury_statement(
            start=self.today - timedelta(days=4), end=self.today
        )
        rows = {row["account"].pk: row for row in statement["accounts"]}
        held = rows[clearing.pk]
        self.assertEqual(held["opening_balance"], money("99.00"))
        self.assertEqual(held["closing_balance"], money("39.60"))
        self.assertEqual(held["closing_balance"], self.balance(clearing))
        self.assertEqual(rows[self.bank.pk]["closing_balance"], self.balance(self.bank))
        self.assertEqual(statement["totals"]["in_transit"], money("39.60"))
        self.assertEqual(
            statement["totals"]["closing_total"], self.position()["totals"]["total"]
        )


class CancellingASettlementTests(HeldCardTestCase):
    def test_cancelling_puts_every_figure_back(self):
        clearing = self.open_clearing()
        self.pay("1000.00", days_ago=2)
        before = {
            "clearing": self.balance(clearing),
            "bank": self.balance(self.bank),
            "total": self.position()["totals"]["total"],
        }
        settlement = self.settle(clearing, "985.00")

        cancel_settlement(settlement, reason="wrong amount", actor=self.owner)

        settlement.refresh_from_db()
        self.assertTrue(settlement.is_cancelled)
        self.assertEqual(self.balance(clearing), before["clearing"])
        self.assertEqual(self.balance(self.bank), before["bank"])
        self.assertEqual(self.position()["totals"]["total"], before["total"])
        self.assertEqual(settlement_fee_total(self.today, self.today), money("0.00"))
        self.assertEqual(len(held_rows(clearing)), 1)

    def test_the_released_payments_can_be_settled_again(self):
        clearing = self.open_clearing()
        self.pay("100.00", days_ago=2)
        first = self.settle(clearing, "90.00")
        cancel_settlement(first, reason="typo", actor=self.owner)

        second = self.settle(clearing, "99.00")

        self.assertEqual(second.difference, money("0.00"))
        self.assertEqual(self.balance(clearing), money("0.00"))
        self.assertEqual(self.balance(self.bank), money("1099.00"))


class CancelledCardPaymentTests(HeldCardTestCase):
    def cancel(self, payment):
        document_services.cancel(payment, reason="wrong tender", actor=self.owner)
        return Payment.objects.get(reverses=payment)

    def test_a_counter_row_backs_out_of_the_bank_the_payment_named(self):
        second = MoneyAccount.objects.create(
            name="الأمان",
            kind=MoneyAccount.Kind.BANK,
            opening_at=self.today - timedelta(days=60),
        )
        payment = self.pay("100.00", account=second)

        counter = self.cancel(payment)

        self.assertEqual(counter.money_account_id, second.pk)
        self.assertEqual(self.balance(second), money("0.00"))
        self.assertEqual(self.balance(self.bank), money("1000.00"))

    def test_a_voided_held_sale_nets_out_of_its_own_day(self):
        clearing = self.open_clearing()
        voided = self.pay("100.00", days_ago=2)
        self.pay("50.00", days_ago=2)

        self.cancel(voided)

        days = pending_days(clearing)
        self.assertEqual(len(days), 1)
        self.assertEqual(days[0].day, self.today - timedelta(days=2))
        self.assertEqual(days[0].net, money("49.50"))
        self.assertEqual(self.balance(clearing), money("49.50"))


class ClearingAccountRulesTests(HeldCardTestCase):
    def update(self, account, **data):
        serializer = MoneyAccountSerializer(account, data=data, partial=True)
        serializer.is_valid(raise_exception=False)
        return serializer

    def test_it_has_no_opening_balance_and_is_never_a_default(self):
        clearing = self.open_clearing(opening_balance="500.00", is_default=True)
        self.assertEqual(clearing.opening_balance, money("0.00"))
        self.assertFalse(clearing.is_default)
        self.bank.refresh_from_db()
        self.assertTrue(self.bank.is_default)

    def test_its_bank_and_kind_are_fixed(self):
        clearing = self.open_clearing()
        second = MoneyAccount.objects.create(
            name="الأمان", kind=MoneyAccount.Kind.BANK, opening_at=self.today
        )
        self.assertIn("settles_into", self.update(clearing, settles_into=second.pk).errors)
        self.assertIn("kind", self.update(clearing, kind=MoneyAccount.Kind.BANK).errors)
        self.assertIn("kind", self.update(self.bank, kind=MoneyAccount.Kind.CLEARING).errors)

    def test_one_open_clearing_account_per_bank(self):
        self.open_clearing()
        serializer = MoneyAccountSerializer(
            data={
                "name": "ثانٍ",
                "kind": MoneyAccount.Kind.CLEARING,
                "settles_into": self.bank.pk,
            }
        )
        self.assertFalse(serializer.is_valid())
        self.assertIn("settles_into", serializer.errors)

    def test_it_cannot_start_in_the_future_or_long_ago(self):
        for days_ago in (-1, 40):
            serializer = MoneyAccountSerializer(
                data={
                    "name": "معاملات",
                    "kind": MoneyAccount.Kind.CLEARING,
                    "settles_into": self.bank.pk,
                    "opening_at": (self.today - timedelta(days=days_ago)).isoformat(),
                }
            )
            with self.subTest(days_ago=days_ago):
                self.assertFalse(serializer.is_valid())
                self.assertIn("opening_at", serializer.errors)

    def test_its_start_is_fixed_once_a_deposit_is_recorded(self):
        clearing = self.open_clearing()
        self.pay("100.00", days_ago=2)
        moved = (self.today - timedelta(days=5)).isoformat()
        self.assertTrue(self.update(clearing, opening_at=moved).is_valid())

        self.settle(clearing, "99.00")
        self.assertIn("opening_at", self.update(clearing, opening_at=moved).errors)

    def test_held_money_is_never_transferred_by_hand(self):
        clearing = self.open_clearing()
        serializer = MoneyTransferSerializer(
            data={
                "from_account": clearing.pk,
                "to_account": self.bank.pk,
                "amount": "10.00",
            }
        )
        self.assertFalse(serializer.is_valid())

    def test_closing_stops_holding_but_keeps_what_it_holds(self):
        clearing = self.open_clearing()
        self.pay("100.00", days_ago=2)

        serializer = self.update(clearing, is_active=False)
        self.assertTrue(serializer.is_valid(), serializer.errors)
        clearing = serializer.save()
        self.assertEqual(clearing.closed_on, self.today)

        # Still shown while it holds money, and still settled from.
        self.assertEqual(self.balance(clearing), money("99.00"))
        self.settle(clearing, "99.00")
        listed = [entry["account"].pk for entry in self.position()["accounts"]]
        self.assertNotIn(clearing.pk, listed)
        self.assertEqual(self.balance(self.bank), money("1099.00"))

        self.assertIn("is_active", self.update(clearing, is_active=True).errors)

    def test_a_new_clearing_account_for_the_bank_starts_after_the_last(self):
        clearing = self.open_clearing()
        serializer = self.update(clearing, is_active=False)
        serializer.is_valid(raise_exception=True)
        serializer.save()

        overlapping = MoneyAccountSerializer(
            data={
                "name": "معاملات 2",
                "kind": MoneyAccount.Kind.CLEARING,
                "settles_into": self.bank.pk,
                "opening_at": self.today.isoformat(),
            }
        )
        self.assertFalse(overlapping.is_valid())
        self.assertIn("opening_at", overlapping.errors)

    def test_it_is_never_routed_and_never_the_untagged_default(self):
        clearing = self.open_clearing()
        self.assertFalse(MoneyAccountSerializer(clearing).data["is_routed"])
        self.assertTrue(MoneyAccountSerializer(self.bank).data["is_routed"])


class HeldCardInvariantTests(HeldCardTestCase):
    """Random days of trading, held and settled, against three invariants.

    Whatever order sales, refunds, voids, deposits and undone deposits arrive
    in, after every step:

    * the clearing account holds exactly the held sales nobody has paid out;
    * the bank holds its opening balance, the takings that never went through
      the processor, and exactly what the processor paid in — nothing else;
    * the shop's total moved only by what was sold and by what a processor
      kept beyond (or short of) the estimated fee.
    """

    SEEDS = (11, 23, 57)
    STEPS = 60

    def test_the_money_always_adds_up(self):
        import random

        for seed in self.SEEDS:
            with self.subTest(seed=seed), transaction.atomic():
                self._run(random.Random(seed))
                transaction.set_rollback(True)

    def _run(self, rng):
        clearing = self.open_clearing(starts_days_ago=12)
        opening_total = self.position()["totals"]["total"]
        sales = []
        for step in range(self.STEPS):
            roll = rng.random()
            if roll < 0.45 or not sales:
                method = (
                    Payment.Method.CARD if rng.random() < 0.85 else Payment.Method.TRANSFER
                )
                sales.append(
                    self.pay(
                        f"{rng.randint(1, 400)}.{rng.randint(0, 99):02d}",
                        days_ago=rng.randint(1, 15),
                        hour=rng.randint(0, 23),
                        method=method,
                    )
                )
            elif roll < 0.55:
                original = rng.choice(sales)
                Payment.objects.create(
                    order=original.order,
                    method=original.method,
                    amount=-(original.amount / 2).quantize(Decimal("0.01")),
                    commission_amount=-(original.commission_amount / 2).quantize(
                        Decimal("0.01")
                    ),
                    money_account=original.money_account,
                    paid_at=self.at(rng.randint(0, 1), rng.randint(0, 23)),
                )
            elif roll < 0.62:
                original = rng.choice(sales)
                if original.doc_status == "submitted":
                    document_services.cancel(original, reason="void", actor=self.owner)
                    original.refresh_from_db()
            elif roll < 0.9:
                days = [day.day for day in pending_days(clearing)]
                if days:
                    chosen = rng.sample(days, rng.randint(1, len(days)))
                    expected = sum(
                        (day.net for day in pending_days(clearing) if day.day in chosen),
                        Decimal("0.00"),
                    )
                    gap = Decimal(rng.choice(["0.00", "0.00", "-4.20", "1.15", "-0.01"]))
                    self.settle(clearing, expected + gap, days=chosen)
            else:
                live = list(CardSettlement.objects.live())
                if live:
                    cancel_settlement(rng.choice(live), reason="undo", actor=self.owner)
            self._assert_invariants(clearing, opening_total, step)
        # Not vacuous: the run settled, undid a settlement, and voided a sale.
        self.assertTrue(CardSettlement.objects.live().exists())
        self.assertTrue(CardSettlement.objects.filter(doc_status="cancelled").exists())
        self.assertTrue(Payment.objects.filter(reverses__isnull=False).exists())

    def _assert_invariants(self, clearing, opening_total, step):
        from .clearing import clearing_accounts, held_by_any_q

        position = self.position()
        balances = {entry["account"].pk: entry["expected_balance"] for entry in position["accounts"]}
        held = sum((row.net for row in held_rows(clearing)), Decimal("0.00"))
        self.assertEqual(balances[clearing.pk], held, f"held balance, step {step}")

        # Every sale here is inside the bank's window (it opened 60 days ago).
        unheld = Payment.objects.filter(
            method__in=[Payment.Method.CARD, Payment.Method.TRANSFER]
        ).exclude(held_by_any_q(clearing_accounts()))
        unheld_net = sum(
            (payment.amount - payment.commission_amount for payment in unheld),
            Decimal("0.00"),
        )
        received = sum(
            (settlement.amount_received for settlement in CardSettlement.objects.live()),
            Decimal("0.00"),
        )
        self.assertEqual(
            balances[self.bank.pk],
            self.bank.opening_balance + unheld_net + received,
            f"bank balance, step {step}",
        )

        every_sale = sum(
            (payment.amount - payment.commission_amount for payment in Payment.objects.all()),
            Decimal("0.00"),
        )
        differences = sum(
            (settlement.difference for settlement in CardSettlement.objects.live()),
            Decimal("0.00"),
        )
        self.assertEqual(
            position["totals"]["total"],
            opening_total + every_sale + differences,
            f"shop total, step {step}",
        )
