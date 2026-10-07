"""Stamp the backend's release on every API response.

A till learns the backend was updated from whatever request it was already
making — usually the idle poll of ``/api/state/`` — and that is its cue to ask
the LAN manifest whether a matching app build is waiting for it. Without this a
remote update replaced the server and the tills went on running the old app
until someone happened to open device settings.

A header rather than a field in the state vector: the vector lives in Redis and
goes quiet when Redis does, and this must not. It is a settings constant, so it
costs nothing to send.
"""

from django.conf import settings

SERVER_VERSION_HEADER = "X-Pointy-Server-Version"


class ServerVersionHeaderMiddleware:
    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        response = self.get_response(request)
        version = getattr(settings, "POINTY_VERSION", "")
        if version and request.path.startswith("/api/"):
            response[SERVER_VERSION_HEADER] = version
        return response
