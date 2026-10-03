"""Driver that sends SMS through the company relay, with Resala behind it.

The shop holds no SMS credentials at all. The relay owns the Resala account and
the approved template ids; this driver hands it a template kind, the values for
its slots and the installation's own access token, and the relay decides —
the shop's SMS balance (each message is paid from it, per SMS part it goes out
as), template, number — before anything is sent. That single chokepoint is also where the company sees
which shop sends what.

Resala only delivers approved templates, so a message without a template kind is
refused here rather than sent as free text.
"""

from __future__ import annotations

import json
import logging

from django.conf import settings
from django.core.exceptions import ImproperlyConfigured

from apps.core.models import RelayInstallation
from apps.core.relay import (
    RelayControlError,
    mirror_sms_wallet,
    relay_sms_available,
    relay_transport_cooldown_active,
    scoped_relay_client,
    sms_affordable,
    sms_prepaid,
)

from .base import UNCERTAIN_FAILURE_CODES, MessagingTransport, SendResult, register

logger = logging.getLogger(__name__)

# How long a message waits when the relay is out of reach or asked us to slow
# down. The dispatcher polls every few seconds; these keep a dead uplink from
# being hammered while the queue waits for it.
_UNREACHABLE_RETRY_SECONDS = 300
_BUSY_RETRY_SECONDS = 60
_STATUS_BATCH = 100

# Relay answers that mean "try again later", with how long to wait. An
# ``internal_error`` is the relay's own database failing before anything was
# sent — and the idempotency key makes even a mistaken retry harmless.
_DEFERRED_CODES = {
    "rate_limited": _BUSY_RETRY_SECONDS,
    "in_flight": _BUSY_RETRY_SECONDS,
    "internal_error": _BUSY_RETRY_SECONDS,
}
# The relay's own vocabulary for a key it no longer recognises as a kind.
_CODE_ALIASES = {"unknown_kind": "template_not_configured", "unauthorized": "not_entitled"}


def sms_test_mode() -> bool:
    """Ask the relay not to really send (Resala's test mode).

    On by default on a development machine, whose database is often a copy of a
    real shop's — a debt-reminder sweep there must not text real customers.
    """
    return bool(getattr(settings, "POINTY_SMS_TEST_MODE", False))


def _error_payload(exc: RelayControlError) -> dict:
    try:
        payload = json.loads(exc.body or "")
    except (TypeError, ValueError):
        return {}
    return payload if isinstance(payload, dict) else {}


def _failure(
    code: str, detail: str, *, retryable: bool = False, provider_message_id: str = ""
) -> SendResult:
    return SendResult(
        ok=False,
        status="failed",
        error_code=code,
        error_detail=(detail or code)[:500],
        retryable=retryable,
        provider_message_id=provider_message_id,
    )


def _deferred(code: str, detail: str, seconds: int) -> SendResult:
    return SendResult(
        ok=False,
        status="queued",
        error_code=code,
        error_detail=(detail or code)[:500],
        retryable=True,
        defer=True,
        retry_after_seconds=seconds,
    )


def result_for_relay_error(exc: RelayControlError) -> SendResult:
    """Map a refused or failed relay call onto the message's fate."""
    status = exc.status_code
    payload = _error_payload(exc)
    code = str(payload.get("code") or "").strip()
    detail = str(payload.get("detail") or payload.get("error") or exc)

    if status is None:
        # Never reached the relay: nothing was sent, so waiting costs nothing.
        return _deferred("relay_unreachable", str(exc), _UNREACHABLE_RETRY_SECONDS)
    if code in _DEFERRED_CODES:
        return _deferred(code, detail, _DEFERRED_CODES[code])
    if not code:
        if status in (502, 503, 504):
            # A load balancer in front of a relay that is down or restarting.
            return _deferred("relay_unreachable", detail, _UNREACHABLE_RETRY_SECONDS)
        if status in (401, 402, 403):
            code = "not_entitled"
        else:
            code = "relay_error"
    # Everything else is an answer, not an outage: no entitlement, allowance
    # spent, a template the company never registered, a number Resala cannot
    # reach, a provider failure whose outcome is unknown. Retrying any of them
    # either fails again or risks texting the customer twice.
    code = _CODE_ALIASES.get(code, code)
    relay_id = str(payload.get("id") or "") if code in UNCERTAIN_FAILURE_CODES else ""
    return _failure(code, detail, provider_message_id=relay_id)


