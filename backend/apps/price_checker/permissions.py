from rest_framework.permissions import BasePermission

from apps.core.discovery import request_is_lan_local


class IsPrivateNetworkOrAuthenticated(BasePermission):
    """Allow LAN price-checker hardware OR an authenticated staff user.

    A price lookup is low-sensitivity (the name and shelf price the shopper is
    already holding) and dumb on-prem hardware cannot hold a session, so we
    trust LAN peers — the same trust model the existing LAN discovery uses —
    while still permitting staff via the authenticated UI.

    "LAN" here means :func:`request_is_lan_local`, not merely a private
    ``REMOTE_ADDR``: the relay connector dials the backend from the LAN, so a
    request tunnelled in from the internet also has a private peer address.
    Without the relayed check this gate would let anyone holding the shop's
    relay access token read the catalogue and self-register kiosks remotely,
    with no user session. Signed-in staff are unaffected — they pass on the
    branch above, over the relay or not.
    """

    message = "Price lookups are limited to the local network."

    def has_permission(self, request, view):
        user = getattr(request, "user", None)
        if user is not None and user.is_authenticated:
            return True
        return request_is_lan_local(request)
