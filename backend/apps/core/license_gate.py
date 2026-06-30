from django.http import JsonResponse

from .models import RelayInstallation


class LicenseGateMiddleware:
    """Refuse to serve the API until this installation is licensed (enrolled with
    the relay). Best-effort: a determined on-prem operator could patch it out, but
    out of the box an unlicensed backend serves nothing useful — and so the
    connector can't bootstrap either, because everything but the bootstrap path is
    locked.

    The gate keys on "does a RelayInstallation exist?", which becomes true exactly
    once — the first time the license key is redeemed online. It NEVER requires the
    relay to be reachable again, so a licensed shop keeps working fully offline (a
    POS must survive internet outages).
    """

    # Paths reachable before licensing: health/readiness probes (so the container
    # is healthy and the connector can start), the relay connector bootstrap (so
    # the backend can self-enroll), and the enrollment-status probe for the UI.
    EXEMPT_PREFIXES = (
        "/healthz",
        "/readyz",
        "/api/discovery/",
        "/api/relay/connector-config",
        "/api/relay/connector-heartbeat",
        "/api/enrollment/",
    )

    def __init__(self, get_response):
        self.get_response = get_response
        # Cached once licensed: an installation is never un-enrolled at runtime, so
        # this avoids a DB hit on every request in the common (licensed) case.
        self._licensed = False

    def __call__(self, request):
        if (
            not self._licensed
            and request.method != "OPTIONS"  # let CORS preflight through
            and not self._is_exempt(request.path)
        ):
            if RelayInstallation.objects.exists():
                self._licensed = True
            else:
                return JsonResponse(
                    {
                        "detail": "license enrollment required",
                        "requires_enrollment": True,
                    },
                    status=503,
                )
        return self.get_response(request)

    def _is_exempt(self, path):
        return any(path.startswith(prefix) for prefix in self.EXEMPT_PREFIXES)
