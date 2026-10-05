"""Unclaimed payouts: reminded on a cadence, and never anybody's but the owner's.

§6.2.2 and §17.8. The sweep is tested end to end — sale through the real
checkout, the message through ``enqueue_message`` on a fake gateway — because
the failures worth catching are in the joins: a round spent twice, a round
never spent, a consignor texted eight times on one morning, a refusal that
burns every round before anybody registered the template.
"""

from datetime import timedelta
from decimal import Decimal
from unittest import mock

from django.urls import reverse
from django.utils import timezone

from apps.core.models import ShopSettings
from apps.messaging.models import MessagingGateway, OutboundMessage
from apps.messaging.services import NoGatewayConfigured

from . import consignment as figures
from .consignment_reminders import (
    MAX_ROUNDS,
    due_round,
    send_unclaimed_payout_reminders,
)
from .models import ConsignmentPayoutReminder, StockUnit
from .tasks import consignment_unclaimed_reminders_task
from .test_consignment_api import ConsignmentApiTestCase


class ReminderTestCase(ConsignmentApiTestCase):
    def setUp(self):
        super().setUp()
        MessagingGateway.objects.create(
            name="gate",
            channel=MessagingGateway.Channel.SMS,
            provider=MessagingGateway.Provider.FAKE,
            is_active=True,
        )

    def _take_in(self, *codes):
        agreement = self._agreement()
        response = self.client.post(
            reverse("consignment-agreement-submit", args=[agreement["id"]]),
            {
                "items": [
                    {
                        "variant": self.variant.pk,
                        "code": code,
                        "declared_value": "12000.00",
                    }
                    for code in codes
                ]
            },
            format="json",
        )
        self.assertEqual(response.status_code, 200, response.data)
        return list(StockUnit.objects.filter(code__in=codes).order_by("code"))

    def _sell(self, unit, price="12000.00"):
        """One till for the whole test: selling twice must not open two."""
        from apps.sales.models import RegisterSession
        from apps.sales.services import checkout_order

        session = getattr(self, "_till", None)
        if session is None:
            session = self._till = RegisterSession.objects.create(
                owner=self.manager,
                owner_key=f"user:{self.manager.pk}",
                status=RegisterSession.Status.OPEN,
                opening_cash=Decimal("0.00"),
            )
        return checkout_order(
            register_session=session,
            lines_data=[
                {
                    "variant": self.variant,
                    "quantity": Decimal("1"),
                    "effective_unit_price": Decimal(price),
                    "stock_units": [unit.pk],
                }
            ],
            payments_data=[{"method": "cash", "amount": Decimal(price)}],
        )

    def _sold_days_ago(self, unit, days):
        self._sell(unit)
        StockUnit.objects.filter(pk=unit.pk).update(
            sold_at=timezone.now() - timedelta(days=days)
        )
        unit.refresh_from_db()
        return unit

    def _reminders(self):
        return OutboundMessage.objects.filter(source_type="consignment_unclaimed")


class CadenceTests(ReminderTestCase):
    def test_the_rounds_are_n_2n_3n_and_then_it_stops(self):
        self.assertEqual(due_round(29, 30), 0)
        self.assertEqual(due_round(30, 30), 1)
        self.assertEqual(due_round(61, 30), 2)
        self.assertEqual(due_round(95, 30), 3)
        self.assertEqual(due_round(400, 30), MAX_ROUNDS)
        self.assertEqual(due_round(400, 0), 0)

    def test_nothing_before_the_reminder_days(self):
        unit = self._take_in("W-1")[0]
        self._sold_days_ago(unit, 29)

        self.assertEqual(send_unclaimed_payout_reminders(), 0)
        self.assertFalse(self._reminders().exists())

    def test_one_reminder_per_round_however_often_the_sweep_runs(self):
        unit = self._take_in("W-1")[0]
        self._sold_days_ago(unit, 31)

        self.assertEqual(send_unclaimed_payout_reminders(), 1)
        self.assertEqual(send_unclaimed_payout_reminders(), 0)

        message = self._reminders().get()
        self.assertIn("سالم", message.body)
        self.assertIn("10000.00", message.body)
        self.assertIn("W-1", message.body)
        self.assertEqual(message.template_kind, "consignment_unclaimed")
        reminder = ConsignmentPayoutReminder.objects.get()
        self.assertEqual(
            (reminder.round, reminder.message_id, reminder.consignor_id),
            (1, message.pk, self.consignor.pk),
        )

    def test_a_missed_sweep_sends_the_round_reached_not_every_round_skipped(self):
        unit = self._take_in("W-1")[0]
        self._sold_days_ago(unit, 75)

        self.assertEqual(send_unclaimed_payout_reminders(), 1)

        self.assertEqual(self._reminders().count(), 1)
        self.assertEqual(ConsignmentPayoutReminder.objects.get().round, 2)

    def test_three_rounds_at_most(self):
        unit = self._take_in("W-1")[0]
        for days in (30, 60, 90, 120, 400):
            self._sold_days_ago_without_selling(unit, days)
            send_unclaimed_payout_reminders()

        self.assertEqual(self._reminders().count(), MAX_ROUNDS)
        self.assertEqual(
            sorted(ConsignmentPayoutReminder.objects.values_list("round", flat=True)),
            [1, 2, 3],
        )

    def _sold_days_ago_without_selling(self, unit, days):
        if unit.status != StockUnit.Status.SOLD:
            self._sell(unit)
        StockUnit.objects.filter(pk=unit.pk).update(
            sold_at=timezone.now() - timedelta(days=days)
        )
        unit.refresh_from_db()
        # The rows keep the sale they chase; moving the sale date in a test
        # moves the sale, so the earlier rows follow it.
        ConsignmentPayoutReminder.objects.filter(unit=unit).update(
            sold_at=unit.sold_at
        )

    def test_several_articles_due_together_share_one_text(self):
        first, second = self._take_in("W-1", "W-2")
        self._sold_days_ago(first, 40)
        self._sold_days_ago(second, 35)

        self.assertEqual(send_unclaimed_payout_reminders(), 1)

        message = self._reminders().get()
        self.assertIn("2 من أماناتكم", message.body)
        self.assertIn("20000.00", message.body)
        # Each article still has its own round on record.
        self.assertEqual(
            set(ConsignmentPayoutReminder.objects.values_list("unit_id", flat=True)),
            {first.pk, second.pk},
        )

    def test_a_paid_out_article_is_not_chased(self):
        from .consignment_service import disburse_payout
        from .test_consignment import _request_with, _session

        unit = self._take_in("W-1")[0]
        self._sold_days_ago(unit, 45)
        disburse_payout(units=[unit], request=_request_with(_session()))

        self.assertEqual(send_unclaimed_payout_reminders(), 0)

    def test_the_task_runs_the_sweep(self):
        unit = self._take_in("W-1")[0]
        self._sold_days_ago(unit, 31)

        self.assertEqual(consignment_unclaimed_reminders_task(), {"queued": 1})


