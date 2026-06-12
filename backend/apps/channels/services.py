from rest_framework.exceptions import PermissionDenied

from .models import SalesChannel


def resolve_sales_channel(request):
    """Return the sales channel for ``request``, derived only from credentials.

    A request that presented a valid channel API key was already bound to its
    channel by ``SalesChannelMiddleware``; everything else that carries an
    authenticated user session is, by definition, the shop's own POS app.
    Client-supplied channel names or ids are deliberately never consulted.
    """
    channel = getattr(request, "sales_channel", None)
    if channel is not None:
        return channel
    user = getattr(request, "user", None)
    if user is not None and user.is_authenticated:
        return SalesChannel.pos_channel()
    return None


def require_active_sales_channel(request):
    """Resolve the request's channel, rejecting missing or deauthorized ones.

    The middleware already rejects API-key requests for inactive channels;
    this re-check guards code paths where the channel was deactivated through
    another door (for example the Django admin).
    """
    channel = resolve_sales_channel(request)
    if channel is None:
        raise PermissionDenied("No sales channel could be resolved for this request.")
    if not channel.is_active:
        raise PermissionDenied("This sales channel has been deauthorized.")
    return channel