def _reported_parts(payload: dict) -> int:
    """The SMS parts the relay charged the message for; 0 when an older relay
    does not say, which leaves the count to ``count_segments``."""
    try:
        parts = int(payload.get("parts") or 0)
    except (TypeError, ValueError):
        return 0
    return parts if 0 < parts < 1000 else 0


def _note_sms_balance(payload: dict, installation) -> None:
    """Mirror the SMS balance a relay answer reported. Best-effort: the send's
    own outcome is what matters here, and the periodic sync catches up."""
    if not isinstance(payload, dict) or payload.get("balance") in (None, ""):
        return
    sms = {"balance": payload.get("balance")}
    if payload.get("price") not in (None, ""):
        sms["price"] = payload.get("price")
    try:
        mirror_sms_wallet(sms, installation=installation)
    except Exception:  # noqa: BLE001 - see the docstring
        logger.exception("mirroring the SMS balance after a send failed")


@register("relay")
class RelaySmsDriver(MessagingTransport):
    requires_template = True

    def unavailable_reason(self) -> str:
        installation = RelayInstallation.load()
        if relay_sms_available(installation):
            return ""
        # SMS is prepaid by the message: an empty SMS balance is something the
        # owner fixes from the wallet, not a plan to ask support for.
        return "insufficient_balance" if sms_prepaid(installation) else "not_entitled"

    def unaffordable_reason(self, segments: int) -> str:
        if sms_affordable(RelayInstallation.load(), segments):
            return ""
        return "insufficient_balance"

    def _timeout(self) -> int:
        return self.gateway.send_timeout_seconds or 20

    def send(self, *, to, body, message=None):
        if message is None or not message.template_kind:
            return _failure(
                "template_required",
                "the SMS provider only delivers approved templates",
            )
        installation = RelayInstallation.load()
        if installation is None or not installation.access_token:
            return _failure("not_entitled", "this backend is not enrolled with the relay")
        if relay_transport_cooldown_active():
            # A relay call failed at the transport level moments ago; answer at
            # once instead of spending the timeout on every queued message.
            return _deferred(
                "relay_unreachable",
                "relay recently unreachable",
                _UNREACHABLE_RETRY_SECONDS,
            )
        try:
            client = scoped_relay_client(installation)
            payload = client.send_sms(
                access_token=installation.access_token,
                kind=message.template_kind,
                to=to,
                variables=list(message.template_values or []),
                idempotency_key=message.relay_idempotency_key,
                consent_class=message.consent_class,
                test=sms_test_mode(),
                timeout=self._timeout(),
            )
        except ImproperlyConfigured as exc:
            logger.warning("relay SMS is not configured on this backend: %s", exc)
            return _failure("relay_unconfigured", str(exc))
        except RelayControlError as exc:
            result = result_for_relay_error(exc)
            if result.error_code == "insufficient_balance":
                # The money ran out: say so to every device now, not at the
                # next sync, so nobody queues more messages that cannot go.
                _note_sms_balance(_error_payload(exc), installation)
            return result

        _note_sms_balance(payload, installation)
        status = str(payload.get("status") or "sent")
        if status == "failed":
            return _failure(
                str(payload.get("code") or "provider_rejected"),
                str(payload.get("detail") or payload.get("error") or ""),
            )
        return SendResult(
            ok=True,
            status="sent",
            provider_message_id=str(payload.get("id") or ""),
            sent_body=str(payload.get("content") or ""),
            segments=_reported_parts(payload),
        )

    def delivery_statuses(self, messages) -> dict:
        by_relay_id = {
            message.provider_message_id: message.pk
            for message in messages
            if message.provider_message_id
        }
        if not by_relay_id:
            return {}
        installation = RelayInstallation.load()
        if installation is None or not installation.access_token:
            return {}
        try:
            client = scoped_relay_client(installation)
        except ImproperlyConfigured:
            return {}
        statuses = {}
        relay_ids = list(by_relay_id)
        for start in range(0, len(relay_ids), _STATUS_BATCH):
            batch = relay_ids[start : start + _STATUS_BATCH]
            try:
                payload = client.get_sms_statuses(
                    access_token=installation.access_token, ids=batch
                )
            except RelayControlError as exc:
                logger.info("relay SMS status poll failed: %s", exc)
                break
            for row in payload.get("messages") or []:
                if not isinstance(row, dict):
                    continue
                pk = by_relay_id.get(str(row.get("id") or ""))
                status = str(row.get("status") or "").strip().lower()
                # "sent" matters for a send that failed in doubt: the relay
                # found it in Resala's sent log after all.
                if pk is not None and status in {"sent", "delivered", "undelivered", "failed"}:
                    statuses[pk] = status
        return statuses
