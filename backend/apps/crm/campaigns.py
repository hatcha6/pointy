"""Campaign lifecycle: audience resolution, preview, expansion, and the drip pump.

Expansion is where the ``can_send`` consent authority is finally consumed —
opted-out / do-not-contact customers are excluded up front, and the pump
re-checks at send time so a STOP received mid-drip is still honored. The actual
send pace is the gateway's rate limiter (messaging.dispatch_outbound); the pump
only enqueues.
"""

from __future__ import annotations

import logging

from django.db.models import Q
from django.utils import timezone

from apps.core.models import ShopSettings
from apps.customers.models import Customer
from apps.messaging.models import MessagingGateway, OutboundMessage
from apps.messaging.phone import normalize_phone
from apps.messaging.segments import count_segments
from apps.messaging.services import NoGatewayConfigured, enqueue_message

from .consent import can_send
from .models import Campaign, CampaignRecipient
from .templating import render_template

logger = logging.getLogger(__name__)

_MARKETING = OutboundMessage.ConsentClass.MARKETING


class InvalidCampaignState(Exception):
    """The campaign is not in a state that can be sent."""


def _shop_name() -> str:
    return (getattr(ShopSettings.load(), "shop_name", "") or "").strip()


def resolve_audience(campaign):
    """Active, phone-bearing customers matching the campaign's targeting.

    Unions RFM segments, the explicit customer set, and any discount rule's own
    targeting. No targeting at all = every active customer with a phone.
    """
    queryset = Customer.objects.filter(is_active=True).exclude(phone="")
    query = Q()
    has_filter = False
    if campaign.rfm_segments:
        query |= Q(rfm_segment__in=campaign.rfm_segments)
        has_filter = True
    explicit_ids = list(campaign.customers.values_list("id", flat=True))
    if explicit_ids:
        query |= Q(id__in=explicit_ids)
        has_filter = True
    if campaign.discount_rule_id:
        rule = campaign.discount_rule
        ranks = list(rule.customer_ranks or [])
        if ranks:
            query |= Q(rfm_segment__in=ranks)
            has_filter = True
        rule_ids = list(rule.customers.values_list("id", flat=True))
        if rule_ids:
            query |= Q(id__in=rule_ids)
            has_filter = True
    if has_filter:
        queryset = queryset.filter(query)
    return queryset.distinct()


def _estimate_minutes(count: int, gateway) -> int:
    rate = (gateway.max_messages_per_minute if gateway else 0) or 6
    if count <= 0:
        return 0
    return -(-count // rate)  # ceil


def preview_campaign(campaign) -> dict:
    """Audience size, a rendered sample, segment count, and drip duration — the
    numbers the approver sees before pulling the trigger. Creates no rows."""
    audience = resolve_audience(campaign)
    total = audience.count()
    sendable = audience.filter(
        marketing_opted_out_at__isnull=True, do_not_contact=False
    ).count()
    shop_name = _shop_name()
    sample_customer = audience.first()
    sample = render_template(
        campaign.body_template, sample_customer, shop_name=shop_name
    )
    return {
        "audience_total": total,
        "sendable_estimate": sendable,
        "skipped_estimate": max(total - sendable, 0),
        "sample_message": sample,
        "segments": count_segments(sample),
        "estimated_minutes": _estimate_minutes(sendable, campaign.gateway),
    }


def expand_campaign_recipients(campaign) -> None:
    """Freeze one CampaignRecipient per targeted customer with rendered copy +
    consent decision. Idempotent (update_or_create per customer)."""
    shop_name = _shop_name()
    total = 0
    skipped = 0
    for customer in resolve_audience(campaign).iterator():
        normalized = normalize_phone(customer.phone)
        allowed, _reason = can_send(customer, _MARKETING)
        if not allowed or not normalized:
            skipped += 1
            CampaignRecipient.objects.update_or_create(
                campaign=campaign,
                customer=customer,
                defaults={
                    "phone": normalized,
                    "rendered_body": "",
                    "segments": 1,
                    "status": CampaignRecipient.Status.SKIPPED_OPTOUT,
                },
            )
            continue
        body = render_template(campaign.body_template, customer, shop_name=shop_name)
        CampaignRecipient.objects.update_or_create(
            campaign=campaign,
            customer=customer,
            defaults={
                "phone": normalized,
                "rendered_body": body,
                "segments": count_segments(body),
                "status": CampaignRecipient.Status.PENDING,
            },
        )
        total += 1
    campaign.total_recipients = total
    campaign.skipped_optout_count = skipped
    campaign.save(
        update_fields=["total_recipients", "skipped_optout_count", "updated_at"]
    )


def approve_and_send(campaign, *, actor) -> Campaign:
    """Approve a draft/pending campaign and start sending (expand recipients)."""
    if campaign.status not in (
        Campaign.Status.DRAFT,
        Campaign.Status.PENDING_APPROVAL,
        Campaign.Status.APPROVED,
    ):
        raise InvalidCampaignState(campaign.status)
    campaign.approved_by = actor
    campaign.approved_at = timezone.now()
    campaign.status = Campaign.Status.SENDING
    campaign.save(
        update_fields=["approved_by", "approved_at", "status", "updated_at"]
    )
    expand_campaign_recipients(campaign)
    return campaign


def _apply_counters(campaign) -> None:
    recipients = campaign.recipients
    campaign.sent_count = recipients.filter(
        status__in=[
            CampaignRecipient.Status.QUEUED,
            CampaignRecipient.Status.SENT,
            CampaignRecipient.Status.DELIVERED,
        ]
    ).count()
    campaign.failed_count = recipients.filter(
        status=CampaignRecipient.Status.FAILED
    ).count()
    campaign.skipped_optout_count = recipients.filter(
        status=CampaignRecipient.Status.SKIPPED_OPTOUT
    ).count()


def pump_campaign(campaign, *, batch: int = 200) -> int:
    """Enqueue the next batch of pending recipients. Returns how many were
    queued. When none remain, the campaign is marked sent."""
    pending = list(
        campaign.recipients.filter(status=CampaignRecipient.Status.PENDING)
        .select_related("customer")[:batch]
    )
    if not pending:
        _apply_counters(campaign)
        campaign.status = Campaign.Status.SENT
        campaign.save(
            update_fields=[
                "status",
                "sent_count",
                "failed_count",
                "skipped_optout_count",
                "updated_at",
            ]
        )
        return 0

    gateway = campaign.gateway or MessagingGateway.default_gateway()
    queued = 0
    for recipient in pending:
        allowed, _reason = can_send(recipient.customer, _MARKETING)
        if not allowed:
            recipient.status = CampaignRecipient.Status.SKIPPED_OPTOUT
            recipient.save(update_fields=["status", "updated_at"])
            continue
        try:
            message = enqueue_message(
                to=recipient.phone,
                body=recipient.rendered_body,
                consent_class=_MARKETING,
                gateway=gateway,
                dedup_key=f"campaign:{recipient.id}",
                source_type="campaign",
                source_id=recipient.id,
            )
        except NoGatewayConfigured:
            return queued
        recipient.status = CampaignRecipient.Status.QUEUED
        recipient.outbound = message
        recipient.save(update_fields=["status", "outbound", "updated_at"])
        queued += 1

    _apply_counters(campaign)
    campaign.save(
        update_fields=[
            "sent_count",
            "failed_count",
            "skipped_optout_count",
            "updated_at",
        ]
    )
    return queued
