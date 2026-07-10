from rest_framework import mixins, status, viewsets
from rest_framework.decorators import action
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from django.utils import timezone

from .cache import notifications_etag
from .serializers import (
    BusinessNotificationSerializer,
    SnoozeBusinessNotificationSerializer,
)
from .services import (
    acknowledge_notification,
    acknowledge_notifications_for_user,
    maybe_sync_business_notifications,
    restore_notification,
    restore_notifications_for_user,
    snooze_notification,
    sync_business_notifications,
    visible_notifications_for_user,
)


class BusinessNotificationViewSet(
    mixins.ListModelMixin,
    mixins.RetrieveModelMixin,
    viewsets.GenericViewSet,
):
    serializer_class = BusinessNotificationSerializer
    permission_classes = [IsAuthenticated]
    filterset_fields = ("category", "severity", "code", "entity_type", "entity_id")
    search_fields = ("code", "entity_type", "entity_id")
    ordering_fields = ("last_seen_at", "severity", "category", "created_at")

    def list(self, request, *args, **kwargs):
        # The bell/badge poll from every signed-in device. Order matters: the
        # (throttled) inline sync runs first because it may materially change
        # the feed and bump the version; only then is the ETag trustworthy.
        maybe_sync_business_notifications()
        etag = notifications_etag(request)
        if etag is not None and request.headers.get("If-None-Match") == etag:
            return Response(
                status=status.HTTP_304_NOT_MODIFIED, headers={"ETag": etag}
            )
        response = super().list(request, *args, **kwargs)
        if etag is not None and response.status_code == status.HTTP_200_OK:
            response["ETag"] = etag
        return response

    def get_queryset(self):
        # Reads top up the feed inline, but throttled (see the service): the
        # Celery beat is the primary refresher, so the bell/badge polled by every
        # device no longer triggers a full recompute per request. The explicit
        # POST /refresh below still forces an immediate, unthrottled recompute.
        # (list() runs the same top-up before its ETag check, so only retrieve
        # needs it here.)
        if self.action == "retrieve":
            maybe_sync_business_notifications()
        queryset = visible_notifications_for_user(self.request.user)
        include_hidden = self.action in {
            "dismiss",
            "snooze",
            "restore",
        } or _truthy(self.request.query_params.get("include_hidden"))
        if include_hidden:
            return queryset
        return queryset.exclude(
            user_states__user=self.request.user,
            user_states__acknowledged_at__isnull=False,
        ).exclude(
            user_states__user=self.request.user,
            user_states__snoozed_until__gt=timezone.now(),
        )

    @action(detail=False, methods=["post"])
    def refresh(self, request):
        result = sync_business_notifications()
        return Response(result)

    @action(detail=True, methods=["post"])
    def dismiss(self, request, pk=None):
        notification = self.get_object()
        acknowledge_notification(notification, request.user)
        serializer = self.get_serializer(notification)
        return Response(serializer.data)

    @action(detail=True, methods=["post"])
    def snooze(self, request, pk=None):
        serializer = SnoozeBusinessNotificationSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        notification = self.get_object()
        snooze_notification(
            notification,
            request.user,
            duration=serializer.duration,
        )
        return Response(self.get_serializer(notification).data)

    @action(detail=True, methods=["post"])
    def restore(self, request, pk=None):
        notification = self.get_object()
        restore_notification(notification, request.user)
        return Response(self.get_serializer(notification).data)

    @action(detail=False, methods=["post"], url_path="dismiss-all")
    def dismiss_all(self, request):
        count = acknowledge_notifications_for_user(
            request.user,
            visible_notifications_for_user(request.user),
        )
        return Response({"dismissed": count}, status=status.HTTP_200_OK)

    @action(detail=False, methods=["post"], url_path="restore-hidden")
    def restore_hidden(self, request):
        count = restore_notifications_for_user(
            request.user,
            visible_notifications_for_user(request.user),
        )
        return Response({"restored": count}, status=status.HTTP_200_OK)


def _truthy(value):
    return str(value or "").strip().lower() in {"1", "true", "yes", "on"}
