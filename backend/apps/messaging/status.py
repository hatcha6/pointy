"""What the SMS settings page shows, assembled in one place.

The subscription decides whether a shop has SMS at all (the relay's verdict,
mirrored on ``RelayInstallation``); the shop's own gateway row decides whether it
is switched on and how fast it may go; the relay alone knows this month's usage
and which message kinds the company has an approved template for.
"""

from __future__ import annotations

import logging

from django.core.exceptions import ImproperlyConfigured

from apps.core.models import RelayInstallation
from apps.core.relay import RelayControlError, relay_sms_available, scoped_relay_client

from .models import MessagingGateway
from .serializers import MessagingGatewaySerializer
from .sms_templates import SMS_TEMPLATE_SPECS
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
    """SMS can be sent right now: in the subscription and not switched off.

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


def messaging_status() -> dict:
    installation = RelayInstallation.load()
    entitled = relay_sms_available(installation)
    gateway = _relay_gateway()

    usage = None
    usage_error = "" if entitled else "not_entitled"
    relay_test_mode = False
    configured_kinds = None
    if entitled:
        payload, usage_error = _relay_usage(installation)
        if payload is not None:
            if payload.get("configured") is False:
                usage_error = "not_configured"
            else:
                usage = {key: payload.get(key) for key in _USAGE_KEYS}
            relay_test_mode = bool(payload.get("test_mode"))
            kinds = payload.get("kinds")
            if isinstance(kinds, list):
                configured_kinds = {str(kind) for kind in kinds}

    return {
        "entitled": entitled,
        "available": entitled and gateway is not None and gateway.is_active,
        "test_mode": sms_test_mode() or relay_test_mode,
        "gateway": MessagingGatewaySerializer(gateway).data if gateway else None,
        "usage": usage,
        "usage_error": usage_error,
        "templates": [
            {
                "kind": spec.kind,
                "title": spec.title,
                "description": spec.description,
                "text": spec.text,
                "variables": list(spec.variables),
                "example": spec.example,
                "consent_class": spec.consent_class,
                "configured": (
                    None if configured_kinds is None else spec.kind in configured_kinds
                ),
            }
            for spec in SMS_TEMPLATE_SPECS
        ],
    }
