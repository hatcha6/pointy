from __future__ import annotations

import logging

from celery import shared_task
from django.conf import settings as django_settings

from apps.messaging.models import InboundMessage
from apps.messaging.services import NoGatewayConfigured

from .campaigns import pump_campaign
from .consent import handle_consent_command, parse_consent_command
from .models import Campaign
from .services import thread_inbound
from .staff_commands import (
    handle_staff_command,
    is_staff_number,
    parse_staff_command,
)
from .transactional import send_debt_reminder

logger = logging.getLogger(__name__)


@shared_task(
    name="crm.route_inbound",
    autoretry_for=(Exception,),
    retry_backoff=True,
    retry_kwargs={"max_retries": 3},
)
def route_inbound_task(inbound_id):
    """Route a stored inbound message.

    Consent commands (STOP/START) are handled first so they are never swallowed
    into a thread; everything else routes into a customer conversation. Staff
    commands are layered in ahead of threading in a later phase.
    """
    inbound = InboundMessage.objects.filter(pk=inbound_id).first()
    if inbound is None or inbound.handled:
        return "skip"

    action = parse_consent_command(inbound.body)
    if action is not None:
        handle_consent_command(inbound, action)
        inbound.handled = True
        inbound.handled_as = InboundMessage.HandledAs.CONSENT_COMMAND
        inbound.save(update_fields=["handled", "handled_as", "updated_at"])
        return "consent"

    if is_staff_number(inbound.from_phone):
        command = parse_staff_command(inbound.body)
        if command is not None:
            handle_staff_command(inbound, command)
            inbound.handled = True
            inbound.handled_as = InboundMessage.HandledAs.STAFF_COMMAND
            inbound.save(update_fields=["handled", "handled_as", "updated_at"])
            return "staff_command"

    thread_inbound(inbound)
    inbound.handled = True
    inbound.handled_as = InboundMessage.HandledAs.CONVERSATION
    inbound.save(update_fields=["handled", "handled_as", "updated_at"])
    return "threaded"


@shared_task(
    name="crm.debt_reminder_sweep",
    autoretry_for=(Exception,),
    retry_backoff=True,
)
def debt_reminder_sweep_task():
    """Queue a debt reminder for every open-credit order that is *due* and has a
    reachable customer. "Due" means the invoice's due date has arrived or passed,
    or it carries no due date at all (an open tab is due now); a future due date
    holds the reminder until that day. Off by default (opt-in via
    ``POINTY_SMS_DEBT_REMINDERS_ENABLED``) so a shop never sends surprise SMS.
    Honors do-not-contact and is idempotent per shop-local day.
    """
    if not getattr(django_settings, "POINTY_SMS_DEBT_REMINDERS_ENABLED", False):
        return {"skipped": "disabled"}

    from django.db.models import Q

    from apps.core.timeutils import business_local_date
    from apps.sales.models import Order

    today = business_local_date()
    orders = (
        Order.objects.open_credit()
        .select_related("customer")
        # Prefetch payments so each order's balance_due (which sums payments in
        # Python) doesn't fire its own query — avoids an N+1 across the sweep.
        .prefetch_related("payments")
        .filter(customer__isnull=False)
        # Only invoices that are actually due: due-on-or-before today, or with no
        # due date set (treated as due now). A future due date defers the nudge.
        .filter(Q(valid_until__isnull=True) | Q(valid_until__lte=today))
        .exclude(customer__phone="")
        .exclude(customer__do_not_contact=True)
    )
    sent = 0
    # chunk_size is required to combine iterator() with prefetch_related().
    for order in orders.iterator(chunk_size=500):
        try:
            if send_debt_reminder(order) is not None:
                sent += 1
        except NoGatewayConfigured:
            return {"sent": sent, "stopped": "no_gateway"}
        except Exception:
            logger.exception("debt reminder failed for order %s", order.id)
    return {"sent": sent}


@shared_task(
    name="crm.pump_sending_campaigns",
    autoretry_for=(Exception,),
    retry_backoff=True,
)
def pump_sending_campaigns_task():
    """Drain each sending campaign's pending recipients into the outbound queue;
    the gateway rate limiter paces the actual sends."""
    queued = 0
    for campaign in Campaign.objects.filter(status=Campaign.Status.SENDING):
        queued += pump_campaign(campaign)
    return {"queued": queued}


_MIN_SUGGESTION_COHORT = 5


@shared_task(
    name="crm.generate_ai_suggestions",
    autoretry_for=(Exception,),
    retry_backoff=True,
)
def generate_ai_suggestions_task():
    """Proactively draft a win-back campaign for a slipping cohort as an
    AI-tagged DRAFT awaiting human approval. Opt-in + AI-entitlement gated, and —
    like every AI path — it only ever drafts, never sends."""
    if not getattr(django_settings, "POINTY_SMS_AI_SUGGESTIONS_ENABLED", False):
        return {"skipped": "disabled"}

    from apps.core.models import RelayInstallation

    installation = RelayInstallation.load()
    if installation is None or not installation.ai_enabled:
        return {"skipped": "no_ai"}

    from apps.customers.models import Customer

    cohort = (
        Customer.objects.filter(
            is_active=True,
            rfm_segment__in=["at_risk", "hibernating"],
            marketing_opted_out_at__isnull=True,
            do_not_contact=False,
        )
        .exclude(phone="")
    )
    if cohort.count() < _MIN_SUGGESTION_COHORT:
        return {"created": 0}
    if Campaign.objects.filter(
        created_via=Campaign.CreatedVia.AI,
        status__in=[Campaign.Status.DRAFT, Campaign.Status.PENDING_APPROVAL],
    ).exists():
        return {"created": 0, "skipped": "existing_draft"}

    Campaign.objects.create(
        name="استرجاع العملاء المتعثّرين",
        body_template=(
            "نفتقدك يا {{first_name}}! لديك عرض خاص بانتظارك في {{shop_name}}. "
            "زُرنا قريبًا."
        ),
        status=Campaign.Status.DRAFT,
        created_via=Campaign.CreatedVia.AI,
        rfm_segments=["at_risk", "hibernating"],
    )
    return {"created": 1}