class SwitchTests(ReminderTestCase):
    def test_zero_reminder_days_turns_it_off(self):
        settings = ShopSettings.load()
        settings.consignment_unclaimed_payout_reminder_days = 0
        settings.save(update_fields=["consignment_unclaimed_payout_reminder_days"])
        unit = self._take_in("W-1")[0]
        self._sold_days_ago(unit, 200)

        self.assertEqual(send_unclaimed_payout_reminders(), 0)

    def test_the_consignment_texts_switch_governs_it(self):
        settings = ShopSettings.load()
        settings.consignment_auto_sms_on_sale = False
        settings.save(update_fields=["consignment_auto_sms_on_sale"])
        unit = self._take_in("W-1")[0]
        self._sold_days_ago(unit, 45)

        self.assertEqual(send_unclaimed_payout_reminders(), 0)

    def test_the_cadence_follows_the_shop_s_days(self):
        settings = ShopSettings.load()
        settings.consignment_unclaimed_payout_reminder_days = 7
        settings.save(update_fields=["consignment_unclaimed_payout_reminder_days"])
        unit = self._take_in("W-1")[0]
        self._sold_days_ago(unit, 8)

        self.assertEqual(send_unclaimed_payout_reminders(), 1)

    def test_a_consignor_who_asked_not_to_be_contacted_is_not(self):
        self.consignor.do_not_contact = True
        self.consignor.save(update_fields=["do_not_contact"])
        unit = self._take_in("W-1")[0]
        self._sold_days_ago(unit, 45)

        self.assertEqual(send_unclaimed_payout_reminders(), 0)

    def test_no_balance_spends_no_round(self):
        unit = self._take_in("W-1")[0]
        self._sold_days_ago(unit, 45)

        with mock.patch(
            "apps.messaging.services.enqueue_message",
            side_effect=NoGatewayConfigured(code="insufficient_balance"),
        ):
            self.assertEqual(send_unclaimed_payout_reminders(), 0)

        self.assertFalse(ConsignmentPayoutReminder.objects.exists())
        # Tomorrow, with money on the balance, the round is still there to send.
        self.assertEqual(send_unclaimed_payout_reminders(), 1)

    def test_a_template_refusal_does_not_burn_the_round(self):
        unit = self._take_in("W-1")[0]
        self._sold_days_ago(unit, 45)
        send_unclaimed_payout_reminders()
        first = self._reminders().get()
        OutboundMessage.objects.filter(pk=first.pk).update(
            status=OutboundMessage.Status.FAILED,
            error_code="template_not_configured",
        )

        self.assertEqual(send_unclaimed_payout_reminders(), 1)

        reminder = ConsignmentPayoutReminder.objects.get()
        self.assertEqual(reminder.round, 1)
        self.assertNotEqual(reminder.message_id, first.pk)

    def test_any_other_failure_spends_it_and_shows(self):
        unit = self._take_in("W-1")[0]
        self._sold_days_ago(unit, 45)
        send_unclaimed_payout_reminders()
        OutboundMessage.objects.update(
            status=OutboundMessage.Status.FAILED, error_code="invalid_phone"
        )

        self.assertEqual(send_unclaimed_payout_reminders(), 0)


class TheMoneyStaysTheirsTests(ReminderTestCase):
    def test_reminding_never_turns_the_payout_into_the_shop_s_money(self):
        unit = self._take_in("W-1")[0]
        self._sold_days_ago(unit, 30)
        commission = figures.shop_consignment_commission()

        for days in (30, 60, 90, 365, 2000):
            sold_at = timezone.now() - timedelta(days=days)
            StockUnit.objects.filter(pk=unit.pk).update(sold_at=sold_at)
            ConsignmentPayoutReminder.objects.filter(unit=unit).update(
                sold_at=sold_at
            )
            send_unclaimed_payout_reminders()

        self.assertEqual(self._reminders().count(), MAX_ROUNDS)

        unit.refresh_from_db()
        self.assertEqual(unit.status, StockUnit.Status.SOLD)
        self.assertIsNone(unit.consignor_paid_at)
        self.assertEqual(figures.consignor_payable(), Decimal("10000.00"))
        self.assertEqual(figures.shop_consignment_commission(), commission)
