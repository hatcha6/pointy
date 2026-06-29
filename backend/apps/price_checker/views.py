from rest_framework import mixins, status, viewsets
from rest_framework.decorators import action, api_view, permission_classes
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.reverse import reverse

from apps.core.permissions import HasPointyPermission

from . import drivers as driver_registry
from .discovery import register_http_kiosk, run_discovery_scan
from .drivers import driver_for_device, get_driver
from .formatting import profile_from_device
from .models import PriceCheckerDevice, PriceCheckEvent
from .permissions import IsPrivateNetworkOrAuthenticated
from .serializers import (
    PriceCheckerDeviceSerializer,
    PriceCheckEventSerializer,
    price_result_payload,
)
from .service import perform_lookup


def _peer_ip(request) -> str:
    return request.META.get("REMOTE_ADDR", "") or ""


def _image_url(request, result) -> str:
    """Absolute, token-signed URL for the scanned product's image (or "").

    The token lets an unauthenticated LAN kiosk fetch the image content; the
    kiosk requests it right after the scan, so the short-lived token is fresh.
    """
    if not (result.found and result.image_attachment_id):
        return ""
    base = reverse(
        "attachment-content",
        kwargs={"pk": result.image_attachment_id},
        request=request,
    )
    separator = "&" if "?" in base else "?"
    return f"{base}{separator}token={result.image_token}"


class PriceCheckerDeviceViewSet(viewsets.ModelViewSet):
    queryset = PriceCheckerDevice.objects.all()
    serializer_class = PriceCheckerDeviceSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("price_checker.view_pricecheckerdevice",),
        "retrieve": ("price_checker.view_pricecheckerdevice",),
        "create": ("price_checker.add_pricecheckerdevice",),
        "update": ("price_checker.change_pricecheckerdevice",),
        "partial_update": ("price_checker.change_pricecheckerdevice",),
        "destroy": ("price_checker.delete_pricecheckerdevice",),
        "scan": ("price_checker.add_pricecheckerdevice",),
        "drivers": ("price_checker.view_pricecheckerdevice",),
    }
    filterset_fields = ("transport", "status", "driver", "discovery_method")
    search_fields = ("name", "identifier", "address", "mac_address", "location")
    ordering_fields = ("name", "last_seen_at", "created_at")

    @action(detail=False, methods=["post"])
    def scan(self, request):
        """Trigger an on-demand LAN scan and register what we find."""
        return Response(run_discovery_scan())

    @action(detail=False, methods=["get"])
    def drivers(self, request):
        """List supported makes/models so the UI can populate a picker."""
        return Response(
            [
                {
                    "key": driver.key,
                    "label": driver.label,
                    "make": driver.make,
                    "model": driver.model,
                    "transport": driver.transport,
                    "default_rows": driver.default_rows,
                    "default_cols": driver.default_cols,
                    "default_arabic": driver.default_arabic,
                    "default_encoding": driver.default_encoding,
                    "default_port": driver.default_port,
                }
                for driver in driver_registry.all_drivers()
            ]
        )


class PriceCheckEventViewSet(
    mixins.ListModelMixin,
    mixins.RetrieveModelMixin,
    viewsets.GenericViewSet,
):
    queryset = PriceCheckEvent.objects.select_related("device", "variant").all()
    serializer_class = PriceCheckEventSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("price_checker.view_pricecheckevent",),
        "retrieve": ("price_checker.view_pricecheckevent",),
    }
    filterset_fields = ("result", "device", "device_identifier", "barcode")
    search_fields = ("barcode", "product_name", "device_identifier")
    ordering_fields = ("created_at", "latency_ms")


@api_view(["GET", "POST"])
@permission_classes([IsPrivateNetworkOrAuthenticated])
def price_lookup_view(request):
    """HTTP/web-kiosk price lookup. Returns display-ready JSON + text lines."""
    barcode = request.query_params.get("barcode") or request.data.get("barcode")
    identifier = request.query_params.get("device") or request.data.get("device")

    device = None
    if identifier:
        device = (
            PriceCheckerDevice.objects.filter(identifier=identifier)
            .exclude(status=PriceCheckerDevice.Status.DISABLED)
            .first()
        )
    driver = (
        driver_for_device(device)
        if device
        else get_driver(driver_registry.DEFAULT_DRIVER_KEY)
    )
    profile = profile_from_device(device) if device else driver.profile()

    result, _ = perform_lookup(
        barcode,
        device=device,
        source_address=_peer_ip(request),
        render_lines=lambda r: driver.display_lines(r, profile),
        with_image=True,
    )
    return Response(
        price_result_payload(
            result,
            allow_arabic=profile.allow_arabic,
            display_lines=driver.display_lines(result, profile),
            image_url=_image_url(request, result),
        )
    )


@api_view(["POST"])
@permission_classes([IsPrivateNetworkOrAuthenticated])
def price_checker_register_view(request):
    """Let an HTTP/web kiosk (our app in price-checker mode) self-register.

    LAN-allowed like the lookup endpoint so a kiosk shows up in the fleet with
    live scan history without a manager having to add it by hand. Idempotent on
    the client-supplied ``identifier``.
    """
    identifier = (
        request.data.get("identifier") or request.query_params.get("identifier") or ""
    ).strip()
    if not identifier:
        return Response(
            {"detail": "identifier is required."},
            status=status.HTTP_400_BAD_REQUEST,
        )
    device = register_http_kiosk(
        identifier=identifier,
        name=(request.data.get("name") or "").strip(),
        location=(request.data.get("location") or "").strip(),
        address=_peer_ip(request),
    )
    return Response(
        PriceCheckerDeviceSerializer(device, context={"request": request}).data
    )
