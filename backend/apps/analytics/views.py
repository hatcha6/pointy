import django_filters
from django import forms
from django.http import HttpResponse
from django.db.models import Q
from rest_framework import mixins, status, viewsets
from rest_framework.decorators import action
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from apps.core.permissions import HasPointyPermission, IsManager

from .models import AnalyticsEvent
from .serializers import (
    AnalyticsEventBatchSerializer,
    AnalyticsEventExportQuerySerializer,
    AnalyticsEventSerializer,
)
from .services import build_events_export_zip, filter_events_for_export, ingest_events


ANALYTICS_EVENT_ACTIONS = {
    "pos_line_deleted": "pos.cart.line.deleted",
    "purchase_line_deleted": "purchasing.draft.line.deleted",
    "invoice_created": "sales.checkout.completed",
    "customer_created": "customers.customer.created",
    "register_cash_movement": "sales.register_cash_movement.created",
    "order_voided": "sales.order.voided",
    "order_returned": "sales.order.returned",
    "purchase_order_deleted": "purchasing.purchase_order.deleted",
}

TECHNICAL_EVENT_NAMES = {
    "app.lifecycle_changed",
    "app.started",
    "backend.request",
    "frontend.frame_timing",
    "frontend.http_request",
    "frontend.interaction",
    "frontend.operation",
    "frontend.screen_viewed",
}


class AnalyticsEventFilterForm(forms.Form):
    def clean(self):
        cleaned_data = super().clean()
        lower_bounds = [
            value
            for value in (
                cleaned_data.get("occurred_at_after"),
                cleaned_data.get("date_from"),
            )
            if value is not None
        ]
        upper_bounds = [
            value
            for value in (
                cleaned_data.get("occurred_at_before"),
                cleaned_data.get("date_to"),
            )
            if value is not None
        ]
        if lower_bounds and upper_bounds and max(lower_bounds) > min(upper_bounds):
            raise forms.ValidationError(
                "date_from/occurred_at_after must be before date_to/occurred_at_before."
            )

        risk_score_min = cleaned_data.get("risk_score_min")
        risk_score_max = cleaned_data.get("risk_score_max")
        if (
            risk_score_min is not None
            and risk_score_max is not None
            and risk_score_min > risk_score_max
        ):
            raise forms.ValidationError(
                "risk_score_min must be less than or equal to risk_score_max."
            )
        return cleaned_data


class AnalyticsEventFilter(django_filters.FilterSet):
    activity_scope = django_filters.ChoiceFilter(
        choices=(
            ("reviewable", "Reviewable activity"),
            ("all", "All events"),
            ("technical", "Technical telemetry"),
        ),
        method="filter_activity_scope",
    )
    action = django_filters.ChoiceFilter(
        choices=(
            ("fraud_signal", "Fraud signal"),
            ("any_deleted", "Any deleted"),
            *(
                (action_name, action_name.replace("_", " ").title())
                for action_name in ANALYTICS_EVENT_ACTIONS
            ),
        ),
        method="filter_action",
    )
    received_by = django_filters.NumberFilter(
        field_name="received_by_id",
        min_value=1,
    )
    user = django_filters.NumberFilter(field_name="received_by_id", min_value=1)
    occurred_at_after = django_filters.IsoDateTimeFilter(
        field_name="occurred_at",
        lookup_expr="gte",
    )
    occurred_at_before = django_filters.IsoDateTimeFilter(
        field_name="occurred_at",
        lookup_expr="lte",
    )
    date_from = django_filters.IsoDateTimeFilter(
        field_name="occurred_at",
        lookup_expr="gte",
    )
    date_to = django_filters.IsoDateTimeFilter(
        field_name="occurred_at",
        lookup_expr="lte",
    )
    risk_score_min = django_filters.NumberFilter(
        field_name="risk_score",
        lookup_expr="gte",
        min_value=0,
        max_value=100,
    )
    risk_score_max = django_filters.NumberFilter(
        field_name="risk_score",
        lookup_expr="lte",
        min_value=0,
        max_value=100,
    )
    register_session = django_filters.CharFilter(field_name="session_id")

    class Meta:
        model = AnalyticsEvent
        form = AnalyticsEventFilterForm
        fields = (
            "event_type",
            "activity_scope",
            "name",
            "action",
            "severity",
            "source",
            "received_by",
            "user",
            "occurred_at_after",
            "occurred_at_before",
            "date_from",
            "date_to",
            "risk_score_min",
            "risk_score_max",
            "session_id",
            "register_session",
            "device_id",
            "installation_id",
            "platform",
            "entity_type",
            "entity_id",
        )

    def filter_action(self, queryset, name, value):
        if value == "fraud_signal":
            return queryset.filter(event_type=AnalyticsEvent.EventType.FRAUD_SIGNAL)
        if value == "any_deleted":
            return queryset.filter(name__contains="deleted")
        return queryset.filter(name=ANALYTICS_EVENT_ACTIONS[value])

    def filter_activity_scope(self, queryset, name, value):
        technical_query = Q(event_type=AnalyticsEvent.EventType.PERFORMANCE) | Q(
            name__in=TECHNICAL_EVENT_NAMES
        )
        if value == "reviewable":
            return queryset.exclude(technical_query)
        if value == "technical":
            return queryset.filter(technical_query)
        return queryset


class AnalyticsEventViewSet(
    mixins.ListModelMixin,
    mixins.RetrieveModelMixin,
    viewsets.GenericViewSet,
):
    serializer_class = AnalyticsEventSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("analytics.view_analyticsevent",),
        "retrieve": ("analytics.view_analyticsevent",),
        "ingest": ("analytics.add_analyticsevent",),
        "export": ("analytics.view_analyticsevent",),
    }
    queryset = AnalyticsEvent.objects.select_related("received_by")
    filterset_class = AnalyticsEventFilter
    search_fields = ("name", "trace_id", "entity_type", "entity_id")
    ordering_fields = ("occurred_at", "created_at", "severity", "risk_score")

    def get_permissions(self):
        if self.action == "export":
            return [IsAuthenticated(), IsManager(), HasPointyPermission()]
        return super().get_permissions()

    @action(detail=False, methods=["post"])
    def ingest(self, request):
        serializer = AnalyticsEventBatchSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        result = ingest_events(
            events=serializer.validated_data["events"],
            user=request.user,
            request=request,
        )
        return Response(
            {
                "accepted": result.accepted,
                "duplicates": result.duplicates,
                "event_ids": result.event_ids,
                "duplicate_event_ids": result.duplicate_event_ids,
            },
            status=status.HTTP_201_CREATED,
        )

    @action(detail=False, methods=["get"])
    def export(self, request):
        serializer = AnalyticsEventExportQuerySerializer(data=request.query_params)
        serializer.is_valid(raise_exception=True)
        queryset = filter_events_for_export(
            self.get_queryset(),
            serializer.normalized_filters,
        )
        export = build_events_export_zip(
            queryset=queryset,
            filters=serializer.normalized_filters,
            exported_by=request.user,
        )
        response = HttpResponse(export.content, content_type="application/zip")
        response["Content-Disposition"] = f'attachment; filename="{export.filename}"'
        response["X-Pointy-Analytics-Event-Count"] = str(export.event_count)
        return response
