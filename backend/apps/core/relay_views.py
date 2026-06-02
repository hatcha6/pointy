import secrets

from django.conf import settings
from django.core.exceptions import ImproperlyConfigured
from django.utils import timezone
from rest_framework import status, views
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework.response import Response

from apps.analytics.models import AnalyticsEvent
from apps.analytics.services import record_domain_event

from .discovery import (
    backend_discovery_payload,
    request_discovery_allowed,
)
from .models import RelayInstallation, ShopSettings
from .permissions import HasPointyPermission
from .relay import (
    RelayControlClient,
    RelayControlError,
    consume_connector_setup_token,
    ensure_relay_installation,
    issue_pairing_ticket,
    relay_status_payload,
    sync_relay_installation,
)
from .relay_serializers import (
    RelayConnectorConfigSerializer,
    RelayConnectorConfigRequestSerializer,
    RelayConnectorHeartbeatSerializer,
    RelayInstallationProvisionSerializer,
    RelayInstallationStatusSerializer,
    RelayPairingRequestSerializer,
    RelayPairingResponseSerializer,
)


class DiscoveryServiceView(views.APIView):
    permission_classes = [AllowAny]
    authentication_classes = []

    def get(self, request):
        if not request_discovery_allowed(request):
            return Response(
                {"detail": "service discovery unavailable"},
                status=status.HTTP_404_NOT_FOUND,
            )
        return Response(backend_discovery_payload(request=request))


class RelayInstallationView(views.APIView):
    permission_classes = [IsAuthenticated, HasPointyPermission]

    def get_required_permissions(self, request):
        return ("core.change_shopsettings",)

    def get(self, request):
        installation = RelayInstallation.load()
        if installation is not None and request.query_params.get("sync") == "1":
            try:
                installation = sync_relay_installation(installation)
            except (ImproperlyConfigured, RelayControlError) as exc:
                return Response(
                    {"detail": str(exc)},
                    status=status.HTTP_502_BAD_GATEWAY,
                )
        serializer = RelayInstallationStatusSerializer(relay_status_payload(installation))
        return Response(serializer.data)

    def post(self, request):
        serializer = RelayInstallationProvisionSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        try:
            installation, created = ensure_relay_installation()
            if not created and serializer.validated_data["sync"]:
                installation = sync_relay_installation(installation)
        except (ImproperlyConfigured, RelayControlError) as exc:
            return Response(
                {"detail": str(exc)},
                status=status.HTTP_502_BAD_GATEWAY,
            )
        event_name = (
            "relay.installation.provisioned"
            if created
            else "relay.installation.synced"
        )
        record_domain_event(
            name=event_name,
            event_type=AnalyticsEvent.EventType.AUDIT,
            severity=AnalyticsEvent.Severity.INFO,
            user=request.user,
            entity_type="relay_installation",
            entity_id=installation.pk,
            attributes={
                "installation_id": installation.installation_id,
                "relay_enabled": installation.relay_enabled,
                "subscription_active": installation.subscription_active,
            },
        )
        response = RelayInstallationStatusSerializer(relay_status_payload(installation))
        return Response(
            response.data,
            status=status.HTTP_201_CREATED if created else status.HTTP_200_OK,
        )


class RelayPairingView(views.APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request):
        if not request_discovery_allowed(request):
            return Response(
                self._inactive_payload(reason="relay_requires_lan_pairing"),
                status=status.HTTP_403_FORBIDDEN,
            )
        serializer = RelayPairingRequestSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        installation = RelayInstallation.load()
        if installation is None:
            return Response(self._inactive_payload(reason="relay_not_configured"))
        try:
            installation = sync_relay_installation(installation)
        except (ImproperlyConfigured, RelayControlError):
            return Response(self._inactive_payload(reason="relay_unavailable"))
        if not installation.remote_access_supported:
            return Response(self._inactive_payload(installation, reason="relay_not_active"))

        try:
            issued = issue_pairing_ticket(
                installation,
                device_id=serializer.validated_data.get("device_id", ""),
                device_name=serializer.validated_data.get("device_name", ""),
            )
        except (ImproperlyConfigured, RelayControlError):
            return Response(
                self._inactive_payload(installation, reason="relay_unavailable")
            )

        device_id = serializer.validated_data.get("device_id", "")
        record_domain_event(
            name="relay.pairing.ticket_issued",
            event_type=AnalyticsEvent.EventType.AUDIT,
            severity=AnalyticsEvent.Severity.INFO,
            user=request.user,
            entity_type="relay_installation",
            entity_id=installation.pk,
            installation_id=installation.installation_id,
            device_id=device_id,
            attributes={
                "installation_id": installation.installation_id,
                "relay_enabled": installation.relay_enabled,
                "subscription_active": installation.subscription_active,
                "device_id_present": bool(device_id),
                "device_name_present": bool(
                    serializer.validated_data.get("device_name", "")
                ),
            },
        )
        payload = {
            "remote_access_supported": True,
            "installation_id": installation.installation_id,
            "shop_name": installation.shop_name,
            "relay_public_api_url": installation.relay_public_api_url,
            "relay_token": issued["token"],
            "expires_at": issued["expires_at"],
            "relay_refresh_token": issued.get("refresh_token", ""),
            "refresh_expires_at": issued.get("refresh_expires_at"),
            "reason": "",
        }
        response = RelayPairingResponseSerializer(payload)
        return Response(response.data)

    def _inactive_payload(self, installation=None, *, reason):
        return RelayPairingResponseSerializer(
            {
                "remote_access_supported": False,
                "installation_id": installation.installation_id if installation else "",
                "shop_name": (
                    installation.shop_name if installation else ShopSettings.load().shop_name
                ),
                "relay_public_api_url": (
                    installation.relay_public_api_url if installation else ""
                ),
                "relay_token": "",
                "expires_at": None,
                "relay_refresh_token": "",
                "refresh_expires_at": None,
                "reason": reason,
            }
        ).data


