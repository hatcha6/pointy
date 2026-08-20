"""In-memory driver for tests and the Flutter preview harness.

Records every send so a test (or a preview) can assert on what "went out"
without a real phone. Set ``config["fail_with"] = "<error_code>"`` on the gateway
to simulate a failure. Never used in production.
"""

from __future__ import annotations

from .base import MessagingTransport, SendResult, register

SENT_MESSAGES: list[dict] = []
REGISTERED_WEBHOOKS: list[dict] = []


def reset():
    SENT_MESSAGES.clear()
    REGISTERED_WEBHOOKS.clear()


@register("fake")
class FakeDriver(MessagingTransport):
    def send(self, *, to, body, message=None):
        fail = self.gateway.config.get("fail_with")
        if fail:
            return SendResult(
                ok=False, status="failed", error_code=str(fail),
                error_detail="simulated failure", retryable=str(fail) != "unauthorized",
            )
        SENT_MESSAGES.append({"to": to, "body": body, "gateway": self.gateway.pk})
        return SendResult(ok=True, status="sent", provider_message_id=f"fake-{len(SENT_MESSAGES)}")

    def register_webhooks(self, *, inbound_url, receipt_url):
        REGISTERED_WEBHOOKS.append(
            {"inbound": inbound_url, "receipt": receipt_url, "gateway": self.gateway.pk}
        )
        return [
            {"event": "sms:received", "ok": True, "detail": ""},
            {"event": "sms:delivered", "ok": True, "detail": ""},
        ]

    # No transport-level trust: a driver that answers True authenticates every
    # caller, and this one is registered in production code, so a gateway left
    # on the "fake" provider turned ``IsGatewayPeer`` into an open door — any
    # LAN peer could post a forged inbound SMS claiming any sender. Inbound to a
    # fake gateway goes through the shared ``webhook_token`` that activation
    # provisions, exactly like a real one; there is nothing left for the driver
    # itself to vouch for.
    def verify_inbound(self, request) -> bool:
        return False

    def parse_inbound(self, request) -> dict:
        data = getattr(request, "data", {}) or {}
        return {
            "from": data.get("from") or data.get("phoneNumber") or "",
            "body": data.get("body") or data.get("message") or "",
            "provider_message_id": str(data.get("id") or data.get("messageId") or ""),
            "sent_at": data.get("sent_at"),
        }

    def parse_receipt(self, request) -> list[dict]:
        data = getattr(request, "data", {}) or {}
        return [
            {
                "provider_message_id": str(data.get("id") or data.get("messageId") or ""),
                "status": str(data.get("status") or data.get("state") or ""),
            }
        ]
