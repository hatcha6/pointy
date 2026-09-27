from __future__ import annotations

import logging

from django.db import transaction
from rest_framework import mixins, viewsets
from rest_framework.decorators import action
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.core import caching
from apps.core.dispatch import enqueue_best_effort
from apps.core.models import ShopSettings
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
    unavailable_message,
)
from .sms_templates import sms_template
from .status import messaging_status
from .transports import transport_for

logger = logging.getLogger(__name__)


class MessagingGatewayViewSet(
    mixins.ListModelMixin,
    mixins.RetrieveModelMixin,
    mixins.UpdateModelMixin,
    viewsets.GenericViewSet,
):
    """The shop's SMS gateway: read it, tune its pacing, switch it off, test it.

    No create/delete: the relay gateway provisions itself on first need
    (``MessagingGateway.ensure_relay_gateway``) and holds no credentials, so
    there is nothing for a shop to add — only brakes and a switch to set.
    """

    queryset = MessagingGateway.objects.all()
    serializer_class = MessagingGatewaySerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("messaging.manage_gateways",),
        "retrieve": ("messaging.manage_gateways",),
        "update": ("messaging.manage_gateways",),
        "partial_update": ("messaging.manage_gateways",),
        "test_send": ("messaging.manage_gateways",),
        "messages": ("messaging.view_logs",),
    }

    def perform_update(self, serializer):
        was_active = serializer.instance.is_active
        gateway = serializer.save()
        if gateway.is_active != was_active:
            # sms_available rides the session; moving the permissions version
            # makes every device re-read it, so switching SMS off hides the
            # send actions everywhere within one poll.
            transaction.on_commit(caching.bump_perm_version)

    @action(detail=True, methods=["post"])
    def test_send(self, request, pk=None):
        """Send the test template now and return the message's final state.

        ``max_attempts=1`` so a problem — no subscription, the allowance spent,
        a template the provider has not approved — reaches the manager at once
        instead of being quietly re-queued for a retry.
        """
        gateway = self.get_object()
        to = (request.data.get("to") or "").strip()
        if not to:
            return Response({"detail": "رقم الهاتف مطلوب."}, status=400)
        shop_name = (ShopSettings.load().shop_name or "").strip() or "متجرنا"
        try:
            message = enqueue_message(
                to=to,
                template=sms_template("test", shop_name),
                gateway=gateway,
                source_type="test_send",
                max_attempts=1,
            )
        except NoGatewayConfigured as exc:
            return Response(
                {"detail": unavailable_message(exc), "code": exc.code}, status=400
            )
        deliver_message(message)
        message.refresh_from_db()
        return Response(OutboundMessageSerializer(message).data)

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


class MessagingStatusView(APIView):
    """Everything the SMS settings page shows: the subscription's verdict, this
    month's usage, the gateway's brakes and the messages Pointy sends."""

    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {"GET": ("messaging.manage_gateways",)}

    def get(self, request):
        return Response(messaging_status())


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
            # Dispatch by *name* (no crm import) through the bounded publisher,
            # which honours task_always_eager for tests and — unlike the bare
            # try/except this replaces — also survives a broker that accepts the
            # connection and then stops answering. The name is passed, not
            # resolved here, so a registry miss (crm's tasks module not imported
            # yet) stays inside the publisher's guard. The inbound row is stored
            # either way; only the routing pass is lost, and the gateway must not
            # be left holding an open POST for it.
            if not enqueue_best_effort("crm.route_inbound", message.id):
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