class RelayConnectorConfigView(views.APIView):
    permission_classes = [AllowAny]
    authentication_classes = []

    def post(self, request):
        if not request_discovery_allowed(request):
            return Response(
                {"detail": "connector bootstrap requires LAN access"},
                status=status.HTTP_403_FORBIDDEN,
            )
        request_serializer = RelayConnectorConfigRequestSerializer(data=request.data)
        request_serializer.is_valid(raise_exception=True)
        provided_token = request.headers.get("X-Pointy-Connector-Setup-Token", "")
        if not consume_connector_setup_token(provided_token):
            return Response(
                {"detail": "connector setup token rejected"},
                status=status.HTTP_403_FORBIDDEN,
            )
        try:
            installation, _ = ensure_relay_installation()
        except (ImproperlyConfigured, RelayControlError) as exc:
            return Response(
                {"detail": str(exc)},
                status=status.HTTP_502_BAD_GATEWAY,
            )
        certificate = self._issue_connector_certificate(
            installation,
            request_serializer.validated_data.get("csr_pem", ""),
        )
        if isinstance(certificate, Response):
            return certificate
        serializer = RelayConnectorConfigSerializer(
            self._connector_config_payload(installation, certificate)
        )
        record_domain_event(
            name="relay.connector.bootstrap_succeeded",
            event_type=AnalyticsEvent.EventType.AUDIT,
            severity=AnalyticsEvent.Severity.INFO,
            entity_type="relay_installation",
            entity_id=installation.pk,
            installation_id=installation.installation_id,
            attributes={
                "installation_id": installation.installation_id,
                "certificate_issued": bool(certificate),
                "certificate_expires_at": certificate.get("expires_at")
                if certificate
                else None,
            },
        )
        return Response(serializer.data)

    def _issue_connector_certificate(self, installation, csr_pem):
        if not csr_pem.strip():
            return None
        try:
            return RelayControlClient().issue_connector_certificate(
                installation_id=installation.installation_id,
                csr_pem=csr_pem,
            )
        except (ImproperlyConfigured, RelayControlError) as exc:
            return Response(
                {"detail": str(exc)},
                status=status.HTTP_502_BAD_GATEWAY,
            )

    def _connector_config_payload(self, installation, certificate):
        certificate = certificate or {}
        return {
            "installation_id": installation.installation_id,
            "shop_name": installation.shop_name,
            "relay_connector_address": installation.relay_connector_address,
            "connector_token": installation.connector_token,
            "tls_server_name": str(
                getattr(settings, "POINTY_RELAY_CONNECTOR_TLS_SERVER_NAME", "")
            ).strip(),
            "connector_certificate_pem": certificate.get("certificate_pem", ""),
            "connector_ca_certificate_pem": certificate.get("ca_certificate_pem", ""),
            "connector_certificate_expires_at": certificate.get("expires_at"),
        }


class RelayConnectorHeartbeatView(views.APIView):
    permission_classes = [AllowAny]
    authentication_classes = []

    def post(self, request):
        serializer = RelayConnectorHeartbeatSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        installation = RelayInstallation.load()
        if installation is None:
            return Response(
                {"detail": "relay installation is not configured"},
                status=status.HTTP_404_NOT_FOUND,
            )
        provided_token = request.headers.get("X-Pointy-Connector-Token", "")
        if not secrets.compare_digest(provided_token, installation.connector_token):
            return Response(
                {"detail": "connector token rejected"},
                status=status.HTTP_403_FORBIDDEN,
            )
        installation.connector_last_seen_at = timezone.now()
        installation.connector_version = serializer.validated_data.get("version", "")
        installation.save(
            update_fields=[
                "connector_last_seen_at",
                "connector_version",
                "updated_at",
            ]
        )
        return Response(
            {
                "ok": True,
                "installation_id": installation.installation_id,
                "connector_last_seen_at": installation.connector_last_seen_at,
            }
        )
