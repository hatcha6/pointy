from __future__ import annotations

import logging
import secrets

from celery import current_app
from django.conf import settings
from django.utils import timezone
from rest_framework import viewsets
from rest_framework.decorators import action
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.core.dispatch import enqueue_best_effort
from apps.core.permissions import HasPointyPermission

from .models import MessagingGateway, OutboundMessage
from .permissions import IsGatewayPeer
from .serializers import MessagingGatewaySerializer, OutboundMessageSerializer
from .services import (
    NoGatewayConfigured,
    apply_receipt,
    deliver_message,
    enqueue_message,
    record_inbound,
)
from .transports import transport_for

logger = logging.getLogger(__name__)


def _webhook_base_url(request) -> str:
    """The base URL the phone should POST webhooks to. An explicit override wins;
    otherwise use the LAN host the admin reached the backend on (the phone is on
    the same LAN). Plain http — SMS Gate posts over the LAN, not TLS."""
    override = (getattr(settings, "POINTY_MESSAGING_WEBHOOK_BASE_URL", "") or "").strip()
    if override:
        return override.rstrip("/")
    return f"http://{request.get_host()}"


class MessagingGatewayViewSet(viewsets.ModelViewSet):
    queryset = MessagingGateway.objects.all()
    serializer_class = MessagingGatewaySerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("messaging.manage_gateways",),
        "retrieve": ("messaging.manage_gateways",),
        "create": ("messaging.manage_gateways",),
        "update": ("messaging.manage_gateways",),
        "partial_update": ("messaging.manage_gateways",),
        "destroy": ("messaging.manage_gateways",),
        "test_send": ("messaging.manage_gateways",),
        "activate": ("messaging.manage_gateways",),
        "messages": ("messaging.view_logs",),
    }

    @action(detail=True, methods=["post"])
    def test_send(self, request, pk=None):
        """Send one transactional test message now and return its final state.

        ``max_attempts=1`` so a misconfigured gateway surfaces its error to the
        manager immediately instead of silently re-queuing for a retry.
        """
        gateway = self.get_object()
        to = (request.data.get("to") or "").strip()
        if not to:
            return Response({"detail": "رقم الهاتف مطلوب."}, status=400)
        body = (request.data.get("body") or "").strip() or "رسالة اختبار من دفتر ✅"
        try:
            message = enqueue_message(
                to=to,
                body=body,
                gateway=gateway,
                consent_class=OutboundMessage.ConsentClass.TRANSACTIONAL,
                source_type="test_send",
                max_attempts=1,
            )
        except NoGatewayConfigured:
            return Response({"detail": "لا توجد بوابة رسائل مُفعّلة."}, status=400)
        deliver_message(message)
        message.refresh_from_db()
        return Response(OutboundMessageSerializer(message).data)

    @action(detail=True, methods=["post"])
    def activate(self, request, pk=None):
        """Zero-touch activation: provision a per-gateway webhook token, register
        our inbound + delivery webhooks on the phone (so two-way SMS + delivery
        receipts start flowing automatically), and make this the active default.
        No manual SMS Gate configuration needed."""
        gateway = self.get_object()
        transport = transport_for(gateway)

        token = gateway.get_secret("webhook_token")
        if not token:
            token = secrets.token_urlsafe(24)
            gateway.set_secret("webhook_token", token)
            gateway.save(update_fields=["secrets_encrypted", "updated_at"])

        base = _webhook_base_url(request)
        inbound_url = f"{base}/api/messaging/inbound/{gateway.id}/?token={token}"
        receipt_url = f"{base}/api/messaging/receipts/{gateway.id}/?token={token}"

        webhooks = []
        register = getattr(transport, "register_webhooks", None)
        if callable(register):
            webhooks = register(inbound_url=inbound_url, receipt_url=receipt_url)

        gateway.is_active = True
        gateway.is_default = True
        gateway.last_seen_at = timezone.now()
        gateway.save(
            update_fields=["is_active", "is_default", "last_seen_at", "updated_at"]
        )

        all_ok = bool(webhooks) and all(item.get("ok") for item in webhooks)
        return Response(
            {"ok": all_ok, "webhooks": webhooks, "webhook_base_url": base}
        )

    @action(detail=False, methods=["get"])
    def messages(self, request):
        queryset = OutboundMessage.objects.select_related("gateway")
        gateway_id = request.query_params.get("gateway")
        if gateway_id:
            queryset = queryset.filter(gateway_id=gateway_id)
        status_filter = request.query_params.get("status")
        if status_filter:
            queryset = queryset.filter(status=status_filter)
        page = self.paginate_queryset(queryset)
        if page is not None:
            return self.get_paginated_response(
                OutboundMessageSerializer(page, many=True).data
            )
        return Response(OutboundMessageSerializer(queryset[:200], many=True).data)


class InboundWebhookView(APIView):
    """Receive an inbound SMS from a gateway's device (LAN + HMAC gated).

    Persists the raw message idempotently, then dispatches routing to the CRM
    layer by task name so messaging never imports crm. Best-effort dispatch: the
    message is stored regardless of broker health.
    """

    authentication_classes = []
    permission_classes = [IsGatewayPeer]

    def post(self, request, gateway_id):
        gateway = self.gateway
        parsed = transport_for(gateway).parse_inbound(request)
        message, created = record_inbound(
            gateway,
            from_phone=parsed.get("from", ""),
            body=parsed.get("body", ""),
            provider_message_id=parsed.get("provider_message_id", ""),
        )
        if created:
            # Look the task up by name (no crm import) and enqueue it through the
            # bounded publisher, which honours task_always_eager for tests and —
            # unlike the bare try/except this replaces — also survives a broker
            # that accepts the connection and then stops answering. The inbound
            # row is stored either way; only the routing pass is lost, and the
            # gateway must not be left holding an open POST for it.
            if not enqueue_best_effort(
                current_app.tasks["crm.route_inbound"], message.id
            ):
                logger.warning("inbound %s stored but not routed", message.id)
        return Response({"ok": True, "id": message.id, "created": created})


class DeliveryReceiptWebhookView(APIView):
    """Receive delivery-status callbacks and advance the matching messages."""

    authentication_classes = []
    permission_classes = [IsGatewayPeer]

    def post(self, request, gateway_id):
        gateway = self.gateway
        raw = request.data if isinstance(request.data, dict) else {}
        applied = 0
        for item in transport_for(gateway).parse_receipt(request):
            apply_receipt(
                gateway,
                provider_message_id=item.get("provider_message_id", ""),
                status=item.get("status", ""),
                raw=raw,
            )
            applied += 1
        return Response({"ok": True, "applied": applied})
