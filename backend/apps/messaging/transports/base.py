"""Transport-driver abstraction — the backend analog of Flutter's PrintTransport.

The outbound pipeline only ever touches ``MessagingTransport``; it never knows
which provider is behind a gateway. Adding a provider (Twilio, a relay proxy,
WhatsApp, …) is a new subclass registered with ``@register("name")`` — no
pipeline, model, or Celery change.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class SendResult:
    """Outcome of a single send attempt, mapped onto ``OutboundMessage``."""

    ok: bool
    provider_message_id: str = ""  # correlate async delivery receipts
    status: str = ""               # informational; the pipeline decides final status
    error_code: str = ""           # machine: "unauthorized" | "unreachable" | ...
    error_detail: str = ""         # human, for the message log
    retryable: bool = True         # False => permanent (bad number); do not retry


class UnknownProvider(Exception):
    """Raised when a gateway names a provider with no registered driver."""


class MessagingTransport:
    """One instance per gateway. Subclasses implement ``send`` (+ inbound hooks)."""

    channel = "sms"

    def __init__(self, gateway):
        self.gateway = gateway

    def send(self, *, to: str, body: str, message=None) -> SendResult:
        raise NotImplementedError

    # --- inbound hooks (wired from Phase 2) --------------------------------
    def verify_inbound(self, request) -> bool:
        """Authenticate a webhook hit as genuinely from THIS gateway's device."""
        return False

    def parse_inbound(self, request) -> dict:
        """Return ``{from, body, provider_message_id, sent_at}`` from a webhook."""
        return {}

    def parse_receipt(self, request) -> list[dict]:
        """Return ``[{provider_message_id, status}, ...]`` from a receipt webhook."""
        return []


_REGISTRY: dict[str, type[MessagingTransport]] = {}


def register(provider: str):
    def _decorator(cls):
        _REGISTRY[provider] = cls
        return cls

    return _decorator


def transport_for(gateway) -> MessagingTransport:
    cls = _REGISTRY.get(gateway.provider)
    if cls is None:
        raise UnknownProvider(gateway.provider)
    return cls(gateway)


def registered_providers() -> list[str]:
    return sorted(_REGISTRY)
