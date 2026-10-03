"""What the SMS settings page shows, assembled in one place.

SMS is prepaid by the message: the shop's SMS balance on the relay decides
whether it can send at all (mirrored on ``RelayInstallation``); the shop's own
gateway row decides whether it is switched on and how fast it may go; the relay
alone knows the balance right now, this month's sends and which message kinds
the company has an approved template for.
"""

from __future__ import annotations

import logging

from django.core.exceptions import ImproperlyConfigured

from apps.core.models import RelayInstallation
from apps.core.relay import (
    RelayControlError,
    mirror_sms_wallet,
    relay_sms_available,
    scoped_relay_client,
    sms_prepaid,
)

from .approvals import note_approved_kinds
from .automation import auto_message_states
from .models import MessagingGateway
from .segments import count_segments
from .serializers import MessagingGatewaySerializer
from .sms_templates import SMS_TEMPLATE_GROUPS, SMS_TEMPLATE_SPECS
from .transports.relay import sms_test_mode

logger = logging.getLogger(__name__)

_USAGE_KEYS = ("used", "limit", "remaining", "period_start", "resets_at")


def _relay_gateway() -> MessagingGateway | None:
    # Shown even when switched off: the page is where the shop switches it back on.
    return (
        MessagingGateway.objects.filter(provider=MessagingGateway.Provider.RELAY)
        .order_by("created_at")
        .first()
    ) or MessagingGateway.ensure_relay_gateway()


def sms_available() -> bool:
    """SMS can be sent right now: the SMS balance pays for a message and the
    shop has not switched it off.

    Delivered with the session (``sms_available``) so the app shows SMS actions
    only where they can work — like ``ai_available``.
    """
    if not relay_sms_available():
        return False
    gateway = (
        MessagingGateway.objects.filter(provider=MessagingGateway.Provider.RELAY)
        .order_by("created_at")
        .first()
    )
    return gateway is None or gateway.is_active


def _relay_usage(installation) -> tuple[dict | None, str]:
    """This month's usage from the relay, or why it could not be read."""
    try:
        client = scoped_relay_client(installation)
        payload = client.get_sms_usage(access_token=installation.access_token)
    except ImproperlyConfigured as exc:
        logger.warning("relay SMS usage unavailable: %s", exc)
        return None, "not_configured"
    except RelayControlError as exc:
        if exc.status_code in (401, 402, 403):
            return None, "not_entitled"
        return None, "relay_unreachable"
    return payload if isinstance(payload, dict) else {}, ""


def _sms_wallet(installation) -> dict | None:
    """The SMS balance as the shop's copy of it stands, or None when the relay
    has not reported one (a relay from before the SMS balance)."""
    if not sms_prepaid(installation):
        return None
    price = installation.sms_price
    balance = installation.sms_balance
    return {
        "balance": f"{balance:.3f}",
        "price": f"{price:.3f}",
        "messages_left": max(int(balance // price), 0),
    }


def messaging_status() -> dict:
    installation = RelayInstallation.load()
    gateway = _relay_gateway()

    usage = None
    usage_error = "not_entitled"
    relay_test_mode = False
    configured_kinds = None
    if installation is not None and installation.access_token:
        # Asked even when SMS cannot be sent: the page shows an empty balance
        # and how to fill it, and the relay answers on identity alone.
        payload, usage_error = _relay_usage(installation)
        if payload is not None:
            if payload.get("price") not in (None, ""):
                mirror_sms_wallet(payload, installation=installation)
            if payload.get("configured") is False:
                usage_error = "not_configured"
            else:
                usage = {key: payload.get(key) for key in _USAGE_KEYS}
            relay_test_mode = bool(payload.get("test_mode"))
            kinds = payload.get("kinds")
            if isinstance(kinds, list):
                configured_kinds = {str(kind) for kind in kinds}
                note_approved_kinds(configured_kinds)
    entitled = relay_sms_available(installation)
    if usage_error == "not_entitled" and installation is not None and sms_prepaid(installation):
        # A prepaid shop is never "not entitled": its balance is just empty.
        usage_error = ""
    automatic = auto_message_states(gateway)
    part_price = installation.sms_price if sms_prepaid(installation) else None

    return {
        "entitled": entitled,
        "available": entitled and gateway is not None and gateway.is_active,
        "test_mode": sms_test_mode() or relay_test_mode,
        "gateway": MessagingGatewaySerializer(gateway).data if gateway else None,
        "sms_wallet": _sms_wallet(installation),
        "usage": usage,
        "usage_error": usage_error,
        "template_groups": [{"key": key, "title": title} for key, title in SMS_TEMPLATE_GROUPS],
        "templates": [_template_info(spec, configured_kinds, automatic, part_price) for spec in SMS_TEMPLATE_SPECS],
    }


def _template_info(spec, configured_kinds, automatic, part_price) -> dict:
    """One template as the settings page lists it: what it says, an example
    with what that example costs (SMS are paid per part), and — for a text
    that goes out by itself — whether its switch is on."""
    parts = count_segments(spec.example)
    return {
        "kind": spec.kind,
        "title": spec.title,
        "description": spec.description,
        "text": spec.text,
        "variables": list(spec.variables),
        "example": spec.example,
        "example_parts": parts,
        "example_price": None if part_price is None else f"{part_price * parts:.3f}",
        "consent_class": spec.consent_class,
        "group": spec.group,
        "automatic": spec.automatic,
        "auto_enabled": automatic.get(spec.kind) if spec.automatic else None,
        "auto_label": spec.auto_label,
        "configured": None if configured_kinds is None else spec.kind in configured_kinds,
    }
