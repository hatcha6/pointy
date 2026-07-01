from __future__ import annotations

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.customers.models import Customer
from apps.messaging.models import MessagingGateway, OutboundMessage
from apps.messaging.transports import fake

from .campaigns import (
    approve_and_send,
    expand_campaign_recipients,
    pump_campaign,
    resolve_audience,
)
from .models import Campaign, CampaignRecipient
from .templating import render_template

_CHAMPION = Customer.Rank.CHAMPION


def make_gateway():
    return MessagingGateway.objects.create(
        name="phone", provider=MessagingGateway.Provider.FAKE, is_default=True
    )


def make_campaign(**kwargs):
    defaults = dict(name="عرض", body_template="مرحبا {{first_name}} من {{shop_name}}")
    defaults.update(kwargs)
    return Campaign.objects.create(**defaults)


def champion(name, phone, **kwargs):
    return Customer.objects.create(
        full_name=name, phone=phone, rfm_segment=_CHAMPION, **kwargs
    )


class TemplatingTests(TestCase):
    def test_substitutes_known_leaves_unknown(self):
        customer = Customer(full_name="علي محمد")
        out = render_template(
            "مرحبا {{first_name}} {{unknown}}", customer, shop_name="متجري"
        )
        self.assertIn("علي", out)
        self.assertIn("{{unknown}}", out)


class AudienceTests(TestCase):
    def test_rfm_filter_excludes_others_and_no_phone(self):
        champ = champion("A", "+218912345670")
        loyal = Customer.objects.create(
            full_name="B", phone="+218912345671", rfm_segment=Customer.Rank.LOYAL
        )
        no_phone = champion("C", "")
        campaign = make_campaign(rfm_segments=["champion"])
        audience = list(resolve_audience(campaign))
        self.assertIn(champ, audience)
        self.assertNotIn(loyal, audience)
        self.assertNotIn(no_phone, audience)


class ExpansionTests(TestCase):
    def setUp(self):
        fake.reset()
        self.gateway = make_gateway()

    def test_expansion_honors_consent_and_freezes_copy(self):
        sendable = champion("علي", "+218912345670")
        opted_out = champion("B", "+218912345671", marketing_opted_out_at=timezone.now())
        do_not_contact = champion("C", "+218912345672", do_not_contact=True)
        campaign = make_campaign(rfm_segments=["champion"])

        expand_campaign_recipients(campaign)
        campaign.refresh_from_db()
        self.assertEqual(campaign.total_recipients, 1)
        self.assertEqual(campaign.skipped_optout_count, 2)

        recipient = CampaignRecipient.objects.get(customer=sendable)
        self.assertEqual(recipient.status, CampaignRecipient.Status.PENDING)
        self.assertIn("علي", recipient.rendered_body)
        self.assertGreaterEqual(recipient.segments, 1)
        self.assertEqual(
            CampaignRecipient.objects.get(customer=opted_out).status,
            CampaignRecipient.Status.SKIPPED_OPTOUT,
        )
        self.assertEqual(
            CampaignRecipient.objects.get(customer=do_not_contact).status,
            CampaignRecipient.Status.SKIPPED_OPTOUT,
        )


class PumpTests(TestCase):
    def setUp(self):
        fake.reset()
        self.gateway = make_gateway()

    def test_pump_enqueues_marketing_and_finalizes(self):
        for i in range(3):
            champion(f"C{i}", f"+21891234567{i}")
        campaign = make_campaign(rfm_segments=["champion"])
        approve_and_send(campaign, actor=None)
        campaign.refresh_from_db()
        self.assertEqual(campaign.status, Campaign.Status.SENDING)

        self.assertEqual(pump_campaign(campaign), 3)
        self.assertEqual(
            OutboundMessage.objects.filter(
                source_type="campaign", consent_class=OutboundMessage.ConsentClass.MARKETING
            ).count(),
            3,
        )
        pump_campaign(campaign)  # nothing left → finalize
        campaign.refresh_from_db()
        self.assertEqual(campaign.status, Campaign.Status.SENT)
        self.assertEqual(campaign.sent_count, 3)

    def test_pump_rechecks_consent_mid_drip(self):
        customer = champion("A", "+218912345670")
        campaign = make_campaign(rfm_segments=["champion"])
        approve_and_send(campaign, actor=None)
        # The customer texts STOP after expansion but before the pump reaches them.
        customer.marketing_opted_out_at = timezone.now()
        customer.save()

        pump_campaign(campaign)
        self.assertEqual(
            CampaignRecipient.objects.get(customer=customer).status,
            CampaignRecipient.Status.SKIPPED_OPTOUT,
        )
        self.assertEqual(OutboundMessage.objects.filter(source_type="campaign").count(), 0)


class CampaignApiTests(TestCase):
    def setUp(self):
        fake.reset()
        self.gateway = make_gateway()
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="mgr", password="x")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.cashier = User.objects.create_user(username="csh", password="x")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        champion("A", "+218912345670")
        self.client = APIClient()

    def test_create_is_always_draft_even_if_status_supplied(self):
        self.client.force_authenticate(self.manager)
        resp = self.client.post(
            "/api/crm/campaigns/",
            {
                "name": "عرض العيد",
                "body_template": "مرحبا",
                "rfm_segments": ["champion"],
                "status": "sending",  # must be ignored
            },
            format="json",
        )
        self.assertEqual(resp.status_code, 201, resp.content)
        self.assertEqual(resp.data["status"], "draft")
        self.assertEqual(resp.data["created_via"], "human")

    def test_cashier_cannot_manage_campaigns(self):
        self.client.force_authenticate(self.cashier)
        self.assertEqual(self.client.get("/api/crm/campaigns/").status_code, 403)

    def test_manager_preview_and_send(self):
        self.client.force_authenticate(self.manager)
        created = self.client.post(
            "/api/crm/campaigns/",
            {
                "name": "عرض",
                "body_template": "مرحبا {{first_name}}",
                "rfm_segments": ["champion"],
            },
            format="json",
        )
        campaign_id = created.data["id"]

        preview = self.client.post(f"/api/crm/campaigns/{campaign_id}/preview/")
        self.assertEqual(preview.status_code, 200)
        self.assertGreaterEqual(preview.data["audience_total"], 1)
        self.assertIn("segments", preview.data)

        send = self.client.post(f"/api/crm/campaigns/{campaign_id}/send/")
        self.assertEqual(send.status_code, 200, send.content)
        self.assertEqual(send.data["status"], "sending")
        self.assertEqual(
            CampaignRecipient.objects.filter(campaign_id=campaign_id).count(), 1
        )

    def test_cashier_cannot_send(self):
        campaign = make_campaign(rfm_segments=["champion"])
        self.client.force_authenticate(self.cashier)
        self.assertEqual(
            self.client.post(f"/api/crm/campaigns/{campaign.id}/send/").status_code,
            403,
        )
