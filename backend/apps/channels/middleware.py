from django.http import JsonResponse
from django.utils import timezone

from .models import SalesChannel

API_KEY_HEADER = "X-Channel-Api-Key"


class SalesChannelMiddleware:
    """Bind API-key-authenticated requests to the channel that owns the key.

    A request presenting a channel API key can only ever act as that key's
    channel; an unknown key is rejected with 401 and a deauthorized (inactive)
    channel with 403. Rejecting here, before any view runs, is what makes
    "deauthorize" in shop settings take effect immediately for every endpoint
    an external integration might call.
    """

    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        raw_key = request.headers.get(API_KEY_HEADER)
        if raw_key:
            channel = SalesChannel.authenticate_api_key(raw_key)
            if channel is None:
                self._record_rejection(request, reason="invalid_key")
                return JsonResponse(
                    {"detail": "Invalid sales channel API key."},
                    status=401,
                )
            if not channel.is_active:
                self._record_rejection(request, reason="channel_deauthorized", channel=channel)
                return JsonResponse(
                    {"detail": "This sales channel has been deauthorized."},
                    status=403,
                )
            request.sales_channel = channel
            SalesChannel.objects.filter(pk=channel.pk).update(
                api_key_last_used_at=timezone.now(),
            )
        return self.get_response(request)

    def _record_rejection(self, request, *, reason, channel=None):
        from apps.analytics.models import AnalyticsEvent
        from apps.analytics.services import record_domain_event

        record_domain_event(
            name="channels.api_key.rejected",
            event_type=AnalyticsEvent.EventType.AUDIT,
            severity=AnalyticsEvent.Severity.WARNING,
            entity_type="sales_channel",
            entity_id=channel.pk if channel is not None else "",
            attributes={
                "reason": reason,
                "path": request.path,
                "channel_slug": channel.slug if channel is not None else None,
            },
        )
