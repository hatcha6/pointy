from django.db import transaction
from django.db.models.deletion import ProtectedError
from rest_framework import status, viewsets
from rest_framework.decorators import action
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from apps.analytics.models import AnalyticsEvent
from apps.analytics.services import record_domain_event
from apps.core.permissions import HasPointyPermission
from .models import SalesChannel
from .serializers import SalesChannelSerializer


class SalesChannelViewSet(viewsets.ModelViewSet):
    serializer_class = SalesChannelSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("channels.view_saleschannel",),
        "retrieve": ("channels.view_saleschannel",),
        "create": ("channels.add_saleschannel",),
        "update": ("channels.change_saleschannel",),
        "partial_update": ("channels.change_saleschannel",),
        "destroy": ("channels.delete_saleschannel",),
        "rotate_key": ("channels.change_saleschannel",),
    }
    queryset = SalesChannel.objects.all()
    filterset_fields = ("is_active", "channel_type")
    search_fields = ("name", "slug")
    ordering_fields = ("name", "created_at", "api_key_last_used_at")

    def list(self, request, *args, **kwargs):
        # The built-in POS channel is normally seeded by migration; recreate it
        # lazily so the settings page is complete even after a partial restore.
        SalesChannel.pos_channel()
        return super().list(request, *args, **kwargs)

    def create(self, request, *args, **kwargs):
        serializer = self.get_serializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        channel = serializer.save()
        raw_key = channel.assign_new_api_key()
        self._record_channel_event(
            "channels.sales_channel.created",
            channel,
            attributes={"channel_type": channel.channel_type},
        )
        data = self.get_serializer(channel).data
        # The raw key is returned exactly once; only its hash is stored.
        data["api_key"] = raw_key
        headers = self.get_success_headers(data)
        return Response(data, status=status.HTTP_201_CREATED, headers=headers)

    def perform_update(self, serializer):
        was_active = serializer.instance.is_active
        channel = serializer.save()
        if was_active and not channel.is_active:
            self._record_channel_event(
                "channels.sales_channel.deauthorized",
                channel,
                severity=AnalyticsEvent.Severity.WARNING,
            )
        elif not was_active and channel.is_active:
            self._record_channel_event("channels.sales_channel.authorized", channel)

    def destroy(self, request, *args, **kwargs):
        channel = self.get_object()
        if channel.is_system:
            return Response(
                {"detail": "The built-in POS channel cannot be deleted."},
                status=status.HTTP_400_BAD_REQUEST,
            )
        try:
            with transaction.atomic():
                channel.delete()
        except ProtectedError:
            return Response(
                {
                    "detail": (
                        "This channel has recorded orders and cannot be deleted. "
                        "Deauthorize it instead."
                    )
                },
                status=status.HTTP_409_CONFLICT,
            )
        self._record_channel_event(
            "channels.sales_channel.deleted",
            channel,
            severity=AnalyticsEvent.Severity.WARNING,
        )
        return Response(status=status.HTTP_204_NO_CONTENT)

    @action(detail=True, methods=["post"], url_path="rotate-key")
    def rotate_key(self, request, pk=None):
        channel = self.get_object()
        if channel.is_system:
            return Response(
                {"detail": "The built-in POS channel does not use an API key."},
                status=status.HTTP_400_BAD_REQUEST,
            )
        raw_key = channel.assign_new_api_key()
        self._record_channel_event(
            "channels.sales_channel.key_rotated",
            channel,
            severity=AnalyticsEvent.Severity.WARNING,
        )
        data = self.get_serializer(channel).data
        data["api_key"] = raw_key
        return Response(data)

    def _record_channel_event(
        self,
        name,
        channel,
        *,
        severity=AnalyticsEvent.Severity.INFO,
        attributes=None,
    ):
        record_domain_event(
            name=name,
            event_type=AnalyticsEvent.EventType.AUDIT,
            severity=severity,
            user=self.request.user,
            entity_type="sales_channel",
            entity_id=channel.pk,
            attributes={"channel_slug": channel.slug, **(attributes or {})},
        )
