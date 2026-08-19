"""Driver for the open-source SMS Gate app (sms-gate.app) in local-server mode.

An old Android phone on the shop LAN runs the app's HTTP server; we POST a
message to it with HTTP Basic auth. Delivery state arrives asynchronously via a
webhook (``sms:delivered`` / ``sms:failed``), so a successful send POST maps to
``sent``, not ``delivered``.

Payloads and signing follow the SMS Gate webhook spec: inbound is ``sms:received``
with ``payload.sender`` / ``payload.message`` / ``payload.messageId``; delivery
reports carry the state in the ``event``; and webhooks are signed
``HMAC-SHA256(key, raw_body + X-Timestamp)`` in the ``X-Signature`` header.
"""

from __future__ import annotations

import hashlib
import hmac

import requests

from apps.core.credentials import constant_time_secret_equal

from .base import MessagingTransport, SendResult, register

# event -> which of our webhooks it targets (inbound thread vs delivery receipt).
_WEBHOOK_EVENTS = {
    "sms:received": "inbound",
    "sms:sent": "receipt",
    "sms:delivered": "receipt",
    "sms:failed": "receipt",
}

# Map a delivery-report event to an OutboundMessage-facing status.
_EVENT_STATUS = {
    "sms:sent": "sent",
    "sms:delivered": "delivered",
    "sms:failed": "failed",
}


@register("sms_gate")
class SmsGateDriver(MessagingTransport):
    def _base_url(self) -> str:
        return str(self.gateway.config.get("base_url", "")).rstrip("/")

    def _auth(self):
        return (
            str(self.gateway.config.get("username", "")),
            self.gateway.get_secret("password"),
        )

    def _timeout(self):
        return self.gateway.send_timeout_seconds or 15

    def send(self, *, to, body, message=None):
        base = self._base_url()
        if not base:
            return SendResult(
                ok=False, status="failed", error_code="not_configured",
                error_detail="gateway base_url is empty", retryable=False,
            )
        # Send path is configurable (the API moved /message -> /messages across
        # versions); default matches current SMS Gate.
        path = str(self.gateway.config.get("send_path", "messages")).strip("/")
        try:
            resp = requests.post(
                f"{base}/{path}",
                json={"message": body, "phoneNumbers": [to]},
                auth=self._auth(),
                timeout=self._timeout(),
            )
        except requests.RequestException as exc:
            return SendResult(
                ok=False, status="failed", error_code="unreachable",
                error_detail=str(exc)[:500], retryable=True,
            )
        if resp.status_code in (401, 403):
            return SendResult(
                ok=False, status="failed", error_code="unauthorized",
                error_detail=resp.text[:500], retryable=False,
            )
        if resp.status_code >= 400:
            return SendResult(
                ok=False, status="failed", error_code="gateway_error",
                error_detail=resp.text[:500], retryable=resp.status_code >= 500,
            )
        provider_id = ""
        try:
            provider_id = str((resp.json() or {}).get("id", ""))
        except ValueError:
            provider_id = ""
        return SendResult(ok=True, status="sent", provider_message_id=provider_id)

    def register_webhooks(self, *, inbound_url, receipt_url) -> list[dict]:
        """Register our inbound + delivery webhooks on the phone (idempotent per
        gateway+event via a stable ``id``). Returns a per-event result list."""
        base = self._base_url()
        if not base:
            return [{"event": "*", "ok": False, "detail": "base_url is empty"}]
        results = []
        for event, kind in _WEBHOOK_EVENTS.items():
            url = inbound_url if kind == "inbound" else receipt_url
            payload = {
                "id": f"pointy-{self.gateway.id}-{event.replace(':', '-')}",
                "url": url,
                "event": event,
            }
            try:
                resp = requests.post(
                    f"{base}/webhooks",
                    json=payload,
                    auth=self._auth(),
                    timeout=self._timeout(),
                )
                ok = resp.status_code < 400
                results.append(
                    {"event": event, "ok": ok, "detail": "" if ok else resp.text[:200]}
                )
            except requests.RequestException as exc:
                results.append({"event": event, "ok": False, "detail": str(exc)[:200]})
        return results

    # --- inbound webhooks ---------------------------------------------------
    def verify_inbound(self, request) -> bool:
        key = self.gateway.get_secret("webhook_signing_key")
        if not key:
            return False
        signature = request.headers.get("X-Signature", "")
        if not signature:
            return False
        timestamp = request.headers.get("X-Timestamp", "")
        raw = request.body if isinstance(request.body, (bytes, bytearray)) else str(request.body).encode()
        signed = raw + str(timestamp).encode("utf-8")
        digest = hmac.new(key.encode("utf-8"), signed, hashlib.sha256).hexdigest()
        return constant_time_secret_equal(signature, digest)

    def parse_inbound(self, request) -> dict:
        data = request.data if isinstance(request.data, dict) else {}
        payload = data.get("payload") if isinstance(data.get("payload"), dict) else data
        return {
            "from": payload.get("sender") or payload.get("phoneNumber") or "",
            "body": payload.get("message") or "",
            "provider_message_id": str(payload.get("messageId") or payload.get("id") or ""),
            "sent_at": payload.get("receivedAt"),
        }

    def parse_receipt(self, request) -> list[dict]:
        data = request.data if isinstance(request.data, dict) else {}
        payload = data.get("payload") if isinstance(data.get("payload"), dict) else data
        status = _EVENT_STATUS.get(str(data.get("event", "")), "")
        return [
            {
                "provider_message_id": str(payload.get("messageId") or ""),
                "status": status,
            }
        ]
