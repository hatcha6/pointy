"""The rule that keeps a companion phone from being a login.

A companion token deliberately does **not** authenticate a user. It is resolved
by a permission class rather than a DRF authentication class, so ``request.user``
stays anonymous for the whole request and there is no path — not a stray
``IsAuthenticated``, not a future viewset that forgets — by which a phone could
satisfy ``HasPointyPermission``. What a phone can do is exactly what the views in
this app let a ``request.companion_device`` do: post a scan and post a photo,
into one till's channel.

Phones are lost, left on counters, and handed to whoever is nearest. This is the
line that makes that survivable.
"""

from rest_framework import permissions
from rest_framework.exceptions import APIException

from apps.core.discovery import request_is_lan_local

from .models import CompanionDevice
from .tokens import hash_secret

AUTH_HEADER_SCHEME = "companion"


class CompanionAuthRequired(APIException):
    status_code = 401
    default_detail = "This phone is not paired with a till."
    default_code = "companion_unpaired"


class CompanionOffNetwork(APIException):
    status_code = 403
    default_detail = "The companion camera only works on the shop network."
    default_code = "companion_off_network"


def companion_token_from_request(request) -> str:
    header = request.META.get("HTTP_AUTHORIZATION", "")
    scheme, _, credentials = header.partition(" ")
    if scheme.strip().lower() != AUTH_HEADER_SCHEME:
        return ""
    return credentials.strip()


def resolve_companion_device(request):
    """The live device this request speaks for, or ``None``.

    Cached on the underlying Django request rather than DRF's wrapper, so a
    view, its throttle and anything downstream (request tracking, error
    reporting) all see the same answer and none of them re-query.
    """
    django_request = getattr(request, "_request", request)
    if hasattr(django_request, "companion_device"):
        return django_request.companion_device

    device = None
    token = companion_token_from_request(request)
    if token:
        device = (
            CompanionDevice.objects.live()
            .select_related("register_session")
            .filter(token_hash=hash_secret(token))
            .first()
        )
        if device is not None and not device.is_live:
            # An idle-expired or session-closed device is finished; record why
            # so the paired-devices list can say so instead of showing a ghost.
            device.revoke(
                CompanionDevice.RevokedReason.SESSION_CLOSED
                if device.register_session_id
                else CompanionDevice.RevokedReason.IDLE
            )
            device = None

    django_request.companion_device = device
    return device


class IsCompanionDevice(permissions.BasePermission):
    """A live companion token, presented from this shop's own network."""

    def has_permission(self, request, view) -> bool:
        if not request_is_lan_local(request):
            raise CompanionOffNetwork()
        device = resolve_companion_device(request)
        if device is None:
            raise CompanionAuthRequired()
        return True


class IsOnShopNetwork(permissions.BasePermission):
    """LAN-only, no token yet — the pairing exchange and the page itself."""

    def has_permission(self, request, view) -> bool:
        if not request_is_lan_local(request):
            raise CompanionOffNetwork()
        return True
