"""The remote sessions list: a person's own, and anyone's for user management.

See ``apps.core.remote_sessions`` for what a remote session is.
"""

from django.shortcuts import get_object_or_404
from django.utils import timezone
from rest_framework import serializers, status
from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from apps.analytics.models import AnalyticsEvent
from apps.analytics.services import record_domain_event

from .models import RemoteSession
from .remote_sessions import end_remote_session, visible_remote_sessions

# Checked in order: an iPad's Safari says "Macintosh" when it asks for the
# desktop site, and every Android browser says "Linux".
_PLATFORMS = (
    ("iPhone", "iphone"),
    ("iPad", "ipad"),
    ("Android", "android"),
    ("Windows", "windows"),
    ("Macintosh", "mac"),
    ("Mac OS X", "mac"),
    ("CrOS", "chromeos"),
    ("Linux", "linux"),
)
# Every Chromium browser also says "Chrome", and Chrome says "Safari".
_BROWSERS = (
    ("SamsungBrowser", "samsung"),
    ("Edg", "edge"),
    ("OPR", "opera"),
    ("Firefox", "firefox"),
    ("FxiOS", "firefox"),
    ("CriOS", "chrome"),
    ("Chrome", "chrome"),
    ("Safari", "safari"),
)


def _first_match(user_agent, table):
    return next((code for marker, code in table if marker in user_agent), "other")


class RemoteSessionSerializer(serializers.ModelSerializer):
    status = serializers.SerializerMethodField()
    platform = serializers.SerializerMethodField()
    browser = serializers.SerializerMethodField()
    is_current = serializers.SerializerMethodField()
    ended_by_name = serializers.SerializerMethodField()

    class Meta:
        model = RemoteSession
        fields = [
            "id",
            "status",
            "device_name",
            "platform",
            "browser",
            "ip_address",
            "created_at",
            "last_seen_at",
            "expires_at",
            "ended_at",
            "end_reason",
            "ended_by_name",
            "is_current",
        ]

    def get_status(self, remote):
        if remote.ended_at is not None:
            return remote.end_reason or RemoteSession.EndReason.REVOKED
        return "active" if timezone.now() < remote.expires_at else "expired"

    def get_platform(self, remote):
        return _first_match(remote.user_agent, _PLATFORMS)

    def get_browser(self, remote):
        return _first_match(remote.user_agent, _BROWSERS)

    def get_is_current(self, remote):
        request = self.context.get("request")
        session = getattr(request, "session", None)
        return (
            remote.ended_at is None
            and session is not None
            and bool(session.session_key)
            and remote.session_key == session.session_key
        )

    def get_ended_by_name(self, remote):
        user = remote.ended_by
        if user is None:
            return ""
        return user.get_full_name().strip() or user.username


def remote_sessions_response(request, user):
    return Response(
        RemoteSessionSerializer(
            visible_remote_sessions(user), many=True, context={"request": request}
        ).data
    )


def revoke_remote_session_response(request, user, session_id):
    remote = get_object_or_404(RemoteSession, pk=session_id, user=user)
    if end_remote_session(remote, RemoteSession.EndReason.REVOKED, by=request.user):
        record_domain_event(
            name="auth.remote_session.revoked",
            event_type=AnalyticsEvent.EventType.SECURITY,
            user=request.user,
            entity_type="user",
            entity_id=user.pk,
            attributes={
                "remote_session_id": remote.pk,
                "target_user_id": user.pk,
                "self_service": user.pk == request.user.pk,
            },
        )
    remote.refresh_from_db()
    return Response(
        RemoteSessionSerializer(remote, context={"request": request}).data,
        status=status.HTTP_200_OK,
    )


@api_view(["GET"])
@permission_classes([IsAuthenticated])
def my_remote_sessions_view(request):
    return remote_sessions_response(request, request.user)


@api_view(["POST"])
@permission_classes([IsAuthenticated])
def revoke_my_remote_session_view(request, session_id):
    return revoke_remote_session_response(request, request.user, session_id)
