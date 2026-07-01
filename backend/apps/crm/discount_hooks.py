"""Auto-draft a marketing campaign when a discount is created.

Opt-in (``POINTY_SMS_AUTO_CAMPAIGN_ON_DISCOUNT``, default off) so a shop never
gets surprise drafts. The draft is linked to the rule, so its audience resolves
from the discount's own ``customers`` / ``customer_ranks`` at send time — and
like every campaign it just sits as a draft awaiting human approval.
"""

from __future__ import annotations

import logging

from django.conf import settings as django_settings

from .models import Campaign

logger = logging.getLogger(__name__)


def draft_campaign_for_discount(rule):
    """Create a draft campaign for ``rule`` (idempotent per rule)."""
    if Campaign.objects.filter(discount_rule=rule).exists():
        return None
    body = "عرض خاص من {{shop_name}}: " + (rule.name or "") + "! لا تفوّت الفرصة."
    return Campaign.objects.create(
        name=f"حملة: {rule.name}"[:120],
        body_template=body,
        status=Campaign.Status.DRAFT,
        discount_rule=rule,
        created_via=Campaign.CreatedVia.HUMAN,
    )


def on_discount_rule_saved(sender, instance, created, **kwargs):
    if not created:
        return
    if not getattr(django_settings, "POINTY_SMS_AUTO_CAMPAIGN_ON_DISCOUNT", False):
        return
    try:
        draft_campaign_for_discount(instance)
    except Exception:  # a draft failure must never break discount creation
        logger.exception("auto-campaign draft for discount %s failed", instance.pk)
