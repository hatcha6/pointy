"""The two halves of the companion channel.

**Till side** is ordinary authenticated API: create a pairing, watch the stream,
manage paired phones, ask for a photo.

**Phone side** holds no session and no permissions (see ``permissions.py``). It
can claim a pairing code, read the small context the till chose to show it, and
post a scan or a photo. That is the entire surface a lost phone exposes.

Both halves are LAN-gated by ``request_is_lan_local`` on the phone side; the
till side is reachable however the till itself is (including over the relay,
because a manager reviewing paired devices remotely is legitimate — but a phone
posting photos from the internet is not).
"""

from django.conf import settings
from django.core.handlers.asgi import ASGIRequest
from django.http import StreamingHttpResponse
from django.utils import timezone
from rest_framework import status, views
from rest_framework.exceptions import PermissionDenied, ValidationError
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from apps.core.models import ShopSettings
from apps.core.roles import user_is_manager
from apps.core.streaming import aiter_in_thread
from apps.core.throttling import (
    CompanionPairRateThrottle,
    CompanionUploadRateThrottle,
)

from . import services
from .decoding import decode_image, decoder_available
from .models import (
    CompanionCaptureRequest,
    CompanionDevice,
    CompanionEvent,
)
from .permissions import IsCompanionDevice, IsOnShopNetwork
from .serializers import (
    CompanionCaptureRequestSerializer,
    CompanionContextSerializer,
    CompanionDeviceSerializer,
    CompanionEventSerializer,
)


def _required_till_key(request) -> str:
    """The till whose channel this request is about.

    The key is the client's own random install id, never guessable from
    outside, and every request carrying one is already an authenticated member
    of this shop's staff. It identifies a till; it is not a second password,
    and the channel carries only scans and photos those same staff produced.
    """
    till_key = (
        request.query_params.get("till_key")
        or (request.data.get("till_key") if hasattr(request, "data") else None)
        or ""
    ).strip()
    if not till_key:
        raise ValidationError({"till_key": "A till key is required."})
    return till_key[:64]


def _int_param(request, name, default=0):
    try:
        return int(request.query_params.get(name, default))
    except (TypeError, ValueError):
        return default


# --------------------------------------------------------------------------
# Till side
# --------------------------------------------------------------------------


class CompanionPairingView(views.APIView):
    """Mint the QR the phone scans."""

    permission_classes = [IsAuthenticated]

    def post(self, request):
        till_key = _required_till_key(request)
        till_label = str(request.data.get("till_label") or "").strip()[:120]
        pairing, code = services.create_pairing(
            user=request.user, till_key=till_key, till_label=till_label
        )
        return Response(
            {
                "code": code,
                "url": services.companion_page_url(request, code),
                "till_key": till_key,
                "expires_at": pairing.expires_at,
            },
            status=status.HTTP_201_CREATED,
        )


