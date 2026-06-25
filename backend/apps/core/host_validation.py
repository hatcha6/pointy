"""Host-header validation for on-prem LAN appliances.

An on-prem server typically gets its address from DHCP, and cashier tills find
it through UDP discovery (see :mod:`apps.core.discovery`) — the backend advertises
whichever private IP each till can reach it on, with no per-site configuration.
Pinning ``ALLOWED_HOSTS`` to a fixed IP would defeat that.

When ``POINTY_ALLOW_PRIVATE_HOSTS`` is enabled, settings opens Django's built-in
check to ``["*"]`` and installs this middleware to enforce the real policy:
accept a request only if its ``Host`` is a private / loopback / link-local IP
(any LAN address the server might currently have) or one of the explicitly
allow-listed names, and reject everything else. That keeps Host validation
meaningful — public hostnames are still refused — while letting any LAN IP work
out of the box.
"""

import ipaddress

from django.conf import settings
from django.http import HttpResponseBadRequest
from django.http.request import split_domain_port


def host_is_allowed(host, allowed_names):
    """Return True if ``host`` (a raw ``Host`` header value) is acceptable.

    ``allowed_names`` is a set of lowercase hostnames that are always allowed
    (e.g. ``localhost``, ``backend``, a reverse-proxy DNS name).
    """
    domain, _port = split_domain_port(host)
    if not domain:
        return False
    # split_domain_port lowercases and keeps IPv6 literals bracketed ("[::1]").
    name = domain.strip("[]")
    if name in allowed_names:
        return True
    try:
        address = ipaddress.ip_address(name)
    except ValueError:
        return False
    return address.is_private or address.is_loopback or address.is_link_local


class PrivateNetworkHostMiddleware:
    """Reject non-private ``Host`` headers when ALLOWED_HOSTS is opened to "*"."""

    def __init__(self, get_response):
        self.get_response = get_response
        self.allowed_names = {
            name.lower() for name in getattr(settings, "POINTY_LAN_ALLOWED_HOST_NAMES", [])
        }

    def __call__(self, request):
        # ALLOWED_HOSTS is ["*"] in this mode, so get_host() never raises here.
        if not host_is_allowed(request.get_host(), self.allowed_names):
            return HttpResponseBadRequest("Disallowed host.")
        return self.get_response(request)
