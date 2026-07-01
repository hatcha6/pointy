from __future__ import annotations

from decimal import Decimal

from django.test import TestCase, override_settings

from apps.discounts.models import DiscountRule
from apps.messaging.models import InboundMessage, MessagingGateway, OutboundMessage
from apps.messaging.transports import fake

from .discount_hooks import draft_campaign_for_discount
from .models import Campaign, Conversation, StaffCommandNumber
from .staff_commands import is_staff_number, parse_staff_command
from .tasks import route_inbound_task

_STAFF_PHONE = "+218911111111"


def make_gateway():
    return MessagingGateway.objects.create(
        name="phone", provider=MessagingGateway.Provider.FAKE, is_default=True
    )


def make_inbound(gateway, *, phone=_STAFF_PHONE, body="SALES", pid="m1"):
    return InboundMessage.objects.create(
        gateway=gateway,
        from_phone=phone,
        from_phone_raw=phone,
        body=body,
        provider_message_id=pid,
    )


class StaffCommandParseTests(TestCase):
    def test_keywords(self):
        self.assertEqual(parse_staff_command("SALES"), "sales")
        self.assertEqual(parse_staff_command("مبيعات اليوم"), "sales")
        self.assertEqual(parse_staff_command("DEBT"), "debt")
        self.assertEqual(parse_staff_command("مساعدة"), "help")
        self.assertIsNone(parse_staff_command("مرحبا كيف الحال"))

    def test_is_staff_number(self):
        StaffCommandNumber.objects.create(phone=_STAFF_PHONE, label="مدير")
        self.assertTrue(is_staff_number(_STAFF_PHONE))
        self.assertFalse(is_staff_number("+218912345678"))
        self.assertFalse(is_staff_number(""))


class StaffCommandRoutingTests(TestCase):
    def setUp(self):
        fake.reset()
        self.gateway = make_gateway()
        StaffCommandNumber.objects.create(phone=_STAFF_PHONE, label="مدير")

    def test_staff_command_replies_without_threading(self):
        result = route_inbound_task(make_inbound(self.gateway, body="SALES").id)
        self.assertEqual(result, "staff_command")
        self.assertTrue(
            OutboundMessage.objects.filter(
                source_type="staff_command",
                consent_class=OutboundMessage.ConsentClass.TRANSACTIONAL,
            ).exists()
        )
        self.assertEqual(Conversation.objects.count(), 0)

    def test_non_staff_number_threads(self):
        result = route_inbound_task(
            make_inbound(self.gateway, phone="+218912345678", body="SALES").id
        )
        self.assertEqual(result, "threaded")
        self.assertEqual(Conversation.objects.count(), 1)

    def test_staff_non_command_threads(self):
        result = route_inbound_task(make_inbound(self.gateway, body="مرحبا").id)
        self.assertEqual(result, "threaded")

    def test_consent_wins_over_staff_command(self):
        result = route_inbound_task(make_inbound(self.gateway, body="STOP").id)
        self.assertEqual(result, "consent")


class DiscountAutoCampaignTests(TestCase):
    def _make_rule(self):
        return DiscountRule.objects.create(
            name="خصم العيد", value=Decimal("10"), value_type="percentage"
        )

    def test_disabled_by_default_creates_no_campaign(self):
        self._make_rule()
        self.assertEqual(Campaign.objects.count(), 0)

    @override_settings(POINTY_SMS_AUTO_CAMPAIGN_ON_DISCOUNT=True)
    def test_enabled_drafts_a_campaign(self):
        rule = self._make_rule()
        campaign = Campaign.objects.get(discount_rule=rule)
        self.assertEqual(campaign.status, Campaign.Status.DRAFT)
        self.assertIn("خصم العيد", campaign.name)

    @override_settings(POINTY_SMS_AUTO_CAMPAIGN_ON_DISCOUNT=True)
    def test_idempotent_per_rule(self):
        rule = self._make_rule()
        draft_campaign_for_discount(rule)  # a second attempt must not duplicate
        self.assertEqual(Campaign.objects.filter(discount_rule=rule).count(), 1)
