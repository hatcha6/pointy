from rest_framework.permissions import BasePermission

from apps.core.credentials import constant_time_secret_equal
from apps.core.discovery import request_is_lan_local

from .models import MessagingGateway
from .transports import UnknownProvider, transport_for


class IsGatewayPeer(BasePermission):
    """Authenticate an inbound / receipt webhook as coming from a gateway's own
    device. Always LAN-gated, plus one of:

    * a per-gateway **webhook token** (a shared secret placed in the registered
      URLs during zero-touch activation — only the paired phone knows it); or
    * the transport's own **HMAC** verification (for a phone configured manually
      with a signing key).

    The gateway id is the ``gateway_id`` URL kwarg; on success the resolved
    gateway is stashed on the view as ``view.gateway`` for the handler.
    """

    def has_permission(self, request, view):
        # LAN-local, not merely a private peer address: the relay connector
        # dials the backend from the LAN, so a relayed request would otherwise
        # clear this gate. The paired phone is always on the shop's network.
        if not request_is_lan_local(request):
            return False
        gateway = MessagingGateway.objects.filter(
            pk=view.kwargs.get("gateway_id"), is_active=True
        ).first()
        if gateway is None:
            return False

        expected_token = gateway.get_secret("webhook_token")
        if expected_token:
            provided = request.query_params.get("token", "")
            if not constant_time_secret_equal(provided, expected_token):
                return False
            view.gateway = gateway
            return True

        try:
            transport = transport_for(gateway)
        except UnknownProvider:
            return False
        if not transport.verify_inbound(request):
            return False
        view.gateway = gateway
        return True
