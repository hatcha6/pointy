"""Transport-driver abstraction — the backend analog of Flutter's PrintTransport.

The outbound pipeline only ever touches ``MessagingTransport``; it never knows
which provider is behind a gateway. Adding a provider (WhatsApp, a second SMS
company, …) is a new subclass registered with ``@register("name")`` — no
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
    # The text the provider actually sent, when it reports one. A template the
    # provider approved with different wording than ours would otherwise leave
    # the log showing a message nobody received.
    sent_body: str = ""
    # Not the message's fault — the provider is out of reach or asked us to slow
    # down. The message waits and tries again without spending an attempt, so an
    # afternoon without internet does not fail every invoice SMS of the day.
    defer: bool = False
    retry_after_seconds: int = 0


class UnknownProvider(Exception):
    """Raised when a gateway names a provider with no registered driver."""


class MessagingTransport:
    """One instance per gateway. Subclasses implement ``send`` (+ inbound hooks)."""

    channel = "sms"
    # A provider that only delivers pre-approved templates (Resala via the
    # relay) cannot send a message that has no template kind.
    requires_template = False

    def __init__(self, gateway):
        self.gateway = gateway

    def unavailable_reason(self) -> str:
        """Why nothing can be sent through this gateway right now, or ``""``.

        Checked before a message is queued, so a shop whose plan has no SMS gets
        a clear answer at the button instead of a queue of doomed messages.
        """
        return ""

    def send(self, *, to: str, body: str, message=None) -> SendResult:
        raise NotImplementedError

    def delivery_statuses(self, messages) -> dict:
        """Poll the provider for sent messages' fates: ``{message.pk: status}``.

        For a provider that reports delivery only when asked (the relay) rather
        than by calling us back. Statuses use the receipt vocabulary
        (``delivered`` / ``undelivered`` / ``sent``); a message the provider
        says nothing new about is simply left out.
        """
        return {}

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
