"""Query-count regression tests for the CRM read endpoints.

Campaign and conversation payloads embed rows that each read a related
``OutboundMessage`` (``outbound_status``), and every campaign serializes its
hand-picked ``customers`` audience. Without prefetching, each of those costs one
query per row, so the cost of the page scaled with the audience/thread size —
exactly the thing a shop with a real customer list hits first. These tests pin
the counts flat: the assertions compare N against 2N, so a reintroduced N+1
fails on the slope rather than on a brittle absolute number.
"""

from __future__ import annotations

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.db import connection
from django.test import TestCase
from django.test.utils import CaptureQueriesContext
from rest_framework.test import APIClient

from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.customers.models import Customer
from apps.messaging.models import MessagingGateway, OutboundMessage

from .models import Campaign, CampaignRecipient, Conversation, ConversationMessage


class CrmQueryCountTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="mgr", password="x")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(self.manager)
        self.gateway = MessagingGateway.objects.create(
            name="phone", provider=MessagingGateway.Provider.FAKE, is_default=True
        )
        self._phone = 0

    def _next_phone(self) -> str:
        self._phone += 1
        return f"+21891{self._phone:07d}"

    def _outbound(self, phone: str) -> OutboundMessage:
        return OutboundMessage.objects.create(
            gateway=self.gateway, to_phone=phone, body="مرحبا"
        )

    def _campaign(self, recipients: int) -> Campaign:
        campaign = Campaign.objects.create(
            name=f"حملة {recipients}", body_template="مرحبا {{first_name}}"
        )
        for index in range(recipients):
            phone = self._next_phone()
            customer = Customer.objects.create(
                full_name=f"عميل {recipients}-{index}", phone=phone
            )
            CampaignRecipient.objects.create(
                campaign=campaign,
                customer=customer,
                phone=phone,
                outbound=self._outbound(phone),
            )
            campaign.customers.add(customer)
        return campaign

    def _conversation(self, messages: int) -> Conversation:
        phone = self._next_phone()
        customer = Customer.objects.create(full_name=f"محادثة {messages}", phone=phone)
        conversation = Conversation.objects.create(customer=customer, phone=phone)
        for _ in range(messages):
            ConversationMessage.objects.create(
                conversation=conversation,
                direction=ConversationMessage.Direction.OUT,
                body="مرحبا",
                outbound=self._outbound(phone),
            )
        return conversation

    def _query_count(self, url: str) -> int:
        # The first request warms permissions/content types; measure the second
        # or the numbers carry that one-off cost.
        first = self.client.get(url)
        self.assertEqual(first.status_code, 200, first.content[:400])
        with CaptureQueriesContext(connection) as captured:
            response = self.client.get(url)
        self.assertEqual(response.status_code, 200, response.content[:400])
        return len(captured)

    def test_campaign_detail_is_flat_in_recipients(self):
        small = self._campaign(5)
        large = self._campaign(25)
        small_count = self._query_count(f"/api/crm/campaigns/{small.pk}/")
        large_count = self._query_count(f"/api/crm/campaigns/{large.pk}/")
        self.assertEqual(
            small_count,
            large_count,
            f"campaign-detail scales with recipients: {small_count} at 5, "
            f"{large_count} at 25",
        )
        payload = self.client.get(f"/api/crm/campaigns/{large.pk}/").json()
        self.assertEqual(len(payload["recipients"]), 25)
        self.assertTrue(all(row["outbound_status"] for row in payload["recipients"]))

    def test_campaign_list_is_flat_in_campaigns(self):
        for _ in range(2):
            self._campaign(3)
        small_count = self._query_count("/api/crm/campaigns/")
        for _ in range(2):
            self._campaign(3)
        large_count = self._query_count("/api/crm/campaigns/")
        self.assertEqual(
            small_count,
            large_count,
            f"campaign-list scales with rows: {small_count} at 2, "
            f"{large_count} at 4",
        )

    def test_conversation_detail_is_flat_in_messages(self):
        small = self._conversation(5)
        large = self._conversation(25)
        small_count = self._query_count(f"/api/crm/conversations/{small.pk}/")
        large_count = self._query_count(f"/api/crm/conversations/{large.pk}/")
        self.assertEqual(
            small_count,
            large_count,
            f"conversation-detail scales with messages: {small_count} at 5, "
            f"{large_count} at 25",
        )
        payload = self.client.get(f"/api/crm/conversations/{large.pk}/").json()
        self.assertEqual(len(payload["messages"]), 25)
        self.assertTrue(all(row["outbound_status"] for row in payload["messages"]))
