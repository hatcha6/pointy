"""Sign-in from the internet with the installation ID alone.

The relay answers ``/api/`` for a device with no ticket only on its sign-in
route: a short list of paths (this module's status view, login, pairing),
marked ``X-Pointy-Relay-Sign-In: 1`` on the way in. That is how a phone that
never joined the shop's Wi-Fi — or the web app on an iPhone — gets its first
ticket: a manager signs in, and pairing then hands the device a ticket like
any till paired on the LAN.

It is the shop's call: ``ShopSettings.allow_remote_sign_in`` is off until the
owner turns it on, and only a manager may use it. The marker is trusted as
far as it reaches: a LAN client could forge it, but a LAN client may pair
anyway, so it gains nothing.
"""

from .discovery import request_is_relayed
from .models import ShopSettings
from .roles import user_is_manager


REMOTE_SIGN_IN_META = "HTTP_X_POINTY_RELAY_SIGN_IN"

REMOTE_SIGN_IN_DISABLED = "remote_sign_in_disabled"
REMOTE_SIGN_IN_NOT_ALLOWED = "remote_sign_in_not_allowed"


def request_is_remote_sign_in(request):
    """Whether the request came in through the relay's sign-in route."""
    return request_is_relayed(request) and request.META.get(REMOTE_SIGN_IN_META) == "1"


def remote_sign_in_refusal(request, user=None):
    """Why this sign-in route request is refused, or None when it may go on.

    Not a sign-in route request at all is None too. With no [user] only the
    shop's switch is judged — before a password is ever checked, so a shop
    that has it off tells the internet nothing about its accounts.
    """
    if not request_is_remote_sign_in(request):
        return None
    if not ShopSettings.load().allow_remote_sign_in:
        return REMOTE_SIGN_IN_DISABLED
    if user is not None and not user_is_manager(user):
        return REMOTE_SIGN_IN_NOT_ALLOWED
    return None