class CompanionDeviceListView(views.APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        till_key = _required_till_key(request)
        # Two joins, two N+1s: ``is_live`` reads ``register_session.status`` and
        # the serializer reads ``paired_by.username``. This response is now the
        # *only* way a till learns that its phone's shift ended — nothing emits
        # an event for that, because the revocation is lazy and happens when the
        # phone next calls, while ``is_live`` is computed per response. Asking is
        # the whole signal, so it is worth asking once.
        devices = (
            CompanionDevice.objects.live()
            .select_related("register_session", "paired_by")
            .filter(till_key=till_key)
        )
        return Response(
            CompanionDeviceSerializer(devices, many=True, context={"request": request}).data
        )


class CompanionDeviceDetailView(views.APIView):
    permission_classes = [IsAuthenticated]

    def _device(self, request, pk):
        device = CompanionDevice.objects.filter(pk=pk).first()
        if device is None:
            raise ValidationError({"detail": "That phone is not paired."})
        if device.paired_by_id != request.user.pk and not user_is_manager(request.user):
            raise PermissionDenied("That phone was paired by someone else.")
        return device

    def patch(self, request, pk):
        device = self._device(request, pk)
        serializer = CompanionDeviceSerializer(
            device, data=request.data, partial=True, context={"request": request}
        )
        serializer.is_valid(raise_exception=True)
        was_paused = device.is_paused
        device = serializer.save()
        if device.is_paused != was_paused:
            services.record_device_state(
                device, state="paused" if device.is_paused else "resumed"
            )
        return Response(serializer.data)

    def delete(self, request, pk):
        device = self._device(request, pk)
        device.revoke(CompanionDevice.RevokedReason.MANUAL)
        services.record_device_state(device, state="left")
        return Response(status=status.HTTP_204_NO_CONTENT)


class CompanionEventListView(views.APIView):
    """Polling fallback for the stream, and the replay after a reconnect."""

    permission_classes = [IsAuthenticated]

    def get(self, request):
        till_key = _required_till_key(request)
        since = _int_param(request, "since", 0)
        limit = max(1, min(_int_param(request, "limit", 100), 500))
        events = services.events_since(till_key, since, limit=limit)
        cursor = events[-1].pk if events else since
        return Response(
            {
                "cursor": cursor,
                "events": CompanionEventSerializer(
                    events, many=True, context={"request": request}
                ).data,
            }
        )


class CompanionStreamView(views.APIView):
    """Server-sent events for one till.

    Uses the same ASGI bridge as the AI assistant: Django would otherwise
    buffer a sync generator wholesale under uvicorn and the till would see
    nothing until the stream ended.
    """

    permission_classes = [IsAuthenticated]

    def get(self, request):
        till_key = _required_till_key(request)
        since = _int_param(request, "since", 0)
        if since <= 0:
            # A till with no cursor wants "from now on", not the whole backlog.
            since = services.latest_event_id(till_key)

        serializer_context = {"request": request}

        def serialize(event):
            return CompanionEventSerializer(event, context=serializer_context).data

        stream = services.stream_events(
            till_key=till_key, cursor=since, serialize=serialize
        )
        django_request = getattr(request, "_request", request)
        if isinstance(django_request, ASGIRequest):
            stream = aiter_in_thread(stream)
        response = StreamingHttpResponse(stream, content_type="text/event-stream")
        response["Cache-Control"] = "no-cache"
        response["X-Accel-Buffering"] = "no"
        return response


class CompanionCaptureRequestView(views.APIView):
    """The till asking its phone for one specific photo."""

    permission_classes = [IsAuthenticated]

    def post(self, request):
        till_key = _required_till_key(request)
        serializer = CompanionCaptureRequestSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        owner = serializer.validated_data.pop("_owner", None)

        if owner is not None:
            self._assert_may_attach_to(request.user, owner)

        ttl = int(getattr(settings, "POINTY_COMPANION_CAPTURE_TTL_SECONDS", 600))
        capture_request = CompanionCaptureRequest.objects.create(
            till_key=till_key,
            prompt=serializer.validated_data.get("prompt", "")[:200],
            owner=owner,
            role=serializer.validated_data.get("role", ""),
            is_primary=serializer.validated_data.get("is_primary", False),
            allow_multiple=serializer.validated_data.get("allow_multiple", False),
            created_by=request.user,
            expires_at=timezone.now() + timezone.timedelta(seconds=ttl),
        )
        # No push is needed: the page polls its context while it is on screen,
        # which is far more robust on a phone than a connection mobile Safari
        # will kill the moment the screen locks.
        return Response(
            CompanionCaptureRequestSerializer(capture_request).data,
            status=status.HTTP_201_CREATED,
        )

    def _assert_may_attach_to(self, user, owner):
        """A photo that files itself against a record is a write to that record.

        So the same permission the till would need to edit it by hand is
        required here — otherwise a capture request would be a way to attach
        images to models the user cannot touch.
        """
        if user_is_manager(user) or user.is_superuser:
            return
        meta = owner._meta
        if not user.has_perm(f"{meta.app_label}.change_{meta.model_name}"):
            raise PermissionDenied("You cannot attach photos to that record.")


class CompanionCaptureRequestCancelView(views.APIView):
    permission_classes = [IsAuthenticated]

    def delete(self, request, pk):
        capture_request = CompanionCaptureRequest.objects.filter(pk=pk).first()
        if capture_request is None:
            return Response(status=status.HTTP_204_NO_CONTENT)
        if (
            capture_request.created_by_id != request.user.pk
            and not user_is_manager(request.user)
        ):
            raise PermissionDenied("That request belongs to someone else.")
        if capture_request.status == CompanionCaptureRequest.Status.PENDING:
            capture_request.status = CompanionCaptureRequest.Status.CANCELLED
            capture_request.save(update_fields=["status", "updated_at"])
        return Response(status=status.HTTP_204_NO_CONTENT)


# --------------------------------------------------------------------------
# Phone side
# --------------------------------------------------------------------------


class CompanionPairClaimView(views.APIView):
    """Exchange the code from the QR for this phone's own token."""

    permission_classes = [IsOnShopNetwork]
    authentication_classes = []
    throttle_classes = [CompanionPairRateThrottle]

    def post(self, request):
        device, token = services.claim_pairing(
            code=request.data.get("code"),
            user_agent=request.META.get("HTTP_USER_AGENT", ""),
            address=services.request_address(request),
            label=request.data.get("label") or "",
        )
        return Response(
            {"token": token, "context": _context_payload(device)},
            status=status.HTTP_201_CREATED,
        )


class CompanionContextView(views.APIView):
    """What the till wants from this phone right now."""

    permission_classes = [IsCompanionDevice]
    authentication_classes = []

    def get(self, request):
        device = request.companion_device
        device.touch(address=services.request_address(request))
        return Response(_context_payload(device))


class CompanionScanView(views.APIView):
    permission_classes = [IsCompanionDevice]
    authentication_classes = []

    def post(self, request):
        device = request.companion_device
        device.touch(address=services.request_address(request))
        event = services.record_scan(
            device=device,
            value=request.data.get("value"),
            symbology=request.data.get("symbology") or "",
        )
        return Response(
            {"accepted": event is not None, "paused": device.is_paused},
            status=status.HTTP_201_CREATED if event else status.HTTP_202_ACCEPTED,
        )


class CompanionDecodeView(views.APIView):
    """Read a code out of a photo the phone could not decode itself.

    The browser tries first, because that is instant and costs the shop's
    network nothing. This is the failure path: jsQR is a clean-image decoder and
    reads no 1-D barcodes at all, so on an iPhone every EAN-13 and every
    slightly-blurred receipt QR died there. zxing-cpp reads both, from a real
    photograph, in about the time the round trip takes.

    A hit is recorded as an ordinary scan, so the till cannot tell — and should
    not care — which decoder resolved it.
    """

    permission_classes = [IsCompanionDevice]
    authentication_classes = []
    throttle_classes = [CompanionUploadRateThrottle]

    def post(self, request):
        device = request.companion_device
        device.touch(address=services.request_address(request))
        uploaded = request.FILES.get("file")
        if uploaded is None:
            raise ValidationError({"file": "No image was uploaded."})
        if not decoder_available():
            return Response(
                {"found": False, "detail": "server decoding is unavailable"},
                status=status.HTTP_501_NOT_IMPLEMENTED,
            )

        decoded = decode_image(uploaded.read())
        if decoded is None:
            return Response({"found": False})

        value, symbology = decoded
        event = services.record_scan(
            device=device, value=value, symbology=symbology
        )
        return Response(
            {
                "found": True,
                "value": value,
                "symbology": symbology,
                "accepted": event is not None,
                "paused": device.is_paused,
            }
        )


class CompanionCaptureView(views.APIView):
    permission_classes = [IsCompanionDevice]
    authentication_classes = []
    throttle_classes = [CompanionUploadRateThrottle]

    def post(self, request):
        device = request.companion_device
        device.touch(address=services.request_address(request))
        uploaded = request.FILES.get("file")
        if uploaded is None:
            raise ValidationError({"file": "No photo was uploaded."})

        capture_request = _open_capture_request(
            device.till_key, request.data.get("capture_request")
        )
        _, attachment = services.record_capture(
            device=device,
            uploaded_file=uploaded,
            capture_request=capture_request,
            note=request.data.get("note") or "",
        )
        return Response(
            {"attachment_id": attachment.pk, "filename": attachment.original_filename},
            status=status.HTTP_201_CREATED,
        )


class CompanionLeaveView(views.APIView):
    """The phone unpairing itself — the 'I'm done' button on the page."""

    permission_classes = [IsCompanionDevice]
    authentication_classes = []

    def post(self, request):
        device = request.companion_device
        device.revoke(CompanionDevice.RevokedReason.MANUAL)
        services.record_device_state(device, state="left")
        return Response(status=status.HTTP_204_NO_CONTENT)


def _open_capture_request(till_key, raw_id):
    if not raw_id:
        return _pending_capture_request(till_key)
    capture_request = CompanionCaptureRequest.objects.filter(
        pk=raw_id, till_key=till_key
    ).first()
    if capture_request is None or not capture_request.is_open:
        return None
    return capture_request


def _pending_capture_request(till_key):
    return (
        CompanionCaptureRequest.objects.filter(
            till_key=till_key,
            status=CompanionCaptureRequest.Status.PENDING,
            expires_at__gt=timezone.now(),
        )
        .order_by("-created_at")
        .first()
    )


def _context_payload(device):
    shop_name = ""
    try:
        shop_name = ShopSettings.load().shop_name
    except Exception:  # pragma: no cover - settings row missing
        shop_name = ""
    return CompanionContextSerializer(
        {
            "shop_name": shop_name,
            "till_label": device.label or "",
            "device_id": device.pk,
            "device_label": device.label or "",
            "is_paused": device.is_paused,
            "capture_request": _pending_capture_request(device.till_key),
        }
    ).data
