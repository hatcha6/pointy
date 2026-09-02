from django.conf import settings
from django.core.exceptions import ImproperlyConfigured
from django.utils import timezone
from rest_framework import status, views
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework.response import Response

from apps.analytics.export import estimate_export_rows
from apps.analytics.models import AnalyticsEvent
from apps.analytics.serializers import AnalyticsEventExportQuerySerializer
from apps.analytics.services import (
    count_events_for_export,
    filter_events_for_export,
    iter_events_export_zip,
    record_domain_event,
)
from apps.analytics.views import (
    EXPORT_RENDERER_CLASSES,
    ExportFormatAgnosticNegotiation,
    build_events_export_response,
)

from .credentials import constant_time_secret_equal
from .discovery import (
    backend_discovery_payload,
    request_discovery_allowed,
)
from .models import RelayInstallation, ShopSettings
from .permissions import HasPointyPermission
from .relay import (
    RelayControlError,
    RelayDeadline,
    connector_setup_token_accepted,
    consume_connector_setup_token,
    ensure_relay_installation,
    issue_pairing_ticket,
    relay_config,
    relay_status_payload,
    relay_transport_cooldown_active,
    scoped_relay_client,
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


CONNECTOR_TOKEN_HEADER = "X-Pointy-Connector-Token"


def connector_token_accepted(installation, provided_token):
    """Is ``provided_token`` this installation's connector token?

    The three connector-authenticated endpoints below all gate on this one
    secret, through one comparison rather than three hand-rolled copies. It
    matters most that a blank stored token is never a credential:
    ``connector_token`` is legitimately "" on a shop seeded from env credentials
    without ``POINTY_RELAY_CONNECTOR_TOKEN`` (see ``ensure_relay_installation``),
    and a bare ``compare_digest`` would then match the equally-empty missing
    header and authenticate every anonymous caller. That guard and the
    non-ASCII one both live in ``constant_time_secret_equal``.
    """
    return constant_time_secret_equal(
        provided_token,
        getattr(installation, "connector_token", ""),
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
        # Pairing runs at every sign-in and is opportunistic: LAN operation
        # must not wait on the uplink. A recent transport failure is answered
        # from memory, and the two relay round trips below share ONE wall-clock
        # budget so a slow link cannot hold a worker for a multiple of the
        # per-request timeout (field data: a median of 16 s per pairing on a
        # shop with a poor uplink, 58 times in a week).
        if relay_transport_cooldown_active():
            return Response(self._inactive_payload(installation, reason="relay_unavailable"))
        deadline = RelayDeadline(self._pairing_budget_seconds())
        per_call = relay_config().timeout_seconds
        try:
            installation = sync_relay_installation(
                installation,
                timeout=deadline.timeout(per_call),
                # Best-effort and retried by the periodic sync; not worth a
                # third round trip on the sign-in path.
                push_shop_name=False,
            )
        except (ImproperlyConfigured, RelayControlError):
            return Response(self._inactive_payload(reason="relay_unavailable"))
        if not installation.remote_access_supported:
            return Response(self._inactive_payload(installation, reason="relay_not_active"))

        ticket_timeout = deadline.timeout(per_call)
        if ticket_timeout is None:
            return Response(
                self._inactive_payload(installation, reason="relay_unavailable")
            )
        try:
            issued = issue_pairing_ticket(
                installation,
                device_id=serializer.validated_data.get("device_id", ""),
                device_name=serializer.validated_data.get("device_name", ""),
                timeout=ticket_timeout,
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

    @staticmethod
    def _pairing_budget_seconds():
        return max(int(getattr(settings, "POINTY_RELAY_PAIRING_BUDGET_SECONDS", 8)), 1)

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
        installation = RelayInstallation.load()
        is_renewal = self._valid_connector_token(
            installation,
            request.headers.get(CONNECTOR_TOKEN_HEADER, ""),
        )
        setup_token = ""
        if not is_renewal:
            setup_token = request.headers.get("X-Pointy-Connector-Setup-Token", "")
            # Validate but do NOT spend the token yet: a one-time token must
            # survive a failed bootstrap (e.g. the relay is briefly unreachable
            # below) so the connector can retry, instead of being stranded with a
            # spent token that every later request rejects with 403 (issue #4).
            if not connector_setup_token_accepted(setup_token):
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
        if not is_renewal:
            # The whole bootstrap succeeded — only now spend the token. Any
            # non-seed token becomes single-use; the env seed stays valid so the
            # connector can re-bootstrap after a state-volume loss.
            consume_connector_setup_token(setup_token)
        serializer = RelayConnectorConfigSerializer(
            self._connector_config_payload(installation, certificate)
        )
        record_domain_event(
            name=(
                "relay.connector.certificate_renewed"
                if is_renewal
                else "relay.connector.bootstrap_succeeded"
            ),
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

    def _valid_connector_token(self, installation, provided_token):
        if installation is None:
            return False
        return connector_token_accepted(installation, provided_token)

    def _issue_connector_certificate(self, installation, csr_pem):
        if not csr_pem.strip():
            return None
        try:
            return scoped_relay_client(installation).issue_connector_certificate(
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
        provided_token = request.headers.get(CONNECTOR_TOKEN_HEADER, "")
        if not connector_token_accepted(installation, provided_token):
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


class RelayDiagnosticsAnalyticsExportView(views.APIView):
    """Remote-support export of this installation's tracking/usage/error events.

    Returns the exact same ZIP the Shop Settings "Export Tracking" screen
    produces (reusing the analytics export pipeline), but authenticated with the
    on-prem connector token instead of a logged-in manager. The relay operator
    pulls it over the connector tunnel: the connector injects
    ``X-Pointy-Connector-Token`` for requests it forwards under
    ``/api/relay/diagnostics/``. Because the public relay proxy only routes
    ``/api/`` paths reached via an access ticket, client devices cannot invoke
    this endpoint through the relay; the connector token is the gate.
    """

    permission_classes = [AllowAny]
    authentication_classes = []
    # ``?format=csv`` names the file inside the zip; without this DRF reads it
    # as a renderer override and 404s (see ExportFormatAgnosticNegotiation).
    content_negotiation_class = ExportFormatAgnosticNegotiation
    # The relay asks for ``application/zip`` on the tunnel request; negotiation
    # runs before the handler and 406s without a renderer declaring it.
    renderer_classes = EXPORT_RENDERER_CLASSES

    def get(self, request):
        installation = RelayInstallation.load()
        if installation is None:
            return Response(
                {"detail": "relay installation is not configured"},
                status=status.HTTP_404_NOT_FOUND,
            )
        provided_token = request.headers.get(CONNECTOR_TOKEN_HEADER, "")
        if not connector_token_accepted(installation, provided_token):
            return Response(
                {"detail": "connector token rejected"},
                status=status.HTTP_403_FORBIDDEN,
            )

        serializer = AnalyticsEventExportQuerySerializer(data=request.query_params)
        serializer.is_valid(raise_exception=True)
        queryset = filter_events_for_export(
            AnalyticsEvent.objects.all(),
            serializer.normalized_filters,
        )
        exported_at = timezone.now()
        # Same deal as the in-app export: an exact COUNT(*) is a full scan of
        # the filtered range, so it only happens when the puller asks for it
        # (``count=exact``). Otherwise the planner's estimate goes on the wire
        # and the zip manifest carries the real number.
        filters = serializer.normalized_filters
        count_mode = filters.get("count", "estimate")
        event_count = (
            count_events_for_export(queryset) if count_mode == "exact" else None
        )
        estimated_event_count = (
            estimate_export_rows(queryset, alias=queryset.db)
            if count_mode == "estimate"
            else None
        )
        record_domain_event(
            name="analytics.export.support_pull",
            event_type=AnalyticsEvent.EventType.AUDIT,
            severity=AnalyticsEvent.Severity.INFO,
            entity_type="relay_installation",
            entity_id=installation.pk,
            installation_id=installation.installation_id,
            attributes={
                "installation_id": installation.installation_id,
                "event_count": event_count,
                "estimated_event_count": estimated_event_count,
                "format": filters.get("format", "csv"),
            },
        )
        generator = iter_events_export_zip(
            queryset=queryset,
            filters=filters,
            exported_by=None,
            exported_at=exported_at,
        )
        response = build_events_export_response(
            request,
            generator,
            exported_at,
            event_count=event_count,
            estimated_event_count=estimated_event_count,
        )
        response["X-Pointy-App-Version"] = str(
            settings.SPECTACULAR_SETTINGS.get("VERSION", "")
        )
        response["X-Pointy-Connector-Version"] = installation.connector_version or ""
        return response
