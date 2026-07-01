from __future__ import annotations

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase

from apps.ai.tool_registry import WRITE_DENY_RESOURCES
from apps.ai.tools import draft_campaign, execute_tool
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.customers.models import Customer

from .models import Campaign


class AiDraftCampaignTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="mgr", password="x")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.cashier = User.objects.create_user(username="csh", password="x")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        Customer.objects.create(
            full_name="علي",
            phone="+218912345670",
            rfm_segment=Customer.Rank.CHAMPION,
        )

    def test_manager_drafts_campaign_tagged_ai_with_preview(self):
        result = draft_campaign(
            user=self.manager,
            name="عرض العيد",
            body_template="مرحبا {{first_name}}",
            rfm_segments=["champion"],
        )
        self.assertTrue(result.get("ok"), result)
        campaign = Campaign.objects.get()
        self.assertEqual(campaign.status, Campaign.Status.DRAFT)
        self.assertEqual(campaign.created_via, Campaign.CreatedVia.AI)
        self.assertIsNotNone(result.get("preview"))

    def test_missing_permission_is_denied(self):
        result = draft_campaign(
            user=self.cashier, name="عرض", body_template="مرحبا"
        )
        self.assertFalse(result.get("ok"))
        self.assertEqual(Campaign.objects.count(), 0)

    def test_generic_create_cannot_bypass_to_sending(self):
        # Even supplying status=sending, the AI's generic writer yields a draft.
        result = execute_tool(
            "create_resource",
            {
                "resource": "crm/campaigns",
                "data": {
                    "name": "x",
                    "body_template": "y",
                    "status": "sending",
                },
            },
            user=self.manager,
        )
        self.assertTrue(result.get("ok"), result)
        self.assertEqual(Campaign.objects.get().status, Campaign.Status.DRAFT)

    def test_no_send_tool_exists(self):
        result = execute_tool("send_campaign", {}, user=self.manager)
        self.assertFalse(result.get("ok"))
        self.assertEqual(result.get("error"), "unknown_tool")

    def test_sensitive_crm_resources_are_write_denied(self):
        self.assertIn("outbound-messages", WRITE_DENY_RESOURCES)
        self.assertIn("campaign-recipients", WRITE_DENY_RESOURCES)
        self.assertIn("consent-events", WRITE_DENY_RESOURCES)
