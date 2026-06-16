from rest_framework.permissions import BasePermission

from apps.core.discovery import request_is_private_network


class IsPrivateNetworkOrAuthenticated(BasePermission):
    """Allow LAN price-checker hardware OR an authenticated staff user.

    A price lookup is low-sensitivity (the name and shelf price the shopper is
    already holding) and dumb on-prem hardware cannot hold a session, so we
    trust private-network peers — the same trust model the existing LAN
    discovery uses — while still permitting staff via the authenticated UI.
    """

    message = "Price lookups are limited to the local network."

    def has_permission(self, request, view):
        user = getattr(request, "user", None)
        if user is not None and user.is_authenticated:
            return True
        return request_is_private_network(request)
