"""Which events are a person's *actions* and which are the machinery's.

Shared by the activity-log filter (``activity_scope=reviewable``) and the
per-user activity summary, so both draw the line in the same place.
"""

from django.db.models import Q

from .models import AnalyticsEvent

TECHNICAL_EVENT_NAMES = frozenset(
    {
        "app.lifecycle_changed",
        "app.started",
        "backend.request",
        "frontend.frame_timing",
        "frontend.http_request",
        "frontend.interaction",
        "frontend.operation",
        "frontend.screen_viewed",
    }
)


def technical_events_q():
    """Telemetry about the software itself: request timings, frames, clicks."""
    return Q(event_type=AnalyticsEvent.EventType.PERFORMANCE) | Q(
        name__in=TECHNICAL_EVENT_NAMES
    )
